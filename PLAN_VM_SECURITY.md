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
| Conflicts | **Host wins** (`two-way-resolved`, host = alpha). Claude is told in `etc-CLAUDE.md` that fixing lost edits is its job. No overwritten-files list: Mutagen doesn't report host-wins conflicts (S1) |
| Closed project | Flush the sync, terminate it, delete the volume |
| Build output | `node_modules`, `target`, `.venv`, `dist`, … stay in the VM, not synced |
| Other host data | **Hybrid**: mount what is global anyway (kib checkout read-only; `~/.claude/{skills,plugins,agents,commands,hooks}` read-write). Sync the open project's slices (transcripts, state). Copy in only the broker tokens of routes in use |
| Lima missing | Linux: run natively after the install prompt. macOS: Docker Desktop fallback |
| Docker Desktop | Refuse while `/Users` is shared. After `Y/n`, kib narrows the sharing list and restarts Docker Desktop |

## Goals (done = all true)

1. On every VM setup, the VM holds only: kib's checkout (read-only), the 5 shared `~/.claude` trees,
   a VM-only Node cache, and open projects, without their redacted files.
2. Opening or closing any project never restarts the VM or touches another session.
3. Switching VM mode on or off changes nothing else: same login, history and broker.
4. `security-test.sh` (inside the box) and `tests/vm-check.sh` (on the host) pass on all four
   setups.

## Checklist

### Phase 0: spikes (host-side, before code)
- ✅ **S1** Mutagen Docker transport → a volume-backed sync container in `kib-vm`: initial sync
      time on a big repo, lag, host-wins conflicts, symlinks, exec bits, UID 1000, `.git`, deletes,
      file-change events in the box.
      Done 2026-11-05 (v0.18.1): all pass. Lag ≤55 ms host→VM, ≤111 ms VM→host; close 0.27 s.
      `two-way-resolved` does **not** report host-wins conflicts. Still open: first-sync time on a big repo
- ✅ **S2** `.kibignore` and the global guard → Mutagen ignores: check the `!`, root-anchored and
      folder-seal rules map 1:1.
      Done 2026-11-05: `rules.sync_ignores`, proven against a real Mutagen sync on 9 rule shapes
      (`test_real_mutagen_syncs_exactly_what_verdict_passes`). Passed as a `-c` config file:
      `--ignore` splits on commas
- ⬜ **S3** macOS Docker Desktop: where the file-sharing list lives (`settings-store.json`,
      `FilesharingDirectories`); whether an edit plus restart applies it; whether an org admin lock
      blocks it
- ✅ **S4** FUSE root at `/mnt/kib` in the Lima VM passes Ubuntu's `fusermount3` AppArmor profile.
      Done 2026-11-05: `/mnt/kib` mounts; `/run/kib` is `DENIED … profile="fusermount3"`
- ✅ **S5** Protected paths (`.git/config`, `.git/hooks`, `.vscode`, …) synced **host→VM only**,
      so a VM escape can't plant them on the host. Fallback: the teardown audit, as today.
      **Finding 2026-11-05 (Mutagen v0.18.1 source):** the host trusts the VM agent's snapshot and
      never re-applies ignores. It only rejects `..` and `/` in names. So VM root can tamper with
      the agent and write **any** path in an open project, ignores or not. A one-way side session
      doesn't help: the hole is the main two-way session. Ignores still stop the honest sync.
      Reads too: the host's `Supply()` serves any path the agent asks for, ignores unchecked.
      **Fix (2026-11-05, verified on Linux): two hops.** project ⇄ shadow
      (`~/.local/state/kib-shadow/<cname>`, both ends on the host, guard ignores) ⇄ VM volume
      (build dirs ignored only). Nothing
      guarded is ever in the shadow, and the VM's agent never reaches the project. Mutagen's
      opener refuses symlinks, so a planted link can't reach past the shadow. Rejected: a host
      poller (~100 lines, a 1 s window, no fix for reads); one 9p-shared copy (scanning 9,845
      files took 1.79 s on 9p vs 0.02 s on a volume). Test: a hook planted in the VM volume reached
      the shadow in 1–3 s and never the project; a box edit 3 folders deep reached the host in ≤1 s
- ⬜ **S6** Sync lag on live channels: the clipboard spool and sleep markers.
      2026-11-05, Linux over 9p: clipboard text, screenshot and box→host write all work. Lag and
      sleep markers not measured; both stay on 9p (`vm-rw`)
- ⬜ **S7** macOS Lima (vz + virtiofs): the kib image builds and runs; `host.lima.internal`
      reaches the Mac

### Phase 1: VM base (rework the uncommitted VM code)
- ✅ Delete project mounts: `_vm_pick_root`, `vm-roots`, the per-project restart
- ✅ Fixed mounts only: kib checkout read-only, 5 `~/.claude` trees read-write. Node cache: its own
      `node-vm` dir, so a binary VM root swapped never runs in a native box. Phase 3 adds
      `vm-rw` and `vm-ro`
- ✅ A changed mount set (kib upgrade, today's old VM) re-mounts once, only with no session in it
- ✅ Pin the mount type per OS: Linux `9p`, macOS `virtiofs`. Never `reverse-sshfs`
- ✅ Allow VM mode on macOS (`vm_wanted`); skip the `$PWD` sharing probe on Lima
- ✅ `fuse_root_path` → `/mnt/kib` on Lima (macOS Docker Desktop keeps `/run/kib`)
- ✅ `host.docker.internal` → `192.168.5.2`, Lima's host address (S7 confirms it on vz)
- ✅ Keep: VM lifetime lock (fd 205/206), `engine_in_vm`, the rootless guard, closing fd 205 in
      background jobs
- ✅ Clipboard in Linux VM mode: the macOS spool bridge, on the host's `wl-paste`/`wl-copy` (the
      Wayland socket can't cross into the VM). Same sanitiser. Lag over 9p: S6
- ✅ Lock fds: Mutagen's daemon and Lima's host agent outlive kib, so neither may inherit
      200–206. Found 2026-11-05: the leak kept every VM project and the VM itself alive

### Phase 2: Mutagen per project
- ✅ Installer: `Y/n` → official release into `~/.local/bin`, SHA-256 **pinned in kib** per
      platform (a `SHA256SUMS` beside the tarball vouches for nothing); refuse on `n` or no tty
- ✅ The sync container needs a passwd/group entry for the box's UID (Mutagen looks up the
      username) and `--cap-add=CHOWN` (Mutagen `chown`s its injected agent as root). Found in S1
- ✅ First session of a project: volume `<container>-src` (label `kib-src`) + capless,
      network-less sync container + Mutagen session (host wins; ignores = build dirs + guard +
      `.kibignore` + git's own config/hooks). Protected paths: see S5
- ✅ kib's own Mutagen daemon (`~/.local/state/kib-mutagen`, off the VM's mounts), stopped with
      the VM
- ✅ The FUSE sidecar serves `/src` from that volume, not `$PWD`. The box path stays `$PWD`
- ✅ The box waits for the first sync to finish before Claude starts, with a progress line
- ✅ Last session: `mutagen sync flush` → terminate → remove the volume and sync container. A
      failed flush keeps all of it; the next launch's session carries the edits back
- ✅ Seed after the first sync (`kib/host/vmseed.py`): redacted files as their key-only render,
      protected files (`.git/config`, hooks, `.vscode`, …) as real bytes. The sync ignores them,
      so nothing seeded flows back. The renderers moved to `kib/shared/render.py` for this
- ⬜ The seed is taken once per container: a host edit to a redacted or protected file shows in
      the box at the next cold start. A box edit to `.git/config` stays in the VM
- ⬜ A `.kibignore` rule added mid-session redacts live (FUSE) but the file stays in the volume
      until the project closes. Fix: on a tightening, delete newly ignored paths from the volume

### Phase 2b: found in the first Linux runs (2026-11-05)
- ✅ Progress: Lima's boot is one line with a dot a second; its log prints only on failure
- ✅ The sync container binds nothing from the host. `docker start` on a leftover one turned its
      deleted passwd/group sources into directories, on the host, through 9p
- ✅ `drop_planted_links` kept dropping kib's own placeholder-credential link (fixed on `main`)
- ✅ The clipboard bridge is silent on the terminal (it printed `Terminated` at teardown)
- ✅ `session .claude.json unreadable — not merging back`: the file stopped at exactly 4096 bytes,
      and Claude in the box once read one too (`Unexpected EOF`). Lima's 9p `mmap` cache writes
      back late and takes the size from the host. Fix: every 9p mount `cache=none`. Verified
      2026-11-05; it took effect one boot after the edit (fstab is rewritten after mounting)
- ✅ Boot is ~14–27 s. Decided 2026-11-05: no linger, the VM still stops when the last session
      closes

### Phase 3: hybrid host data
- ✅ Two fixed shares replace `$KIB_STATE_ROOT`, `~/.claude/projects` and
      `~/.keep-it-in-your-box`: `vm-rw` (what the box writes: session, shared, transcripts, sleep
      markers, clipboard spool, broker out) and `vm-ro`, read-only in the VM (rules, passwd,
      broker config and tokens, and the host's own pidfiles, witness and sync config)
- ✅ The session dir and transcripts move onto `vm-rw` at the first open and back at the last
      close; canonical keeps a link meanwhile. One `mv`, no extra sync, no restart
- ✅ Broker: the in-use tokens and `providers.d` are copied into the container's broker dir
      (removed at close). No live rotation lost: a token write was already a rename
- ✅ Verified on Linux 2026-11-06 (separate VM via `LIMA_HOME`): only kib's mounts, `vm-ro`
      read-only, no token store or transcripts dir in the VM, broker and `/resume` work, `vm-rw`
      empty after close

### Phase 4: prompts that survive Claude's full-screen UI
- ✅ Every decision is a blocking prompt before Claude starts: install Lima `[Y/n/never]`
      (pinned v2.2.1 into `~/.local`, `never` writes `vm = off`; Linux offers it only with QEMU
      and KVM, which need root), install Mutagen `[Y/n]`. Docker Desktop narrowing: Phase 5
- ✅ Every launch `warn`/`note` (VM off and why, `.kibignore` opt-outs, inline MCP secrets) is
      printed again after Claude exits. Teardown findings already print after it
- ✅ Verified on Linux 2026-11-06: the Lima prompt (y, n, never) and the replay after exit

### Phase 5: macOS Docker Desktop fallback
- ⬜ Detect `/Users` (or any parent of a kib path) in the sharing list → refuse
- ⬜ `Y/n`: rewrite the list to kib's mounts only, restart Docker Desktop (the prompt warns this
      stops **all** its containers), wait for the engine
- ⬜ Same Mutagen volumes as Lima, so no project ever needs sharing

### Phase 6: policy and docs
- ⬜ `guest/policy/etc-CLAUDE.md`: the project is a synced copy; **the host wins conflicts**, so
      re-read before editing and re-apply lost edits yourself; build dirs are VM-local
- ⬜ `docs/vm.md`: rewrite for Mutagen, hybrid mounts, macOS Lima/Colima, the Docker Desktop
      narrowing, licenses (Lima Apache-2.0, Mutagen MIT + SSPL, Docker Desktop terms)
- ⬜ Design notes: `microvm.md` (decision, and lift the "Lima on macOS rejected" verdict),
      `macos.md`, `container-lifecycle.md`, `redaction-config-guard.md` (sync ignores)
- ⬜ `CLAUDE.md` dead ends: kib inside the VM (no `~/.claude.json`), `/run/kib` vs AppArmor,
      `reverse-sshfs`, parent-folder and per-project mounts (restarts), per-project rootless users
- ⬜ `README.md` limits section

### Phase 7: tests
- ⬜ `tests/check/vm.sh` (fake `limactl`, `mutagen`, `docker`): mount allowlist, sync
      start/stop, volume removal, token copy in/out, refusals, sharing-list rewrite
- ⬜ `tests/check/` ignore translation: every `.kibignore` rule shape → Mutagen ignore
- ⬜ `security-test.sh` new section **Engine VM** (inside the box): engine is a VM; box kernel ≠
      host kernel (kib passes `KIB_HOST_KERNEL`); `host.docker.internal` reaches the host; the
      policy file states host-wins
- ⬜ New `tests/vm-check.sh` (host): the paste blocks below, automated, plus lifecycle checks:
      closed project's volume gone, VM stopped after the last session, only in-use tokens in the VM
- ⬜ `./dev.sh check` green, including bash-3.2 portability

### Phase 8: verify, then commit (ask first)
- ⬜ All platform tests below pass
- ⬜ Commit in small conventional commits, only when asked

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
limactl shell kib-vm -- findmnt -rn -t 9p,virtiofs,fuse.sshfs -o TARGET | grep -vxE "$KIB|$HOME/\.claude/(skills|plugins|agents|commands|hooks)|$HOME/\.cache/keep-it-in-your-box/node-vm|$HOME/\.local/state/keep-it-in-your-box/vm-r[wo]" && echo "❌ unexpected host mount above" || echo "✅ only kib's mounts"
limactl shell kib-vm -- findmnt -rn -t fuse.sshfs -o TARGET | grep -q . && echo "❌ reverse-sshfs in use" || echo "✅ no reverse-sshfs"
limactl shell kib-vm -- touch "$HOME/.local/state/keep-it-in-your-box/vm-ro/x" 2>/dev/null && echo "❌ vm-ro is writable from the VM" || echo "✅ vm-ro is read-only in the VM"
ls "$HOME/.local/state/keep-it-in-your-box/vm-rw"   # one dir per OPEN project, plus .state
limactl shell kib-vm -- test -e "$HOME/.ssh" && echo "❌ ~/.ssh visible in the VM" || echo "✅ ~/.ssh not in the VM"
DOCKER_HOST="unix://$HOME/.lima/kib-vm/sock/docker.sock" docker volume ls -q --filter label=kib-src
for v in $(DOCKER_HOST="unix://$HOME/.lima/kib-vm/sock/docker.sock" docker volume ls -q --filter label=kib-src); do DOCKER_HOST="unix://$HOME/.lima/kib-vm/sock/docker.sock" docker run --rm -v "$v:/s:ro" alpine sh -c 'find /s -name ".env*" ! -name ".env.example" ! -name ".env.sample" ! -name ".env.template" | grep -q . && echo "❌ secrets synced in '"$v"'" || echo "✅ no .env in '"$v"'"'; done
```

The volume list must show one `kib-<project>-<hash>-src` per **open** project and nothing else.

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
docker volume ls -q --filter label=kib-src
```

The `ls` must list only kib's checkout and `.claude`. The volume list must show only open projects.

### Linux, no Lima (native: no VM boundary)

```
docker ps -q --filter name=^kib- | xargs -r docker inspect -f '{{.Name}}{{range .Mounts}}  {{.Source}}{{end}}'
```

Expected: each container binds only its own project, kib's checkout and kib's state, never `~` or
`~/.ssh`. The kernel is still shared, which is why kib prompts to install Lima.
