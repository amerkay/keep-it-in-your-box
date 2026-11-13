"""`kib stats [interval_s]` — live CPU and battery cost of kib; Ctrl-C prints a summary.

Linux reads /proc and /sys; macOS reads `top -l 2` and `ioreg`. Both report the same numbers, so
a run on each, and on each engine (the VM, or Linux's rootless gVisor), compares: CPU in cores
(1.00 = one core busy the whole time, `top`'s 100%), battery in watts, `docker stats` per box.
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from kib.shared import cli

VM = "kib-vm"  # host/vm.sh KIB_VM_NAME
HZ = os.sysconf("SC_CLK_TCK")
HOME = Path.home()
SOCK = Path(os.environ.get("LIMA_HOME", HOME / ".lima")) / VM / "sock/docker.sock"
VM_ARG = re.compile(rf"(^|[/=-]){VM}($|/)")  # kib-vm, never kib-vm2
Parts = dict[str, float]  # piece of kib -> cores


# ── Linux: /proc deltas over the window ──────────────────────────
# No-VM mode's own engine: the user's rootless Docker.
ENGINE = ("dockerd", "containerd", "rootlesskit", "slirp4netns")
LINUX_PARTS = {"vm": ("qemu", "virtiofsd", "view"), "rootless": ("gvisor", "engine", "view")}


def part(comm: str, argv: list[str], engine: str) -> str | None:
    """Which piece of kib one of the user's Linux processes is."""
    exe = os.path.basename(argv[0]) if argv else ""
    if exe == "kib-view":
        return "view"
    if engine == "rootless":
        if comm.startswith("gvisor_"):
            return "gvisor"
        return "engine" if comm.startswith(ENGINE) else None
    if not any(VM_ARG.search(a) for a in argv):
        return None
    return "qemu" if exe.startswith("qemu-system") else "virtiofsd" if "virtiofsd" in exe else None


def _procs(engine: str) -> dict[int, tuple[str, int]]:
    out: dict[int, tuple[str, int]] = {}
    uid = os.getuid()
    for p in Path("/proc").iterdir():
        try:
            if not p.name.isdigit() or p.stat().st_uid != uid:  # every piece runs as the user
                continue
            stat = (p / "stat").read_text()
            comm, rest = stat[stat.index("(") + 1 :].rsplit(")", 1)
            argv = (p / "cmdline").read_bytes().decode(errors="replace").split("\0")[:-1]
            name = part(comm, argv, engine)
            if name:
                f = rest.split()
                out[int(p.name)] = (name, int(f[11]) + int(f[12]))  # utime + stime
        except (OSError, IndexError, ValueError):
            continue  # exited mid-scan
    return out


def _busy() -> int:
    f = [int(x) for x in Path("/proc/stat").read_text().split("\n", 1)[0].split()[1:9]]
    return sum(f) - f[3] - f[4]  # minus idle, iowait


def _sample_linux(interval: float, engine: str) -> tuple[float, float, Parts]:
    t0, busy0, procs0 = time.monotonic(), _busy(), _procs(engine)
    time.sleep(interval)
    dt, busy1, procs1 = time.monotonic() - t0, _busy(), _procs(engine)
    parts = dict.fromkeys(LINUX_PARTS[engine], 0.0)
    for pid, (name, ticks) in procs1.items():
        if pid in procs0:  # a new pid has no baseline: its lifetime total is not this window
            parts[name] += (ticks - procs0[pid][1]) / HZ / dt
    return dt, (busy1 - busy0) / HZ / dt, parts


def _watts_linux() -> float | None:
    """Sum of every discharging battery, or None on AC."""
    total = None
    for b in Path("/sys/class/power_supply").glob("BAT*"):
        try:
            if (b / "status").read_text().strip() != "Discharging":
                continue
            if (b / "power_now").exists():
                w = int((b / "power_now").read_text()) / 1e6
            else:
                w = int((b / "current_now").read_text()) * int((b / "voltage_now").read_text())
                w /= 1e12
            total = (total or 0.0) + w
        except (OSError, ValueError):
            continue
    return total


# ── macOS: one `top -l 2`, whose second sample covers the window ─
def mac_part(command: str) -> str | None:
    # ponytail: any Virtualization.framework VM counts (Docker Desktop, UTM too); quit them first.
    if command.startswith("com.apple.Virtu"):
        return "vz"
    return {"limactl": "lima", "kib-view": "view"}.get(command)


def parse_top(text: str, ncpu: int) -> tuple[float, Parts]:
    """Machine cores and kib's parts from the LAST sample of `top -l N -stats pid,cpu,command`."""
    last = text.rsplit("Processes:", 1)[-1]
    m = re.search(r"CPU usage: ([\d.]+)% user, ([\d.]+)% sys", last)
    machine = (float(m[1]) + float(m[2])) * ncpu / 100 if m else 0.0
    parts = dict.fromkeys(("vz", "lima", "view"), 0.0)
    for row in re.finditer(r"^\s*\d+\s+([\d.]+)\S*\s+(.+?)\s*$", last, re.M):
        name = mac_part(row[2])
        if name:
            parts[name] += float(row[1]) / 100
    return machine, parts


def _sample_mac(interval: float, _engine: str) -> tuple[float, float, Parts]:
    s = max(1, round(interval))  # top's -s is whole seconds
    cmd = ["top", "-l", "2", "-s", str(s), "-n", "64", "-o", "cpu", "-stats", "pid,cpu,command"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False).stdout
    return (s, *parse_top(out, os.cpu_count() or 1))


def parse_ioreg(text: str) -> float | None:
    """Battery draw from `ioreg -rn AppleSmartBattery`, or None on AC."""
    kv: dict[str, str] = dict(
        re.findall(r'^\s*"(\w+)" = (\S+)$', text, re.M)
    )  # top level: nested has no spaces
    if kv.get("ExternalConnected", "Yes") != "No":
        return None
    try:
        amps = int(kv.get("InstantAmperage", kv.get("Amperage", "0")))
        amps = amps - 2**64 if amps >= 2**63 else amps  # ioreg prints a negative as unsigned
        return abs(amps) * int(kv["Voltage"]) / 1e6
    except (KeyError, ValueError):
        return None


def _watts_mac() -> float | None:
    cmd = ["ioreg", "-rn", "AppleSmartBattery"]
    return parse_ioreg(subprocess.run(cmd, capture_output=True, text=True, check=False).stdout)


# ── Both ─────────────────────────────────────────────────────────
def _boxes(docker: str | None, engine: str) -> tuple[Parts, str]:
    """CPU per kib container, or ({}, why not)."""
    if not docker:
        return {}, "no docker CLI found"
    env = {k: v for k, v in os.environ.items() if k != "DOCKER_CONTEXT"}
    if engine != "rootless":  # rootless: the user's own Docker, as kib runs it
        if not SOCK.exists():
            return {}, f"no {VM} engine socket (VM stopped?)"
        env["DOCKER_HOST"] = f"unix://{SOCK}"
    cmd = [docker, "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env, check=False)
    except subprocess.TimeoutExpired:
        return {}, "docker stats timed out"
    if r.returncode:
        return {}, f"docker stats failed: {(r.stderr.strip().splitlines() or ['?'])[0]}"
    out: Parts = {}
    for line in r.stdout.splitlines():
        name, _, pct = line.partition("\t")
        try:
            if name.startswith("kib-"):
                out[name] = float(pct.rstrip("%")) / 100
        except ValueError:
            continue
    return out, ""


class Stats:
    def __init__(self, title: str) -> None:
        self.title = title
        self.series: dict[str, list[float]] = {}
        self.watts: list[float] = []
        self.seconds = 0.0
        self.n = 0
        self.notes: set[str] = set()

    def add(self, key: str, cores: float) -> None:
        self.series.setdefault(key, []).append(cores)

    def avg(self, key: str) -> float:
        # Over EVERY sample, so a box that lived for one still compares with the totals.
        return sum(self.series.get(key, [])) / self.n if self.n else 0.0

    def summary(self, parts: tuple[str, ...]) -> str:
        m, s = divmod(int(self.seconds), 60)
        kib, machine = self.avg("kib"), self.avg("machine")
        boxes = sorted((k for k in self.series if k.startswith("box:")), key=self.avg, reverse=True)
        rows = [("whole machine", "machine"), ("kib, total", "kib")]
        rows += [(f"  {k}", k) for k in parts]
        if "overhead" in self.series:
            rows.append(("  overhead: kib minus the view and the boxes", "overhead"))
        if boxes:
            rows.append(("  per box (docker stats):", ""))
            rows += [(f"    {k[4:]}", k) for k in boxes]
        width = max(len(label) for label, _ in rows)
        lines = [f"\n── kib stats · {self.title} · {m}m {s}s, {self.n} samples ──"]
        lines.append("   cores: 1.00 = one core busy the whole time")
        for label, key in rows:
            peak = max(self.series.get(key, [0.0]))
            stat = f"avg {self.avg(key):5.2f}   peak {peak:5.2f}" if key else ""
            lines.append(f"  {label:<{width}}  {stat}".rstrip())
        w = f"avg {sum(self.watts) / len(self.watts):5.1f} W" if self.watts else "on AC throughout"
        lines.append(f"  {'battery draw':<{width}}  {w}")
        lines += [f"  ⚠ {note}" for note in sorted(self.notes)]
        share = 100 * kib / machine if machine else 0
        lines.append(f"\n→ kib: {share:.0f}% of this machine's CPU ({kib:.2f} of {machine:.2f}).")
        return "\n".join(lines)


def main(argv: list[str]) -> int:
    """argv: <engine: vm|rootless> [interval_s] — the engine comes from kib's config."""
    engine, args = (argv[0], argv[1:]) if argv else ("", [])
    try:
        interval = float(args[0]) if args else 5.0
    except ValueError:
        interval = -1.0
    if engine not in LINUX_PARTS or len(args) > 1 or not 1 <= interval <= 3600:  # nan, inf too
        raise cli.AbortError("usage: kib stats [interval_s, 1-3600]", cli.USAGE)
    if sys.platform == "darwin":
        sample, watts, parts = _sample_mac, _watts_mac, ("vz", "lima", "view")
    elif Path("/proc/stat").exists():
        sample, watts, parts = _sample_linux, _watts_linux, LINUX_PARTS[engine]
    else:
        raise cli.AbortError("kib stats runs on Linux and macOS only.", cli.USAGE)
    path = f"{os.environ.get('PATH', '')}:{HOME}/.local/bin:{HOME}/.local/docker"
    docker = shutil.which("docker", path=path)
    stats = Stats(f"{sys.platform}, engine = {engine}")
    print(f"kib stats ({stats.title}): every {interval:g}s — Ctrl-C for the summary.", flush=True)
    try:
        while True:
            dt, machine, cur = sample(interval, engine)
            boxes, why = _boxes(docker, engine)  # outside the window: its own cost is not counted
            if why:
                stats.notes.add(f"no per-box split: {why}")
            stats.n += 1
            stats.seconds += dt
            kib = sum(cur.values())
            for k, v in (("machine", machine), ("kib", kib), *cur.items()):
                stats.add(k, v)
            for k, v in boxes.items():
                stats.add(f"box:{k}", v)
            if boxes:
                stats.add("overhead", max(0.0, kib - cur["view"] - sum(boxes.values())))
            w = watts()
            if w is not None:
                stats.watts.append(w)
            top = max(boxes.items(), key=lambda kv: kv[1], default=None)
            print(
                f"{time.strftime('%H:%M:%S')}  kib {kib:4.2f}  machine {machine:4.2f} cores"
                f"  battery {f'{w:.1f} W' if w is not None else 'AC'}"
                + (f"  busiest box {top[0]} {top[1]:.2f}" if top else ""),
                flush=True,
            )
    except KeyboardInterrupt:
        signal.signal(signal.SIGINT, signal.SIG_IGN)  # a second, mashed Ctrl-C must not eat it
        print(stats.summary(parts), flush=True)
    return cli.OK


if __name__ == "__main__":
    cli.run(main)
