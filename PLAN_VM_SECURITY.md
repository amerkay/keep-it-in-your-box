# Plan: VM isolation without exposing user files

A container escape must not reach your machine's kernel or files beyond what kib needs.
kib on the host, Docker in a VM, and only **open** projects go into that VM.

## Requirements

**Security**
- Protection against kernel 0-days, not just known CVEs
- Prevention, not detection after a compromise
- No guessing which syscalls a 0-day will use
- A VM boundary on Linux and macOS
- No user files in the VM except open projects
- Never `~`, `/Users`, `~/.ssh` or a parent folder
- `.env` and `.kibignore`-redacted files never reach the VM
- Egress firewall: out of scope

**UX/DX**
- Works on 5+ open projects, opened and closed all day, with **no VM restarts**
- Never lose session progress
- Lima present → VM used automatically; missing → prompt to install, then on
- Mutagen missing → refuse, `Y/n` install prompt
- Prompts block before Claude's screen takes over; key notices are printed again after exit
- No sudo install
- Built into `kib` / `cc`
- No setup again: same `~/.claude`, login, `--resume` history, broker
- Works with and without the VM, switchable
- VM starts with the first session and stops when the last closes

**Platforms**
- Linux: Lima VM; native fallback when Lima is absent
- macOS: Lima or Colima (no license needed), Docker Desktop as fallback
- Docker Desktop: kib narrows its `/Users` sharing itself, no clicking

**Correctness and priorities**
- Same paths on the host, in the VM, in the box
- Security and UX/DX first, then least code and maintenance
- No VM per project (overkill)
- Security tests updated to cover all of this

## Decisions

| Topic | Decision |
|---|---|
| Layout | kib on the host; Docker in one kib-managed Lima VM (`kib-vm`, rootful). The same on Linux and macOS |
| Project files | Mutagen sync into a per-project Docker volume in the VM. No project mounts |
| Mutagen build | Official release (MIT core plus SSPL speed-ups; local use is fine) |
| Conflicts | **Host wins** (`two-way-resolved`, host = alpha). Claude is told in `etc-CLAUDE.md`; kib lists the overwritten files after exit |
| Closed project | Flush the sync, terminate it, delete the volume |
| Build output | `node_modules`, `target`, `.venv`, `dist`, … stay in the VM, not synced |
| Other host data | **Hybrid**: mount what is global anyway (kib checkout read-only; `~/.claude/{skills,plugins,agents,commands,hooks}` read-write). Sync the open project's slices (transcripts, state). Copy in only the broker tokens of routes in use |
| Lima missing | Linux: run natively after the install prompt. macOS: Docker Desktop fallback |
| Docker Desktop | Refuse while `/Users` is shared. After `Y/n`, kib narrows the sharing list and restarts Docker Desktop |

## Goals (done = all true)

1. On every VM setup, the VM holds only: kib's checkout (read-only), the 5 shared `~/.claude` trees,
   and open projects, without their redacted files.
2. Opening or closing any project never restarts the VM or touches another session.
3. Switching VM mode on or off changes nothing else: same login, history and broker.
4. `security-test.sh` (inside the box) and `tests/vm-check.sh` (on the host) pass on all four
   setups.

## Checklist

### Phase 0: spikes (host-side, before code)
- [ ] **S1** Mutagen Docker transport → a volume-backed sync container in `kib-vm`: initial sync
      time on a big repo, lag, host-wins conflicts, symlinks, exec bits, UID 1000, `.git`, deletes,
      file-change events in the box
- [ ] **S2** `.kibignore` and the global guard → Mutagen ignores: check the `!`, root-anchored and
      folder-seal rules map 1:1
- [ ] **S3** macOS Docker Desktop: where the file-sharing list lives (`settings-store.json`,
      `FilesharingDirectories`); whether an edit plus restart applies it; whether an org admin lock
      blocks it
- [ ] **S4** FUSE root at `/mnt/kib` in the Lima VM passes Ubuntu's `fusermount3` AppArmor profile
- [ ] **S5** Protected paths (`.git/config`, `.git/hooks`, `.vscode`, …) synced **host→VM only**,
      so a VM escape can't plant them on the host. Fallback: the teardown audit, as today
- [ ] **S6** Sync lag on live channels: the macOS clipboard spool and sleep markers
- [ ] **S7** macOS Lima (vz + virtiofs): the kib image builds and runs; `host.lima.internal`
      reaches the Mac

### Phase 1: VM base (rework the uncommitted VM code)
- [ ] Delete project mounts: `_vm_pick_root`, `vm-roots`, the restart and re-mount path
- [ ] Fixed mounts only: kib checkout read-only, 5 `~/.claude` trees read-write. Node cache stays
      in the VM
- [ ] Pin the mount type per OS: Linux `9p`, macOS `virtiofs`. Never `reverse-sshfs`
- [ ] Allow VM mode on macOS (`vm_wanted`); skip the Docker Desktop-only checks in VM mode
- [ ] `fuse_root_path` → `/mnt/kib` on Lima (macOS Docker Desktop keeps `/run/kib`)
- [ ] `host.docker.internal` → Lima's host address on Lima (also fixes it on Linux)
- [ ] Keep: VM lifetime lock (fd 205/206), `engine_in_vm`, the rootless guard, closing fd 205 in
      background jobs

### Phase 2: Mutagen per project
- [ ] Installer: `Y/n` → official release into `~/.local/bin`, **checksum-verified**; refuse on `n`
- [ ] First session of a project: volume `kib-src-<hash>` + capless sync container + Mutagen
      session (host wins; ignores = redacted files + build dirs + protected paths, which go
      one-way per S5)
- [ ] The FUSE sidecar serves `/src` from that volume, not `$PWD`. The box path stays `$PWD`
- [ ] The box waits for the first sync to finish before Claude starts, with a progress line
- [ ] Last session: `mutagen sync flush` → terminate → remove the volume and sync container
- [ ] Record overwritten (host-wins) files and print them after exit

### Phase 3: hybrid host data
- [ ] Move per-project state into one folder: `$KIB_STATE_ROOT/<slug>/` (session, shared,
      patterns, passwd, group, clipboard, sleep, broker)
- [ ] Sync that folder and `~/.claude/projects/<slug>` while the project is open
- [ ] Broker: copy only the tokens and `providers.d` entries of routes in use into the state
      slice; remove them at close

### Phase 4: prompts that survive Claude's full-screen UI
- [ ] Every decision is a blocking prompt before Claude starts: install Lima `[Y/n/never]`,
      install Mutagen `[Y/n]`, narrow Docker Desktop sharing `[Y/n]`
- [ ] Repeat key notices after exit: VM off and why, overwritten files, teardown findings

### Phase 5: macOS Docker Desktop fallback
- [ ] Detect `/Users` (or any parent of a kib path) in the sharing list → refuse
- [ ] `Y/n`: rewrite the list to kib's mounts only, restart Docker Desktop (the prompt warns this
      stops **all** its containers), wait for the engine
- [ ] Same Mutagen volumes as Lima, so no project ever needs sharing

### Phase 6: policy and docs
- [ ] `guest/policy/etc-CLAUDE.md`: the project is a synced copy; **the host wins conflicts**, so
      re-read before editing and re-apply lost edits yourself; build dirs are VM-local
- [ ] `docs/vm.md`: rewrite for Mutagen, hybrid mounts, macOS Lima/Colima, the Docker Desktop
      narrowing, licenses (Lima Apache-2.0, Mutagen MIT + SSPL, Docker Desktop terms)
- [ ] Design notes: `microvm.md` (decision, and lift the "Lima on macOS rejected" verdict),
      `macos.md`, `container-lifecycle.md`, `redaction-config-guard.md` (sync ignores)
- [ ] `CLAUDE.md` dead ends: kib inside the VM (no `~/.claude.json`), `/run/kib` vs AppArmor,
      `reverse-sshfs`, parent-folder and per-project mounts (restarts), per-project rootless users
- [ ] `README.md` limits section

### Phase 7: tests
- [ ] `tests/check/vm.sh` (fake `limactl`, `mutagen`, `docker`): mount allowlist, sync
      start/stop, volume removal, token copy in/out, refusals, sharing-list rewrite
- [ ] `tests/check/` ignore translation: every `.kibignore` rule shape → Mutagen ignore
- [ ] `security-test.sh` new section **Engine VM** (inside the box): engine is a VM; box kernel ≠
      host kernel (kib passes `KIB_HOST_KERNEL`); `host.docker.internal` reaches the host; the
      policy file states host-wins
- [ ] New `tests/vm-check.sh` (host): the paste blocks below, automated, plus lifecycle checks:
      closed project's volume gone, VM stopped after the last session, only in-use tokens in the VM
- [ ] `./dev.sh check` green, including bash-3.2 portability

### Phase 8: verify, then commit (ask first)
- [ ] All platform tests below pass
- [ ] Commit in small conventional commits, only when asked

## Platform tests

| # | Test | Linux, no Lima | Linux, Lima | macOS, Docker Desktop | macOS, Lima / Colima |
|---|---|---|---|---|---|
| 1 | First launch: right prompt, then a session | install prompt, runs natively | VM created; Mutagen prompt if missing | narrow-sharing prompt if `/Users` is shared | VM created |
| 2 | `uname -r` in the box ≠ host | n/a (same kernel) | ✅ | ✅ | ✅ |
| 3 | 5 projects opened and closed in any order, no restart | ✅ | ✅ | ✅ | ✅ |
| 4 | Host edit shows in the box < 1s; box edit shows on the host | n/a | ✅ | ✅ | ✅ |
| 5 | Same file edited on both sides → host version kept, file listed after exit | n/a | ✅ | ✅ | ✅ |
| 6 | Close a project → its volume is gone; close all → VM stopped | n/a | ✅ | volume only | ✅ |
| 7 | Same `--resume` history and broker in VM and native mode | ✅ | ✅ | ✅ | ✅ |
| 8 | Dev server on the host reachable via `host.docker.internal` | ✅ | ✅ | ✅ | ✅ |
| 9 | `./tests/security-test.sh` inside the box | ✅ | ✅ | ✅ | ✅ |
| 10 | Paste block below: no user files in the VM | containers only | ✅ | ✅ | ✅ |
| 11 | Colima installed: kib uses `kib-vm`, never `colima` | — | — | — | ✅ |

## Paste blocks: no user files in the VM

Run each in a **host terminal** with at least one kib session open. Every line must print ✅.

### Linux or macOS, Lima / Colima (`kib-vm`)

```
KIB="$(cd "$(dirname "$(readlink -f "$(command -v kib)")")/.." && pwd)"
limactl shell kib-vm -- findmnt -rn -t 9p,virtiofs,fuse.sshfs -o TARGET,FSTYPE,OPTIONS
limactl shell kib-vm -- findmnt -rn -t 9p,virtiofs,fuse.sshfs -o TARGET | grep -vxE "$KIB|$HOME/\.claude/(skills|plugins|agents|commands|hooks)" && echo "❌ unexpected host mount above" || echo "✅ only kib's mounts"
limactl shell kib-vm -- findmnt -rn -t fuse.sshfs -o TARGET | grep -q . && echo "❌ reverse-sshfs in use" || echo "✅ no reverse-sshfs"
limactl shell kib-vm -- test -e "$HOME/.ssh" && echo "❌ ~/.ssh visible in the VM" || echo "✅ ~/.ssh not in the VM"
DOCKER_HOST="unix://$HOME/.lima/kib-vm/sock/docker.sock" docker volume ls -q --filter name=kib-src
for v in $(DOCKER_HOST="unix://$HOME/.lima/kib-vm/sock/docker.sock" docker volume ls -q --filter name=kib-src); do DOCKER_HOST="unix://$HOME/.lima/kib-vm/sock/docker.sock" docker run --rm -v "$v:/s:ro" alpine sh -c 'find /s -name ".env*" ! -name ".env.example" ! -name ".env.sample" ! -name ".env.template" | grep -q . && echo "❌ secrets synced in '"$v"'" || echo "✅ no .env in '"$v"'"'; done
```

The volume list must show one `kib-src-*` per **open** project and nothing else.

**Baseline, 2026-11-05 (before phases 1–3):** `❌` is expected today. The current VM code also
mounts a project folder (`~/scripts`), `~/.claude/projects`, kib's state, the Node cache and
`~/.keep-it-in-your-box` (read-only). These are exactly what phases 1–3 remove. `~/.ssh` was not
visible and no `reverse-sshfs` was in use.

### macOS, Docker Desktop

```
grep -A12 FilesharingDirectories ~/Library/Group\ Containers/group.com.docker/settings-store.json
docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -- ls /run/host_virtiofs/Users/"$USER"
docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -- test -e /run/host_virtiofs/Users/"$USER"/.ssh && echo "❌ ~/.ssh visible in the VM" || echo "✅ ~/.ssh not in the VM"
docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -- test -e /run/host_virtiofs/Users/"$USER"/Documents && echo "❌ ~/Documents visible in the VM" || echo "✅ ~/Documents not in the VM"
docker volume ls -q --filter name=kib-src
```

The `ls` must list only kib's checkout and `.claude`. The volume list must show only open projects.

### Linux, no Lima (native: no VM boundary)

```
docker ps -q --filter name=^kib- | xargs -r docker inspect -f '{{.Name}}{{range .Mounts}}  {{.Source}}{{end}}'
```

Expected: each container binds only its own project, kib's checkout and kib's state, never `~` or
`~/.ssh`. The kernel is still shared, which is why kib prompts to install Lima.
