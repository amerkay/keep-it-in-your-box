from __future__ import annotations

from kib.host.stats import Proc, Stats, parse_ioreg, parse_top, part, window

TOP = """Processes: 600 total
CPU usage: 50.00% user, 50.00% sys, 0.00% idle
PID    %CPU COMMAND
1      99.0 com.apple.Virtua
Processes: 600 total, 3 running
2026/11/13 13:40:05
CPU usage: 10.00% user, 2.50% sys, 87.50% idle
PID    %CPU COMMAND
1234   85.0 com.apple.Virtua
567    2.0  limactl
890    0.5  kib-view
42     30.0 firefox
"""

IOREG = """+-o AppleSmartBattery  <class AppleSmartBattery>
    {
      "ExternalConnected" = No
      "InstantAmperage" = 18446744073709550616
      "Voltage" = 12000
      "BatteryData" = {"Voltage"=1}
    }
"""


def test_part_matches_only_kibs_vm() -> None:
    qemu = "/usr/bin/qemu-system-x86_64"
    assert part("qemu-system-x86", [qemu, "-name", "lima-kib-vm"], "vm") == "qemu"
    assert part("qemu-system-x86", [qemu, "-name", "lima-kib-vm2"], "vm") is None
    fs = ["/usr/libexec/virtiofsd", "--socket-path=/h/.lima/kib-vm/v.sock"]
    assert part("virtiofsd", fs, "vm") == "virtiofsd"
    assert part("kib-view", ["/h/kib-view", "serve"], "vm") == "view"
    assert part("gvisor_sentry", ["runsc"], "vm") is None


def test_part_rootless_counts_gvisor_and_the_engine() -> None:
    assert part("gvisor_sentry", ["runsc-sandbox"], "rootless") == "gvisor"
    assert part("containerd-shim", ["containerd-shim-runc-v2"], "rootless") == "engine"
    assert part("slirp4netns", ["slirp4netns"], "rootless") == "engine"
    assert part("dockerd", ["dockerd"], "rootless", mine=False) is None  # root's own Docker
    assert part("kib-view", ["/h/kib-view"], "rootless") == "view"
    assert part("gvisor_sentry", ["runsc"], "rootful") == "gvisor"
    assert part("dockerd", ["dockerd"], "rootful") is None  # the machine's Docker, not kib's
    assert part("firefox", ["firefox"], "rootless") is None


def test_parse_top_reads_only_the_last_sample() -> None:
    machine, parts, procs = parse_top(TOP, ncpu=8)
    assert machine == 1.0  # 12.5% of 8 cores
    assert parts == {"vz": 0.85, "lima": 0.02, "view": 0.005}
    assert procs["firefox"] == 0.3


def test_parse_ioreg_on_battery_and_ac() -> None:
    assert parse_ioreg(IOREG) == 1000 * 12000 / 1e6  # -1000 mA x 12 V
    assert parse_ioreg(IOREG.replace("= No", "= Yes")) is None


def test_summary_averages_boxes_over_every_sample() -> None:
    s = Stats("linux, engine = vm")
    for machine, vm in ((2.0, 1.0), (4.0, 3.0)):
        s.n += 1
        s.add("machine", machine)
        s.add("kib", vm)
    s.add("box:kib-a", 0.5)  # lived for one of two samples
    s.add("proc:firefox", 1.0)
    out = s.summary(("qemu",))
    assert "67% of this machine's CPU (2.00 of 3.00)" in out
    assert "kib-a" in out and "avg  0.25" in out and "on AC throughout" in out
    assert "  firefox" in out and "avg  0.50" in out


def test_window_credits_reaped_children_once() -> None:
    before = {
        (1, 10): Proc("gvisor", "gvisor_sentry", 0, own=500, kids=0),
        (2, 20): Proc(None, "make", 1, own=100, kids=0),  # alive at the first scan, then reaped
        (3, 30): Proc(None, "old", 0, own=50, kids=0),
    }
    after = {
        # sentry: +40 own; kids +180 = make's 150 lifetime + 30 from helpers that came and went
        (1, 10): Proc("gvisor", "gvisor_sentry", 0, own=540, kids=180),
        (3, 31): Proc(None, "new", 0, own=20, kids=0),  # pid 3 reused: born in the window
    }
    assert window(before, after) == {
        (1, 10): 40 + 30 + 50,  # own, the helpers, make's time since the first scan; not its 100
        (3, 31): 20,
    }
