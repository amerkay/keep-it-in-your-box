# The VM and gVisor

kib runs every box on [gVisor](https://gvisor.dev). On macOS, and on Linux without rootless Docker, it runs inside kib's own [Lima](https://lima-vm.io) VM: a kernel exploit in the box meets gVisor's kernel first, then the VM's, never yours. On Linux with rootless Docker, the box runs there directly, which costs about half as much CPU ([No-VM mode](#no-vm-mode-linux-default)). Docker Desktop is not needed and not used.

## Set up

The first `kib` asks once to install what is missing into `~/.local`, no sudo: Lima, the `docker`
command and `docker buildx`. Each download is checked against a checksum pinned in kib. Then it
creates the VM, installs gVisor into it (also pinned) and, on macOS, bindfs, and builds the image there. That takes a
few minutes.

For the VM, Linux also needs QEMU, KVM and virtiofsd, once, with sudo:

```
ls -l /dev/kvm
sudo apt-get install -y qemu-system-x86 qemu-utils virtiofsd
```

If `/dev/kvm` is missing, turn on virtualization (VT-x / AMD-V) in your BIOS. If it shows
`root kvm` and you are not in the `kvm` group, run `sudo usermod -aG kvm "$USER"` and log in again.

## What kib does

- **kib stays on your machine; only Docker moves into the VM.** Same `~/.claude`, login,
  `--resume` history and broker routes.
- **One VM, `kib-vm`.** It starts with your first session and stops 10 minutes after the last
  one closes, so a quick reopen skips the boot.
- **4 GiB of memory, more only when needed.** The VM keeps what it has used until it stops, so
  kib starts it small, with compressed swap inside it so a spike slows a box down instead of
  stopping it. If it still runs out, kib tells you and doubles it from its next start, up to
  half your RAM.
- **It stays up to date.** Ubuntu installs security updates, kernel included, in the background;
  Docker updates when the VM stops, the one moment it cuts no session. Both apply at the next start.
- **The VM never mounts your home folder or a project.** It shares only `~/.claude` and kib's own folders, so `~/.ssh`, `~/.aws` and every project stay out of it, and it never restarts to open one. Each project reaches it as kib's redaction view, which runs on your machine and which the VM mounts over its network (NFS). So `.env` values never enter the VM and `.git/hooks` stays read-only, even to VM root.
- **Edits are live both ways.** A host edit raises no file-watch event in the box, so dev servers
  there watch by polling.
- **Build folders stay in the VM**, built there for Linux: `node_modules`, `.pnpm-store`, `.venv`,
  `venv`, `target`, `.next`, `.nuxt`, `.turbo`, `.terraform`. Package downloads stay in the
  project's cache volume (`kib-<project>-<hash>-cache`), so a reinstall copies instead of
  downloading.
- **Docker uses its classic storage**, one copy of each image instead of two. An older VM is moved once at its next start, and the image rebuilds once.
- **It cleans up after itself**, once a day at a project's last exit, and shows what it freed: stopped containers, old kib images, unused base images, the build cache (the image carries its own, so a rebuild stays fast), and the volumes of any project closed for 14 days. A `fstrim` then hands the space back to your disk; the VM's idle stop also clears apt's cache and old logs. Set the days with `cleanup_days = 30` in `~/.keep-it-in-your-box/config`, or `0` to keep every project's volumes.

## Limits

- **gVisor and VM root can read and write what the VM shares** if an exploit gets that far: each open project's redacted view, `~/.claude` and kib's state, including the broker tokens in use. It would need a gVisor bug and then a VM kernel bug.
- **Small-file writes are ~2× slower** in the box than on the host. Installs stay fast because build folders are VM volumes.
- **A stat-only file watcher sees a host edit up to 1 s late.** A file is re-checked whenever it is opened, so editors and builds see edits at once.
- **macOS reports every file as owned by whoever asks.** gVisor asks as root, so kib puts bindfs
  over `~/.claude` and its own state folder to report you as their owner.
- **A VM restart ends `kib exec` shells and in-flight turns.** It happens only when a kib update changes the VM's shares, and kib asks you to close your sessions first.

## Licenses

Lima: Apache-2.0. gVisor: Apache-2.0. The `docker` command: Apache-2.0.

## Manage it

| To | Run |
|---|---|
| Resize | `limactl stop kib-vm && limactl edit kib-vm --cpus 4 --memory 8` |
| Start from scratch | `limactl delete -f kib-vm` — the next `kib` creates it again |
| Stop it now | `limactl stop kib-vm` (kib does this 10 minutes after your last session) |

On Linux keep memory under half your RAM: QEMU holds the VM's memory in `/dev/shm`, which is
that size.

## No-VM mode (Linux default)

If [rootless Docker](https://docs.docker.com/engine/security/rootless/) is running, kib uses it instead of the VM, with no setting needed. The first `kib` asks once to add gVisor to `~/.config/docker/daemon.json` and reloads Docker.

Otherwise the first `kib` shows a menu (↑/↓, Enter), and `kib engine` shows it again later:

| Pick | Speed | Enter does |
|---|---|---|
| Rootless Docker + gVisor | fastest, safest | sets it up as you if its packages are there, else prints the sudo steps and quits |
| Your Docker + gVisor | fastest; an escape lands as root | starts if gVisor is registered, else prints the sudo steps and quits |
| kib's VM | slowest on Linux | starts (Lima installs into `~/.local`), else prints the QEMU steps and quits |

**kib never runs `sudo`.** Steps it prints are yours to paste; the pick is saved in `~/.keep-it-in-your-box/config`, so the next `kib` just starts. On your own rootful Docker the box runs as you, boxes keep their memory and CPU limits, and each launch says rootless is safer. Its one-time steps register a pinned, checksummed gVisor in `/opt/kib-gvisor` and set `user_allow_other` in `/etc/fuse.conf`, so root's Docker can read kib's redaction view.

With rootless Docker, what changes:

- **One barrier instead of two.** A gVisor bug alone reaches your machine, as your user (rootless Docker never had root).
- **No memory or CPU limits for boxes.** Rootless Docker runs gVisor only with `--ignore-cgroups`, so one box can use all your memory.
- **The box runs as root inside its container,** which is your own user outside. The redaction view is a FUSE mount on your machine, since rootless Docker cannot mount NFS. Everything kib refuses is still refused.
- **Host dev servers** are at `host.docker.internal` (RootlessKit's `10.0.2.2`), and only if rootless Docker allows host loopback: `DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false` in its user unit.
- **Needs** `fusermount3` (package `fuse3`) and systemd-resolved (kib reads `/run/systemd/resolve/resolv.conf` for the box's DNS).

The config lines behind the menu: `vm = on` always uses the VM; `vm = off` never does; `docker = rootless` or `docker = rootful` picks which Docker. A pick that is not set up yet prints its steps and stops, never falls back. On macOS, `vm = off` is refused, saying how to fix it.
