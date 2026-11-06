# Run kib in a VM

Without a VM the box shares your kernel. kib's hardening stops everything except a kernel bug, and
a kernel exploit inside the box owns your machine. Inside a VM it owns only the VM.

- **macOS:** always on. kib runs every box in its own [Lima](https://lima-vm.io) VM. Docker
  Desktop is not needed and not used.
- **Linux:** opt-in for now: `vm = on` in `~/.keep-it-in-your-box/config` (or `KIB_VM=on kib`
  once).

## Set up

The first `kib` asks once to install what is missing into `~/.local`, no sudo: Lima, Mutagen
and the `docker` command. Each download is checked against a checksum pinned in kib. Then it
creates the VM and builds the image in it, which takes a few minutes.

Linux also needs QEMU and KVM, once, with sudo:

```
ls -l /dev/kvm
command -v qemu-system-x86_64 || sudo apt-get install -y qemu-system-x86 qemu-utils
```

If `/dev/kvm` is missing, turn on virtualization (VT-x / AMD-V) in your BIOS. If it shows
`root kvm` and you are not in the `kvm` group, run `sudo usermod -aG kvm "$USER"` and log in again.

## What kib does

- **kib stays on your machine; only Docker moves into the VM.** Same `~/.claude`, login,
  `--resume` history and broker routes, with or without the VM.
- **One VM, `kib-vm`.** It starts with your first session and stops when the last one closes.
  Opening and closing projects never restarts it.
- **Your project is synced, never mounted.** Mutagen copies it into a VM volume through a
  host-local copy that drops every redacted and protected file, so `.env` values never reach the
  VM and the VM cannot write `.git/hooks`. Edits flow both ways within about a second.
- **The host wins a conflict.** If you and the box change the same file at once, your version is
  kept. The box is told to re-read before editing.
- **Build folders stay in the VM:** `node_modules`, `.venv`, `target`, `.next`, `.nuxt`, `.turbo`
  are built there, for Linux, and never sync.
- **Closing a project deletes its volume.** If the last sync fails, kib keeps it, and the next
  launch carries the edits back.
- **The VM sees only this**, at the same paths:

  | Path | VM access |
  |---|---|
  | kib's own checkout | read-only |
  | `~/.claude/{plugins,skills,agents,commands,hooks}` | read-write |
  | the VM's Node cache, `~/.cache/keep-it-in-your-box/node-vm` | read-write |
  | `…/keep-it-in-your-box/vm-rw`: open projects' sessions and transcripts | read-write |
  | `…/keep-it-in-your-box/vm-ro`: rules, and broker tokens of routes in use | read-only |

  Never your home folder, a project folder, `~/.ssh`, `~/.keep-it-in-your-box`, or `~/.claude`'s
  credential, `settings.json` or `CLAUDE.md`.

## Limits

- **A kernel exploit in the VM** can write the shared `~/.claude` trees above, which load in every
  project. kib reports such writes at teardown.
- **Don't run the same project with and without the VM at the same time.**
- **A kib update that changes the VM's mounts** restarts it once, and waits until no session is
  open.

## Licenses

Lima: Apache-2.0. Mutagen: MIT, with SSPL parts in its release build (fine for local use). The
`docker` command: Apache-2.0.

## Manage it

| To | Run |
|---|---|
| Turn it on / off (Linux) | `vm = on` / `vm = off` in `~/.keep-it-in-your-box/config` |
| Resize | `limactl stop kib-vm && limactl edit kib-vm --cpus 4 --memory 8` |
| Start from scratch | `limactl delete -f kib-vm` — the next `kib` creates it again |
| Stop it now | `limactl stop kib-vm` (kib does this when your last session closes) |

CPU and memory are limits, not reservations. The VM uses what it needs, up to those limits.
