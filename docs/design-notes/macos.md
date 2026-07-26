# macOS support

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

`kib` runs on any macOS Docker engine. Supporting macOS is what settled kib's redaction topology for **both** platforms.

macOS cannot host a FUSE server in a *separate* container reaching the agent by shared-mount propagation (measured on Docker Desktop 4.78.0: it refuses the `rshared`/`rslave` mount config because bind sources resolve through the `/host_mnt` sharing layer, and the LinuxKit kernel refuses the unprivileged-userns `uid_map` write — so a capless-at-creation in-place FUSE exists only inside a real Linux VM, i.e. Colima). kib carried both topologies behind one interface for a while and now carries only the one that works everywhere: the container is created with `SYS_ADMIN`+`SETPCAP`+`/dev/fuse`+`apparmor=unconfined`, and the baked `guest/entrypoint/entrypoint-fuse.sh` mounts the redacted view over the project path; the real project sits at `/kib/real` under a root-700 parent.

Accepted trade: capless-at-**runtime**, not capless-at-creation. **The cap drop happens per session in `kib`'s `docker exec`, not at PID 1** — exec gets the *container's* cap set, not PID 1's reduced bounding set, so `kib` enters as root and runs `setpriv --bounding-set -sys_admin,-setpcap gosu <uid> …` itself (`setpriv` needs `CAP_SETPCAP` effective, which a `--user` session lacks). `security-test.sh` asserts `CapEff` is zero and `CapBnd` lacks both.

Dropping the propagation topology is also what makes a hypervisor-isolated substrate discussable at all; `microvm.md` records why kib is not pursuing one.

## Portability contract

Header of `host/portable.sh`, enforced by `check.sh`: host-side scripts are bash-3.2/BSD-clean — stock macOS, no brew. GNU-only tools (`flock setsid sha256sum grep -P notify-send`) and bash-4isms (`declare -A`, `${var,,}`, `readarray`) only inside `host/portable.sh`'s linux branches. Shims: `lock_fd` (perl flock on the inherited fd — open-file-description semantics identical; release with `lock_fd -u` or `exec N>&-`), `hash8`, `detach_pgrp`, `notify_desktop`, `preflight_platform`. `check.sh` unit-tests the shims by forcing the perl/darwin paths on Linux, so the macOS code paths are proven without a Mac. The Wayland notifier's raw `setsid`/`notify-send` are the one allowed exception (structurally Linux-only; advisory warnings).

**Empty arrays.** bash 3.2 expands `"${arr[@]}"` of an *empty* array as an unbound variable under `set -u` — it aborts the launch, and only 4.4 fixed it. Every array ever assigned `()` expands through `${arr[@]+"${arr[@]}"}`, including where it reads as provably non-empty: the reader cannot verify that, and one later edit makes it empty. This shipped once — a sessionless first Mac run died in `start_broker` on `tok_mounts[@]: unbound variable`, because a Mac with no brokered MCP routes is exactly the case where the array is empty. `portability.sh` now derives the `X=()` names per file and fails on any bare expansion left.

**No nested bind mounts.** A `-v` whose destination is inside another `-v`'s destination aborts the whole `docker run` on Docker Desktop — `mountpoint "/run/host_virtiofs/…" is outside of rootfs`. runc resolves the mountpoint *through* the parent bind, so the real path lands in the engine VM's virtiofs view of the host, outside the container rootfs; the check runs after resolution whether or not runc had to create the mountpoint, so pre-creating it is not a workaround. This killed the second Mac launch attempt (the broker's synthetic `.credentials.json` over the shared-assembly dir), and the other three nests — the ro shared assets, the lock witness, the transcripts dir — would each have killed it in turn. `bind_via_link` (host/lifecycle.sh) mounts flat under `/run/kib/` and leaves a symlink to it in the parent's host-side dir; `tests/check/portability.sh` fails on a reintroduced nest. Linux tolerates nesting, so the Linux-only one (the resolv-sync `/dev/null` masks) stays as it is.

**`$HOST_HOME`'s parent is not in the image.** The entrypoint symlinks `$HOST_HOME` → the container home so Claude's absolute-path-keyed project config resolves. On macOS that is `/Users/<user>`, and a debian image has no `/Users`; there is no `$PWD` bind to create one either, so `ln` failed ENOENT and the entrypoint's `set -e` killed PID 1. It `mkdir -p "$(dirname …)"` first now. Linux was masked from this while it still bound `$PWD` (which created `$HOST_HOME` outright, so the block was skipped) — with that bind gone it takes the same path, and `/home` being in the image is the only reason it survives.

A **second** entrypoint block links `$HOST_HOME/.claude` → the session config dir, so a host-installed plugin's absolute `installPath` resolves in the box (without it the plugin dangles and its MCP servers silently never start — `enabledPlugins` true, nothing in `/mcp`). It is aimed at `$USER_HOME/.claude`, not `$HOST_HOME/.claude`: the symlink above makes them the same directory, and the original spelling only fired when `$HOST_HOME` happened to be a real directory — which it no longer ever is. **Needs an on-hardware VERIFY** (see "Still open").

**Host-side python is 3.9.** `kib_py` runs whatever `python3` the host has, and stock macOS ships 3.9 (`xcode-select --install`) — so `def f() -> str | None` is a launch-time `TypeError`, not a style question. `kib/host`, `kib/shared` and `kib/broker` therefore carry `from __future__ import annotations` and avoid 3.10+ runtime APIs; only `kib/guest` may assume the image's 3.13. Enforced two ways, because neither is sufficient alone: ruff's `per-file-target-version = py39` + `FA102` catches annotations, and `portability.sh` re-parses each module at `feature_version=(3, 9)` and greps the AST for 3.10-only calls (`zip(strict=)`, `dataclass(slots=)`, …) that fail only when *reached*, which an import smoke test would miss. mypy cannot help — 2.x refuses `--python-version 3.9`.

## `fakeowner`: ownership and mode are advisory in the box

Docker Desktop backs every bind with a `fakeowner` layer over virtiofs. Two consequences, both
found on the first real Mac run and neither reproducible on Linux:

**Ownership is invented, so git refuses the project.** The project arrives at `/kib/real` owned
by `root:root` whatever it is on the host. The FUSE server passed `st_uid`/`st_gid` straight
through, the agent runs as `HOST_UID`, and git therefore reported *"detected dubious ownership
in repository"* for the entire tree — taking `git status`, `./dev.sh` (its file discovery is
`git ls-files`) and four of `security-test.sh`'s "the guard must not break ordinary git"
assertions down with it. `entrypoint-fuse.sh` now passes `--uid`/`--gid` and the server reports
those for every path, stub included. Redaction is unaffected: every rule check is
uid-independent, which is what makes the squash safe rather than a hole. It is passed
**unconditionally**, including on Linux where the ids are already the agent's: one code path
beats a second topology, and a genuine cross-owner file then reports as the agent's.

**POSIX permissions inside `$PWD` are no longer enforced at all** — on either platform, and
independently of the squash. The server runs as **root** and mounts with
`default_permissions=False`, so nothing checks owner or mode: a `chmod 000` file in the project
reads and writes fine through the view, and a root-owned file the agent could not touch under
the old `--user $(id -u)` sidecar is now writable, with the write landing on the host. Accepted:
the project is the agent's to edit by construction, and secrecy inside it is `.kibignore`'s job
(rule-based, uid-independent), not the file mode's. Anything that must stay read-only needs a
`:ro` mount or a guard rule — never a mode bit. `chown` to the invented
owner is translated to `-1` (no change) so `cp -p`, `tar -x` and `git checkout` do not try to
rewrite the backing file to a uid it never had.

**Mode bits do not gate access.** `chmod 0400` on a bind is *recorded* faithfully — `stat` reads
back `400` — but `access(2)` still answers writable. Every chmod-based read-only control there is
a silent no-op on macOS. That is how the broker's synthetic `.credentials.json` shipped writable:
it was a `cp` + `chmod 0400`. It is a `:ro` bind now (via `bind_via_link`, since the destination
nests inside the shared-dir mount). Nothing refreshes it under the broker, so a single-file bind
carries none of the rename risk the real rotating credential does. Host-side `chmod 700` on kib's
own scratch dirs is unaffected — that is APFS, not a bind — as is `chmod 700 /kib`, which is the
container's own overlayfs and does still fence `/kib/real`.

## Host key vs box key

Claude keys `projects/`, `.claude.json` and `history.jsonl` by its **resolved** cwd. There is no
`$PWD` bind and the entrypoint symlinks `$HOST_HOME` → the container home, so `/Users/<u>/proj`
resolves to `/home/hostuser/proj` and Claude keys everything by that. The symlink makes the host
path *reachable*; it does not make Claude *use* it.

Discovered on macOS, but **not macOS-specific** — the same translation now runs on Linux, where
`/home/<u>/proj` becomes `/home/hostuser/proj`. `tests/check/wiring.sh` asserts both host-path
shapes and `tests/host/test_config_scope.py` round-trips both, including the two cases where the
two keys coincide (a project outside `$HOME`; a host user already called `hostuser`).

Left alone this silently split every project in two: the box wrote a second set of entries under
the container path, so the host's `--resume` and ↑ history could not see the box's sessions nor the
box the host's — exactly the seamless switch `container-lifecycle.md` exists to protect. (It also
made three `security-test.sh` cross-project assertions fail, which is how it surfaced; they were
reporting a key mismatch, not a leak.)

`kib_box_pwd` (host/config.sh) computes the box path, and every `config_scope` verb takes both:
canonical is only ever keyed by the host path, the session only ever by the box path, translated
in on assembly and back out on merge. A project *outside* `$HOME` needs no translation — the
entrypoint mkdirs that path for real, so it resolves to itself. The transcripts bind takes its
source from the host slug and its link name from the box slug.

One trap this exposed: `merge_history`'s dedupe compared raw text. Claude writes those lines with
JS `JSON.stringify` (no space after separators) and re-keying round-trips them through Python's
`json.dumps`, which does not produce the same bytes — so nothing matched and every launch would
have re-appended the whole seeded history. It compares parsed-and-normalised lines now.

## Clipboard and DNS on macOS

macOS clipboard: `clipboard-bridge.sh` (host, POSIX sh) watches a spool dir at `/kib-clip`; the entrypoint installs `wl-paste`/`xclip` reader shims and `wl-copy`/`pbcopy` deny-marker shims; the host answers with `pbpaste`/osascript PNG extraction and **never calls `pbcopy`**. Started/stopped like the Wayland notifier including the `200>&- 201>&-`.

DNS sync is skipped on macOS (the engine VM tracks the host resolver). No migration step: on a fresh Mac `ensure_claude_home` creates a minimal `~/.claude` skeleton on first launch (first login populates it); nothing to bootstrap.

## Still open — on-hardware VERIFY (Mac only)

- **A host-installed plugin's MCP server starts.** The `$HOST_HOME/.claude` → session-dir link was
  unreachable in the shape that shipped (it required `$HOST_HOME` to be a real directory, and the
  block above always makes it a symlink first). It is now aimed at `$USER_HOME/.claude`, which is
  the same directory through the link. Confirm `/mcp` lists a host-installed plugin's servers.
- Image paste end-to-end. Confirmed broken on the first Mac run (text paste kept working, which
  proves nothing: a terminal pastes text over the pty and never calls a clipboard reader at all —
  the reader is only invoked for an image). Three fixes went in, and which of them mattered is
  still unknown:
  - the `xclip` shim `exec`ed `wl-paste` **with no arguments**, so `-t image/png -o` silently
    fetched the *text* selection;
  - the reader's response budget was 2 s, and the host answers a png with `osascript`, whose cold
    start plus a large image passes that routinely — the read then returns empty and the paste
    produces nothing, with no error;
  - neither of these was the whole story: the host half was never running (`clipboard-bridge.sh`
    shipped non-executable), and the trigger is `Ctrl+V` — `⌘V` never leaves the terminal.

  `tests/check/clipboard.sh` extracts both shims from the entrypoint and drives them against the
  real host bridge, so both halves are covered on Linux. Which reader Claude reaches for is no
  longer a guess: it runs `xclip … || wl-paste …`, trying both in turn.
