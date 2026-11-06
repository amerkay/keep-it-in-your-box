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
- VM starts with the first session and stops 10 minutes after the last closes

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
| Closed project | Flush the sync; it runs on until the VM stops, then its volume is deleted |
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
- ✅ **S3** macOS Docker Desktop: where the file-sharing list lives (`settings-store.json`,
      `FilesharingDirectories`); whether an edit plus restart applies it; whether an org admin lock
      blocks it.
      Done 2026-11-06 (Docker Desktop 4.78, macOS 26.7): `settings-store.json`; the key is absent
      until written (defaults `/Users /Volumes /private /tmp /var/folders`). Edit while stopped,
      then start: applied, and a path off the list is refused. `docker desktop stop|start` (CLI
      v0.3.0): 7 s and 2–4 s. No `admin-settings.json`. **Every share is read-write**: no `:ro`
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
- ✅ **S7** macOS Lima (vz + virtiofs): the kib image builds and runs; `host.lima.internal`
      reaches the Mac.
      Done 2026-11-06 (`tmp_macos_test.sh`): Phase 4 prompts installed Lima and Mutagen; only
      kib's 9 mounts; `vm-ro` read-only; `.env` redacted; a Mac server reached via
      `host.docker.internal`; sync both ways; VM stopped after the last session

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
- ✅ The box waits for the first sync to finish before Claude starts, with Mutagen's status live
      on one line. 2026-11-06 Mac: a 1.6 GB first sync took 3–4 min, 1.3 GB of it a box-made
      `.pnpm-store`; caches now join the never-synced build dirs. The status line names the file
      being copied, and `vm_skip = …` in the config adds names (before the guard, so a `!` in it
      can't un-ignore a guarded file)
- ✅ Package caches outlive a close: one volume per project (`<cname>-cache`, never shared: a box
      could plant a package another project installs) at the box's `~/.cache`, with
      `XDG_CACHE_HOME`, `pnpm_config_store_dir` + `npm_config_store_dir` (pnpm 12 reads only the
      first, a repo-pinned pnpm 9 only the second; env beats a repo's
      `storeDir`) and `npm_config_cache`. The entrypoint no longer `chown -R`s it
- ✅ Last session: `mutagen sync flush`; the sync runs on, so a reopen carries only the
      difference (2026-11-06: a full copy was 30–50 s a launch). The VM's stop terminates every
      sync and removes the volumes, sync containers and shadows, unless one fails to flush.
      Sessions rebuilt on new ignores are flushed first, while they hold their history (a new
      session would let the host win every difference)
- ✅ Seed after the first sync (`kib/host/vmseed.py`): redacted files as their key-only render,
      protected files (`.git/config`, hooks, `.vscode`, …) as real bytes. The sync ignores them,
      so nothing seeded flows back. The renderers moved to `kib/shared/render.py` for this
- ⬜ The seed is taken once per container: a host edit to a redacted or protected file shows in
      the box at the next cold start. A box edit to `.git/config` stays in the VM
- ✅ A `.kibignore` reload (a tightening, or a loosening the user confirms) recreates the host
      hop on the new ignores and swaps each newly redacted file in the shadow for its render; the
      VM hop carries both into the volume (`vm_sync_restage`). The new config is built before the
      old session stops, so a failure leaves the sync running
- ✅ Found doing it: the shadow is VM-writable through its hop, so the seed's `tar -x` could
      follow a planted symlink onto any host file. Seeding and re-rendering now write through
      `O_NOFOLLOW` directory fds (`kib/host/vmseed.py`), and fail closed on a link
- ✅ Same class on `vm-rw`: VM root could swap the project's state dir, its transcripts or
      `.state` for a link, and the close would aim canonical `projects/<slug>` at its target
      (bound rw into the next native box). `vm_state` refuses a link both ways

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
- ✅ Boot is ~14–27 s. Decided 2026-11-06: the VM lingers 10 min after the last session closes
      (a detached timer; only the newest close's timer stops it, and only with no session open)

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

### Phase 5: macOS is Lima only (decided 2026-11-06)
Docker Desktop's sharing list is read-write only (S3), so a narrowed one still exposed kib's
checkout and `vm-ro`. Dropped instead: no Docker Desktop code or dependency left.
- ✅ macOS always runs VM mode. Declining the install refuses to launch, never another engine
- ✅ One prompt installs what is missing: Lima, Mutagen, the Docker CLI (static, pinned) into
      `~/.local`. `never` writes `vm = off` (Linux only)
- ✅ kib's docker calls use their own `DOCKER_CONFIG` (`~/.local/docker`): Docker Desktop's
      `credsStore: desktop` breaks pulls once it is gone. buildx is pinned and installed there
      too: without it the legacy builder printed every line and lost the BuildKit cache
- ✅ Removed: Docker Desktop start/probe/preflight, `engine_in_vm` (now `engine_lima`), the
      `desktop-linux` context check
- ✅ Verified on the Mac 2026-11-06, Docker Desktop quit and its CLI off `PATH`: kib installed
      its own docker CLI; box in Lima, `.env` redacted and its value not in the volume, Mac server
      reached, sync both ways, only kib's mounts, VM stopped after, Docker Desktop never started
- ⬜ `bin/kib`'s `preflight_platform` comment still names the engine check: fix once no Linux
      session is live (editing it under one corrupts it)

### Phase 6: policy and docs
- ✅ `guest/policy/etc-CLAUDE.md`: the project is a synced copy; **the host wins conflicts**, so
      re-read before editing and re-apply lost edits yourself; build dirs and caches are VM-local;
      `~/.cache` is the project's package cache
- ✅ `docs/vm.md`: rewritten for Mutagen, the fixed mounts, macOS Lima-only, licenses
- ✅ Design notes: `microvm.md` (adopted, three choices), `macos.md` (Lima-only, first contact),
      `container-lifecycle.md` (§ In the VM), `redaction-config-guard.md` (§ sync ignores),
      `platform-matrix.md` (macOS column = Lima, TODO for Lima rechecks)
- ✅ `CLAUDE.md` dead ends: FUSE root `/mnt/kib`; no project mount, no one-hop sync, not kib in
      the VM, not reverse-sshfs, not Docker Desktop narrowed; nothing host-trusted on `vm-rw`;
      per-project package caches
- ✅ `README.md`: requirements (macOS needs no Docker engine) and the limits section
- ⬜ `bin/kib`'s `preflight_platform` comment: edit once no Linux session is live

### Phase 7: tests
- ✅ `tests/check/vm.sh` (fake `limactl`, `mutagen`, `docker`): mount allowlist, sync
      start/stop, volume removal, vm-rw/vm-ro placement, refusals, linger, install prompt, macOS
      Lima-only. (Sharing-list rewrite dropped with Docker Desktop)
- ✅ Ignore translation: `tests/shared/test_rules.py`, against a real Mutagen, plus `vm_skip` order
- ✅ `security-test.sh` section **Engine VM** (inside the box): box kernel ≠ host kernel (kib
      passes `KIB_HOST_KERNEL` in VM mode); `host.docker.internal` resolves; the policy states
      host-wins; `~/.cache` is the package-cache volume
- ✅ `tests/vm-check.sh` (host, a session open): the paste blocks below, automated — mounts equal
      kib's own `_vm_mounts`, no reverse-sshfs, `vm-ro` and the checkout read-only, no `~/.ssh`,
      tokens or `~/.claude.json`, one volume per syncing project, no `.env` value in any, `vm-rw`
      one dir per open project. Lifecycle (volumes gone and VM stopped after the linger) is the
      user's checklist
- ✅ `./dev.sh check` green, including bash-3.2 portability
- ✅ `tmp_macos_test.sh` deleted: `tests/vm-check.sh` and the checklist replace it

### Phase 8: verify, then commit
- ⬜ All platform tests below pass (the user's checklist)
- ✅ Committed in small conventional commits on `feat/vm-security` (the user allowed it)
- ⬜ Merge to `main` when the user says so

## Platform tests

Expected results (✅ = must hold). Docker Desktop is no longer a setup (Phase 5).

| # | Test | Linux, native | Linux, `vm = on` | macOS (Lima) |
|---|---|---|---|---|
| 1 | First launch: right prompt, then a session | no prompt | one install prompt for what is missing, then VM created | same |
| 2 | `uname -r` in the box ≠ host | n/a (same kernel) | ✅ | ✅ |
| 3 | 5 projects opened and closed in any order, no VM restart | ✅ | ✅ | ✅ |
| 4 | Host edit shows in the box < 1 s; box edit shows on the host | n/a | ✅ | ✅ |
| 5 | Same file edited on both sides → host version kept | n/a | ✅ | ✅ |
| 6 | Close all → after 10 min the VM stops and the `-src` volumes are gone; cache volumes kept | n/a | ✅ | ✅ |
| 7 | Same `--resume` history and broker in VM and native mode | ✅ | ✅ | ✅ |
| 8 | Dev server on the host reachable via `host.docker.internal` | ✅ | ✅ | ✅ |
| 9 | `./tests/security-test.sh` inside the box | ✅ | ✅ | ✅ |
| 10 | `./tests/vm-check.sh` on the host, a session open | n/a | ✅ | ✅ |
| 11 | Reopening a project reinstalls packages from its cache, no re-download | ✅ | ✅ | ✅ |

## Paste blocks: no user files in the VM

### Linux or macOS, kib's VM

With at least one kib session open, in a host terminal, from the kib checkout:

```
./tests/vm-check.sh
```

Every line must pass.

### Linux, no Lima (native: no VM boundary)

```
docker ps -q --filter name=^kib- | xargs -r docker inspect -f '{{.Name}}{{range .Mounts}}  {{.Source}}{{end}}'
```

Expected: each container binds only its own project, kib's checkout and kib's state, never `~` or
`~/.ssh`. The kernel is still shared, which is why kib prompts to install Lima.
