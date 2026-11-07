# The VM and gVisor

kib runs every box on [gVisor](https://gvisor.dev) inside its own [Lima](https://lima-vm.io) VM,
on Linux and macOS alike. A kernel exploit in the box meets gVisor's kernel first, then the VM's,
never yours. Docker Desktop is not needed and not used.

## Set up

The first `kib` asks once to install what is missing into `~/.local`, no sudo: Lima, the `docker`
command and `docker buildx`. Each download is checked against a checksum pinned in kib. Then it
creates the VM, installs gVisor into it (also pinned) and, on macOS, bindfs, and builds the image there. That takes a
few minutes.

Linux also needs QEMU, KVM and virtiofsd, once, with sudo:

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
  one closes, so a quick reopen skips the boot. Opening and closing projects never restarts it.
- **The VM mounts your home folder**, once, over virtiofs. The box sees your project only through
  kib's redaction view, so `.env` values stay hidden and `.git/hooks` stays read-only. Projects
  outside your home folder are refused.
- **Edits are live both ways.** A host edit raises no file-watch event in the box, so dev servers
  there watch by polling.
- **Build folders stay in the VM**, built there for Linux: `node_modules`, `.pnpm-store`, `.venv`,
  `venv`, `target`, `.next`, `.nuxt`, `.turbo`, `.terraform`. Package downloads stay in the
  project's cache volume (`kib-<project>-<hash>-cache`), so a reinstall copies instead of
  downloading.

## Limits

- **gVisor and VM root can read and write your home folder** if an exploit gets that far: it
  would need a gVisor bug and then a VM kernel bug.
- **Small-file writes are ~1.6–2× slower** in the box than on the host. Installs stay fast
  because build folders are VM volumes.
- **macOS reports every file as owned by whoever asks.** gVisor asks as root, so kib puts bindfs
  over the folders it mounts into the box (`~/.claude`, its state, its checkout, the Node cache)
  to report you as their owner.
- **A kib update that changes the VM's mounts** restarts it once, and waits until no session is
  open.

## Licenses

Lima: Apache-2.0. gVisor: Apache-2.0. The `docker` command: Apache-2.0.

## Manage it

| To | Run |
|---|---|
| Resize | `limactl stop kib-vm && limactl edit kib-vm --cpus 4 --memory 8` |
| Start from scratch | `limactl delete -f kib-vm` — the next `kib` creates it again |
| Stop it now | `limactl stop kib-vm` (kib does this 10 minutes after your last session) |

CPU and memory are limits, not reservations. The VM uses what it needs, up to those limits.
