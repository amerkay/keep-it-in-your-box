# Plan: the redaction view runs on the host and serves NFS; the VM never sees a raw project

**Status 2026-11-09: proposed, not implemented.** Replaces the per-project VM shares and the restart-and-resume path from `3a5d9c5`. Test scripts (untracked): `tmp/nfs-bench-linux.py`, `tmp/nfs-bench-mac.py`, `tmp/gvisor-rootless-test.sh`, `tmp/rootless-view-test.sh`.

## Goals

- **No private files in the VM.** Never `~`, never a project's siblings, never a raw project. VM root sees only redacted views.
- **No VM restart, ever, for opening a project.** A restart ends every session, and Claude's unsent input is lost with it (seen live: text typed in a session was gone after the restart, even though `--resume` brought the conversation back).
- **No drift between Linux and macOS.** One design, one front end.
- **Nothing to install, no `sudo`.** Same as today.
- **No slower than today**, ideally faster.

## How we got here

- **2026-11-04:** the user objected to mounting `~` into the VM. The Mutagen sync replaced it, then the gVisor plan (`15dcc62`) brought the `~` mount back without flagging it.
- **`3a5d9c5`:** the VM shares only opened projects. A new project restarts the VM: kib asks if a session is busy (the sleep guard's verdict), keeps every running box's project shared, and each cut session relaunches with `--resume <id>` and its own flags.
- **First real use:** the idle restart worked, but the user lost the text they had typed and not sent. Restarting is not acceptable, so the share set must never change while the VM runs.

## Options considered

| Option | Verdict | Why |
|---|---|---|
| Suspend or hibernate the VM, change mounts, resume | ❌ | Each session's terminal is a `docker exec` stream through Lima's host agent, which dies with the VM. A restored VM must have the same devices, so a mount can't be added across it. |
| Hardlinks or symlinks into one shared folder | ❌ | Folders can't be hardlinked. Symlinks resolve inside the VM, where the target doesn't exist. |
| Share each project's parent folder | ❌ | Fewer restarts, but shares every sibling project. Rejected by the user. |
| QEMU hot-plug of virtiofs devices | ❌ | Linux only, untested, against Lima's internals. Patching Lima is ruled out. |
| One VM per project | ❌ | RAM; the VM already ran out at 4 GiB. |
| Host bind mounts into one share, via user namespaces | ❌ | Ubuntu 24.04+ blocks unprivileged user namespaces by default. |
| Host FUSE passthrough in front of the VM's FUSE view | ❌ | Two FUSE layers: 1.5–1.8× slower (Test 2), and no safer. |
| macFUSE | ❌ | Kernel backend needs Recovery mode on Apple Silicon. FSKit backend mounts only under `/Volumes`, is slower per its own docs, needs an install and a System Settings switch, and has open hang bugs. |
| FUSE-T | ❌ | Needs an install; it is NFS underneath anyway. |
| SMB from Go | ❌ | The only Go SMB server (`macos-fuse-t/go-smb2`) is AGPL or commercial, which can't ship in MIT kib, and its README doesn't mention change notifications. |
| Host view, Linux FUSE + macOS host NFS client + virtiofs | ❌ | Works, but two front ends (drift). The macOS client half was slower, needs owner bits faked, can't unmount while the VM holds it, and threw "Stale file handle" (Tests 4–7, 10). |
| **Host view serving NFS, mounted by the VM over Lima's network** | ✅ | One front end on both OSes. As fast as a direct share for reads and `git status`, edits seen in ~5 ms, no host mounts at all (Tests 9–10). |

## Test results

All timings are taken inside the VM. `git status` is `-uno`, five runs. Reads read every tracked file, warm. Writes create 500 small files. "Host edit" is how long a change made on the host takes to show up in the VM.

### Test 1: Linux, does the VM see a mount added after it started?

- `sudo mount --bind` into a shared folder: ✅ visible in the VM at once.
- FUSE (`bindfs --no-allow-other`, no `sudo`): ✅ visible.
- Unmounting while the VM holds it: "target is busy"; `umount -l` / `fusermount3 -u -z` work.
- `bindfs` adds `allow_other` by default, which Ubuntu refuses for users; `--no-allow-other` fixes it. kib's FUSE view hard-codes `AllowOther: true` today.

### Test 2: Linux, host FUSE added in front of a direct share

| | Direct | Host FUSE added |
|---|---|---|
| `git status` ×5 | 109 ms | 194 ms (1.8×) |
| 500 writes | 134 ms | 199 ms (1.5×) |

All 500 writes reached the host.

### Test 3: macOS 26.7.1, live mounts and user NFS

- `hdiutil attach` (no `sudo`) into a shared folder after VM start: ✅ the VM read the file.
- `mount_nfs` as a normal user against a stub server in stock `python3`: ✅ mounted with no `sudo`.
- The VM read that NFS mount through Apple's virtiofs: ✅.
- A dead NFS mount (server gone) left "not responding" and blocked recreating the folder. It must never be left under a folder the VM shares.

### Test 4: macOS, the Mac's own NFS client (`go-nfs` server) at default and zero caching

| | Direct | NFS default | NFS `actimeo=0` |
|---|---|---|---|
| `git status` ×5 | 60 ms | 287 ms (4.8×) | 1068 ms (18×) |
| Read every file | 51 ms | 54 ms | 176 ms |
| 500 writes | 212 ms | 625 ms | 1424 ms |
| Host edit | 3 ms | **4082 ms** | 4 ms |
| git commit / `chmod +x` | | FAILED / FAILED | |
| rename, symlink, flock | | ok | |
| AppleDouble `._` files | | 0 | |
| Unmount | | `diskutil unmount force` | after the VM drops caches |

### Test 5: macOS, the Mac's NFS client with a 1 s cache

| | Direct | `actimeo=1` | `actimeo=1,rdirplus` |
|---|---|---|---|
| `git status` ×5 | 48 ms | 81 ms | 76 ms |
| Read every file | 55 ms | 51 ms | 49 ms |
| 500 writes | 217 ms | 653 ms | 623 ms |
| Host edit | 4 ms | 854 ms | 449 ms |
| New host file | 2 ms | 907 ms | 937 ms |
| git commit | | FAILED | |
| `chmod +x`, rename, symlink, flock | | ok | |

The server now supports mode changes (`billy.Change`), which fixed `chmod +x`.

### Test 6: macOS, where the view sits

| | Direct | FUSE in the VM (today's view position, `bindfs`) | Mac NFS client (`actimeo=1,rdirplus`) |
|---|---|---|---|
| `git status` ×5 | 51 ms | **1254 ms (24×)** | 77 ms |
| Read every file | 50 ms | 193 ms | 55 ms |
| 500 writes | 210 ms | (test bug: folder unwritable) | 646 ms |
| Host edit | | | 686 ms |
| Non-root gVisor box writes | ❌ Permission denied | | ✅ with owner bits copied to group/other (seen as uid 0, `rw-rw-rw-`) |
| git commit | | | FAILED: "object file … is empty" |
| Hard link | | | FAILED: Remote I/O error |
| fsync | | | ok |

Apple's virtiofs reports the asking process as each file's owner. gVisor's gofer asks as root, so a non-root box user is locked out unless the mode bits let "other" write.

### Test 7: macOS, git commit root cause

| | Before fix | After owner-write fix |
|---|---|---|
| git commit on the Mac, NFS only | FAILED: "error when closing loose object file: Permission denied" | ok |
| git commit in the VM | FAILED: "object file … is empty" | ok |
| write, rename, read ×50, mode 644 | | ok |
| write, rename, read ×50, mode 444 | 50 of 50 wrong | ok |

Cause: git creates objects read-only (0444), then writes them. NFS v3 checks permission on every WRITE, and `go-nfs` reopens the file per write, so the owner's own read-only file refuses it. Real NFS servers let the owner write anyway. Fix in the server: on a permission error for the owner, add `u+w`, open, restore the mode. The macOS NFS client keeps data intact.

### Test 8: Linux, where the view sits

| | Direct | FUSE in the VM (today) | FUSE on the host |
|---|---|---|---|
| `git status` ×5 | 73 ms | 462 ms (6.3×) | 85 ms (1.2×) |
| Read every file | 53 ms | 154 ms | 55 ms |
| 500 writes | 189 ms | 441 ms | 282 ms |
| Host edit | 5 ms | 4 ms | 4 ms |

Today's view position is the slow one on both OSes.

### Test 9: Linux, the VM mounts the host's NFS view over Lima's network (two runs)

| | Direct | Host FUSE | **VM mounts NFS** |
|---|---|---|---|
| `git status` ×5 | 71 / 50 ms | 176 / 196 ms | **41 / 41 ms** |
| Read every file | 31 / 32 ms | 38 / 45 ms | 39 / 40 ms |
| 500 writes | 112 / 121 ms | 208 / 156 ms | 269 / 207 ms |
| Host edit | | 3 / 3 ms | **4 / 4 ms** |
| git commit, write-rename-read 0444 ×50, non-root gVisor write | | | ✅ ✅ ✅ |

Mount: `vers=3,proto=tcp,port=P,mountport=P,mountproto=tcp,nolock,actimeo=1,soft,timeo=10,retrans=2` at `192.168.5.2` (Lima's address for the host's 127.0.0.1). `nfs-common` installed in the VM.

### Test 10: macOS, the same, against the Mac's own NFS client

| | Direct | Mac NFS client | **VM mounts NFS** |
|---|---|---|---|
| `git status` ×5 | 64 ms | 78 ms | **61 ms** |
| Read every file | 52 ms | 6 ms (cached) | 46 ms |
| 500 writes | 209 ms | 654 ms | **471 ms** |
| Host edit | | 310 ms | **5 ms** |
| git commit, write-rename-read ×50, non-root gVisor write | | "Stale file handle" during git | ✅ ✅ ✅ |

### Test 11: Linux, gVisor under rootless Docker (Docker 29.2.1 rootless, cgroup v2, Ubuntu)

| | Result |
|---|---|
| `runsc --rootless do true`, no Docker | FAILED: "re-executing self: fork/exec /proc/self/exe: permission denied" (very likely Ubuntu's AppArmor rule against unprivileged user namespaces) |
| `docker run --runtime runsc` | FAILED: "systemd error: Access denied as the requested operation requires interactive authentication" (runsc asks the system's systemd for cgroups) |
| `docker run --runtime runsc --ignore-cgroups` | ✅ `Starting gVisor...`, kernel `4.19.0-gvisor` |

Script: `tmp/gvisor-rootless-test.sh`. It adds runtimes to `~/.config/docker/daemon.json` (backed up, restored on exit) and reloads by sending HUP to `dockerd` only. **Never `systemctl --user kill -s HUP docker.service`:** it signals the whole unit, rootlesskit and containerd included, and took containerd down (two runs, user's containers stopped).

### Test 12: Linux, can a no-VM box under rootless Docker get the view?

| Route | runc | gVisor (`--ignore-cgroups`) |
|---|---|---|
| A. Docker mounts the NFS view as a volume (`type=nfs`, at `10.0.2.2` and `127.0.0.1`) | ❌ "failed to mount local volume" | ❌ same |
| B. Host FUSE (`bindfs --no-allow-other`) bound in, box as root | ✅ read + write, owner seen as 0 | ✅ read + write, owner seen as 0 |
| B. Same, box as uid 1000 | ❌ can't even read | ❌ reads, can't write (owner 0) |
| Plain folder, box as root | | ✅ read + write |

Rootless Docker runs inside a user namespace, where Linux refuses NFS mounts. The host user is root inside a rootless box, so a FUSE mount owned by that user needs no `allow_other`, as long as the box runs as root. kib's old rootless support already did that (`platform-matrix.md`: `box_uid` 0, `IS_SANDBOX=1`). Script: `tmp/rootless-view-test.sh`.

## Decision

**The redaction view runs on the host as an NFS server. The VM mounts it; the box binds the VM's mount at the project's real path.** Same on Linux and macOS.

## Design

1. **One Go view, one front end in VM mode.** The redaction core (rules, renderers, write guards) moves out of `guest/fuse` to a host-side folder. A new NFS front end uses `go-nfs` (Apache-2.0). The existing spec (`tests/fixtures/redaction`) runs against the NFS side. The FUSE front end is deleted, unless phase 4 (no-VM Linux) is built, which needs it (Test 12).
2. **Server rules:**
   - The owner may write their own read-only files (Test 7).
   - Hard links are supported (git tries `link()` first).
   - Mode and time changes are supported (`chmod +x`, Test 5).
   - Listens on 127.0.0.1, random port, one server per project.
3. **Built by `kib build`.** The Go stage cross-compiles for linux/darwin × amd64/arm64 and kib copies the host's binary to `$KIB_STATE_ROOT/bin`. Users install nothing.
4. **Lifecycle per project:**
   - First session: start the view, detached, lock fds closed (200/201/205/206).
   - VM root mounts it at `/mnt/kib/<hash>` with the Test 9 options. `nfs-common` is installed in the VM once, like `bindfs` on macOS.
   - The box binds `/mnt/kib/<hash>` at `$PWD`. `local_dirs` volumes still mount below it.
   - Last session out: `umount -l` in the VM, then stop the view.
5. **The VM's shares become fixed:** `~/.claude`, `$KIB_STATE_ROOT`, the Node cache, kib's checkout. They never change, so the VM never restarts for a project. Any folder can be a project, inside `~` or not.
6. **`gitguard`:** `_tracked_matches` runs the view's `match` command on the host, not in a container with the raw repo bound.
7. **Rule reloads:** the rule watcher signals the host view process instead of the sidecar.
8. **macOS keeps `bindfs` in the VM** over `~/.claude` and `$KIB_STATE_ROOT` only. Projects need no owner workaround: the VM's Linux NFS client sees real uids (Test 10, non-root gVisor write ok).

## Security

- **VM root sees only redacted views.** `.env` values never enter the VM, and `.git/hooks` stays unwritable even after a gVisor bug plus a VM kernel bug. Today VM root can read and write the raw project.
- **The NFS port is reachable by every box**, because boxes reach host services through `192.168.5.2` by design, and by any local account on the host. Without a defence, project B's box could mount project A's view. Defences:
  - The server accepts exactly one mount (kib's, at launch) and refuses every later request to mount.
  - File handles are random 128-bit values, never derived from paths or inodes.
  - One port per project.
  - Check whether the VM can stop boxes reaching view ports at all, and add that if cheap.
- **`security-test.sh` additions:** a box can't mount its own or another project's view, and can't guess a handle.
- **The FUSE sidecar's `SYS_ADMIN` goes away.**
- **Residual, unchanged:** VM root can read `~/.claude` (including `.credentials.json`), kib's state (the broker tokens in use) and the Node cache.

## Behaviour notes

- **Freshness:** the VM's NFS client re-checks a file when it is opened, so edits showed in 4–5 ms. A watcher that only `stat`s without opening can see a change up to 1 s late (`actimeo=1`). Dev servers already poll.
- **Locks:** `nolock`, so `flock`/`fcntl` locks are local to the VM. Fine for a single box per project.
- **If the view process dies**, the `soft` mount returns I/O errors in the box until the next launch remounts it.
- **Writes cost ~1.7× (Linux) to 2.3× (macOS)** a direct share, still better than today's view position.
- **Upgrade:** the first launch after the change alters the VM's share list, so the VM restarts once. With sessions open, kib refuses and asks to close them, as before `3a5d9c5`.

## Does this remove the VM?

No.
- **macOS:** containers need a Linux kernel, which a Mac only has inside a VM. kib can't install gVisor into Docker Desktop's VM.
- **Linux: possible, at a cost (Tests 11–12).** gVisor runs under rootless Docker with `--ignore-cgroups`, so no root-equivalent socket is needed. The earlier claim that it needs rootful Docker (`CLAUDE.md`, `microvm.md`, google/gvisor#12575 as cited) is wrong for this machine. What a no-VM mode loses:
  - **One barrier instead of two.** A kernel exploit needs a gVisor bug only, not a gVisor bug plus a VM kernel bug. It lands as the user's own uid (rootless), not root.
  - **No cgroup limits** for gVisor boxes: no memory or CPU caps, so one box can starve the machine.
  - **The view must be a host FUSE mount**, because rootless Docker can't mount NFS (Test 12). So a no-VM mode needs the FUSE front end next to NFS. That is the existing `guest/fuse` code, run on the host with `allow_other` off, not new code.
  - **The box runs as root inside the container**, which is the host user outside. This is kib's old rootless path (`box_uid` 0, `IS_SANDBOX=1`, `platform-matrix.md`).
- **Recommendation:** the VM stays the default on both OSes, with the NFS view. No-VM is an opt-in Linux mode, phase 4: rootless Docker, gVisor with `--ignore-cgroups`, the FUSE view on the host, box as root. Drift is limited to that mode, and the redaction core stays shared.

## Phases

1. **NFS front end** over the existing core, in Go, passing the redaction spec plus the Test 7 and hard-link cases.
2. **Host lifecycle and VM mount** on Linux, verified with `tmp/nfs-bench-linux.py`-style checks. Then the Mac, with a pasted block.
3. **Deletions and docs:**
   - The FUSE sidecar, its `SYS_ADMIN`, the `/mnt/kib` propagation root and the VM mount-table attach checks (`host/redaction.sh`).
   - `vm-roots`, `vm_project_ok`, `_vm_evict`, `vm_resume`, `_vm_resume_args`, the `sid.<id>` marker and `kib_sessions` (`host/vm.sh`, `host/session-state.sh`, `guest/policy/sleep-hook.py`).
   - `CLAUDE.md`'s settled dead ends: propagation root, sidecar, VM mounts, FUSE view rules.
   - `docs/design-notes/microvm.md`, `redaction-config-guard.md`, `macos.md`, `docs/vm.md`.

4. **Optional no-VM Linux mode:** rootless Docker, gVisor with `--ignore-cgroups`, the FUSE front end mounted on the host (no `allow_other`), the box as root inside. Brings back kib's rootless path from `platform-matrix.md`.

Each phase: `./dev.sh check`, then `security-test.sh` inside a sandbox.

## Open questions

- Can the VM's network rules stop boxes reaching view ports without blocking host dev servers?
- `go-nfs` maturity: one main maintainer. Pin it, and keep the spec tests as the safety net.
- `rdirplus` / `actimeo` tuning for the VM's Linux client (only the Mac client was tuned).
- No-VM rootless mode (Tests 11–12): can gVisor get cgroup limits under rootless Docker (a `cgroupfs` path in the delegated user slice, or user-level systemd)? Without them one box can use all memory.

## Testing gotchas

- `limactl shell` reads stdin: inside a pasted script it swallows the rest of the script. Give it `</dev/null`.
- Long pasted blocks can arrive truncated. Python fails with a `SyntaxError` before running anything; bash may run half of it.
