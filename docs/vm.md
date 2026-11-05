# Run kib in a VM (Linux)

On Linux the box shares your kernel. kib's hardening stops everything except a kernel bug, and a
kernel exploit inside the box owns your machine. Inside a VM it owns only the VM. macOS and
Docker Desktop already work this way.

Install [Lima](https://lima-vm.io) once. From then on `kib` and `cc` run every box in a VM, with
nothing to configure.

## Set up (once, about 5 minutes)

Check that your machine can run a VM:

```
ls -l /dev/kvm
command -v qemu-system-x86_64 || sudo apt-get install -y qemu-system-x86 qemu-utils
```

If `/dev/kvm` is missing, turn on virtualization (VT-x / AMD-V) in your BIOS. If it shows
`root kvm` and you are not in the `kvm` group, run `sudo usermod -aG kvm "$USER"` and log in again.

Install Lima into `~/.local` (no sudo):

```
mkdir -p ~/.local
VERSION=$(curl -fsSL https://api.github.com/repos/lima-vm/lima/releases/latest | jq -r .tag_name)
curl -fsSL "https://github.com/lima-vm/lima/releases/download/${VERSION}/lima-${VERSION:1}-$(uname -s)-$(uname -m).tar.gz" | tar Cxzvm ~/.local
curl -fsSL "https://github.com/lima-vm/lima/releases/download/${VERSION}/lima-additional-guestagents-${VERSION:1}-$(uname -s)-$(uname -m).tar.gz" | tar Cxzvm ~/.local
grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

Open a new terminal and run `kib`. The first launch creates the VM and builds the image in it,
which takes a few minutes. After that, the VM starts in seconds with your first session.

## What kib does

- **kib stays on your machine; only Docker moves into the VM.** That means the same `~/.claude`,
  the same login, the same `--resume` history and the same broker routes, with or without the VM.
  Turning it off changes nothing else.
- **One VM, `kib-vm`.** It starts with your first kib session and stops when the last one closes.
- **The VM sees only what the box needs**, at the same paths:

  | Path | VM access |
  |---|---|
  | your project folders | read-write |
  | `~/.claude/{plugins,skills,agents,commands,hooks,projects}` | read-write |
  | kib's state and Node cache under `~/.local` and `~/.cache` | read-write |
  | `~/.keep-it-in-your-box`, kib's own checkout | read-only |

  Never your home folder, `~/.ssh`, or `~/.claude`'s credential, `settings.json` or `CLAUDE.md`.
- **It asks once per new folder.** The first time you run kib in a project, it asks whether the VM
  may see the whole parent folder, e.g. `~/devel`. Answer yes and every project in that folder
  works with no VM restart. Answer no to mount only this project. It never offers `$HOME`,
  `~/Desktop`, `~/Documents` or `~/Downloads`.
- **The VM restarts when it needs a new mount.** A project outside every mounted folder needs one.
  kib refuses while other sessions are still using the VM.

## What changes in the VM

- **No image paste from your clipboard.** The VM can't reach your desktop's Wayland socket.
- **`host.docker.internal`** reaches the VM, not your machine.
- **Don't run the same project with and without the VM at the same time.** That gives two
  containers sharing one session folder.
- **The VM's limit:** a kernel exploit inside it can write to every read-write folder above,
  including `.git/hooks` and `~/.claude/hooks`, without going through kib's in-box guards. kib
  still reports these writes at teardown. Mount as narrowly as you can.

## Manage it

| To | Run |
|---|---|
| Turn it off | add `vm = off` to `~/.keep-it-in-your-box/config` (or `KIB_VM=off kib` once) |
| See mounted folders | `cat ~/.local/state/keep-it-in-your-box/vm-roots` |
| Remove a mount | delete its line from that file, then `limactl delete -f kib-vm` |
| Resize | `limactl stop kib-vm && limactl edit kib-vm --cpus 4 --memory 8` |
| Start from scratch | `limactl delete -f kib-vm` — the next `kib` creates it again |
| Stop it now | `limactl stop kib-vm` (kib does this when your last session closes) |

CPU and memory are limits, not reservations. The VM uses what it needs, up to those limits.
