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
from typing import NamedTuple

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
LINUX_PARTS = {
    "vm": ("qemu", "virtiofsd", "view"),
    "rootless": ("gvisor", "engine", "view"),
    "rootful": ("gvisor", "view"),  # root's Docker is the machine's, not kib's
}
TITLES = {"vm": "VM", "rootless": "no VM (rootless gVisor)", "rootful": "no VM (gVisor, rootful)"}


def part(comm: str, argv: list[str], engine: str, mine: bool = True) -> str | None:
    """Which piece of kib a Linux process is. `mine`: it runs as this user."""
    exe = os.path.basename(argv[0]) if argv else ""
    if exe == "kib-view":
        return "view"
    if engine != "vm":
        if comm.startswith("gvisor_"):
            return "gvisor"
        rootless = engine == "rootless" and mine
        return "engine" if rootless and comm.startswith(ENGINE) else None  # never root's Docker
    if not any(VM_ARG.search(a) for a in argv):
        return None
    return "qemu" if exe.startswith("qemu-system") else "virtiofsd" if "virtiofsd" in exe else None


class Proc(NamedTuple):
    part: str | None  # which piece of kib, or None
    comm: str
    ppid: int
    own: int  # utime + stime, in ticks
    kids: int  # cutime + cstime: children it has reaped


Key = tuple[int, int]  # (pid, start time): a reused pid is a new process


def _procs(engine: str) -> dict[Key, Proc]:
    """Every process, any user."""
    out: dict[Key, Proc] = {}
    uid = os.getuid()
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            stat = (p / "stat").read_text()
            comm, rest = stat[stat.index("(") + 1 :].rsplit(")", 1)
            argv = (p / "cmdline").read_bytes().decode(errors="replace").split("\0")[:-1]
            f = rest.split()
            name = part(comm, argv, engine, p.stat().st_uid == uid)
            own, kids = int(f[11]) + int(f[12]), int(f[13]) + int(f[14])
            out[(int(p.name), int(f[19]))] = Proc(name, comm, int(f[1]), own, kids)
        except (OSError, IndexError, ValueError):
            continue  # exited mid-scan
    return out


def window(before: dict[Key, Proc], after: dict[Key, Proc]) -> dict[Key, int]:
    """Ticks each process spent between two scans, its reaped children included.

    A child that came and went between scans is seen only in its parent's `kids`; one that was
    alive at the first scan is subtracted as it stood then, so its earlier time is not counted
    twice. A process born after the first scan has no baseline: all its time is this window's.
    """
    gone: dict[int, int] = {}  # ppid -> what its vanished children had at the first scan
    for k, p in before.items():
        if k not in after:
            gone[p.ppid] = gone.get(p.ppid, 0) + p.own + p.kids
    zero = Proc(None, "", 0, 0, 0)
    out = {}
    for k, p in after.items():
        b = before.get(k, zero)
        out[k] = p.own - b.own + max(0, p.kids - b.kids - gone.get(k[0], 0))
    return out


def _busy() -> int:
    f = [int(x) for x in Path("/proc/stat").read_text().split("\n", 1)[0].split()[1:9]]
    return sum(f) - f[3] - f[4]  # minus idle, iowait


Sample = tuple[float, float, Parts, Parts]  # seconds, machine cores, kib parts, cores per comm


def _sample_linux(interval: float, engine: str) -> Sample:
    t0, busy0, procs0 = time.monotonic(), _busy(), _procs(engine)
    time.sleep(interval)
    dt, busy1, procs1 = time.monotonic() - t0, _busy(), _procs(engine)
    parts = dict.fromkeys(LINUX_PARTS[engine], 0.0)
    procs: Parts = {}
    for k, ticks in window(procs0, procs1).items():
        p, cores = procs1[k], ticks / HZ / dt
        procs[p.comm] = procs.get(p.comm, 0.0) + cores
        if p.part:
            parts[p.part] += cores
    return dt, (busy1 - busy0) / HZ / dt, parts, procs


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


def parse_top(text: str, ncpu: int) -> tuple[float, Parts, Parts]:
    """Machine cores, kib's parts and cores per command, from the LAST sample of `top -l N`."""
    last = text.rsplit("Processes:", 1)[-1]
    m = re.search(r"CPU usage: ([\d.]+)% user, ([\d.]+)% sys", last)
    machine = (float(m[1]) + float(m[2])) * ncpu / 100 if m else 0.0
    parts = dict.fromkeys(("vz", "lima", "view"), 0.0)
    procs: Parts = {}
    for row in re.finditer(r"^\s*\d+\s+([\d.]+)\S*\s+(.+?)\s*$", last, re.M):
        cores, name = float(row[1]) / 100, mac_part(row[2])
        procs[row[2]] = procs.get(row[2], 0.0) + cores
        if name:
            parts[name] += cores
    return machine, parts, procs


def _sample_mac(interval: float, _engine: str) -> Sample:
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
    if engine == "rootless":  # every box reads the same shared total there
        return {}, "rootless gVisor runs with --ignore-cgroups, so docker stats has none"
    env = dict(os.environ)  # rootful: the user's own Docker, as kib reaches it
    if engine == "vm":
        if not SOCK.exists():
            return {}, f"no {VM} engine socket (VM stopped?)"
        env.pop("DOCKER_CONTEXT", None)
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
        procs = sorted(
            (k for k in self.series if k.startswith("proc:")), key=self.avg, reverse=True
        )
        rows.append(("busiest processes, whole machine (any user):", ""))
        rows += [(f"  {k[5:]}", k) for k in procs[:8]]
        rows.append(("  in no process (kernel, short-lived ones)", "unattributed"))
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


class _CtrlCError(Exception):
    pass


def _on_ctrl_c(*_: object) -> None:
    # Ignore any later Ctrl-C before anything else runs: a second press must not eat the summary.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise _CtrlCError


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
    stats = Stats(f"{sys.platform}, {TITLES[engine]}")
    print(f"kib stats ({stats.title}): every {interval:g}s — Ctrl-C for the summary.", flush=True)
    signal.signal(signal.SIGINT, _on_ctrl_c)
    try:
        while True:
            dt, machine, cur, procs = sample(interval, engine)
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
            for k, v in procs.items():
                stats.add(f"proc:{k}", v)
            stats.add("unattributed", max(0.0, machine - sum(procs.values())))
            if boxes:
                stats.add("overhead", max(0.0, kib - cur["view"] - sum(boxes.values())))
            w = watts()
            if w is not None:
                stats.watts.append(w)
            top = max(boxes.items(), key=lambda kv: kv[1], default=None)
            hog = max(procs.items(), key=lambda kv: kv[1], default=("-", 0.0))
            print(
                f"{time.strftime('%H:%M:%S')}  kib {kib:4.2f}  machine {machine:4.2f} cores"
                f"  battery {f'{w:.1f} W' if w is not None else 'AC'}"
                f"  busiest process {hog[0]} {hog[1]:.2f}"
                + (f"  busiest box {top[0]} {top[1]:.2f}" if top else ""),
                flush=True,
            )
    except _CtrlCError:
        print(stats.summary(parts), flush=True)
    return cli.OK


if __name__ == "__main__":
    cli.run(main)
