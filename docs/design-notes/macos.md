# macOS support

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

`kib` runs on any macOS Docker engine. Supporting macOS is what settled kib's redaction topology for **both** platforms — twice, and the first answer was wrong.

## The propagation root must never be a host file share

kib serves the redacted view from a **sidecar** container and the agent's container consumes it by shared-mount propagation, on Linux and macOS alike. Only the sidecar gets `SYS_ADMIN`, `/dev/fuse` and `apparmor=unconfined`; the agent's container is `--cap-drop=ALL` under `docker-default`, capless at **creation**, with no FUSE server beside it.

That topology was once retired on the grounds that propagation is a shared-kernel feature and *"could never run on macOS"*. **That reasoning was wrong.** Both containers run in the same LinuxKit VM, so they share a kernel and propagation between them is ordinary. What actually failed is narrower and entirely fixable: kib rooted propagation at `/tmp`, which on a Mac is a *macOS* directory exposed over virtiofs — a file-sharing protocol, not a mount namespace, so a mount event has nowhere to land. Kubernetes hits the same wall and resolves it the same way: CSI FUSE sidecars propagate through an `emptyDir`, never a host share.

Only the **mountpoint** is constrained. The project may still arrive over virtiofs as the sidecar's *source*. `fuse_root_path()` (host/portable.sh) therefore puts the root at `/run/kib/fuse.<hash>` on macOS: `/run` is neither a macOS directory nor in Docker Desktop's share list (`/Users`, `/Volumes`, `/private`, `/tmp`), so the daemon creates it inside the VM. **Never use `/var`** — it is a symlink to `/private/var`, which *is* shared, and the root would silently land back on the Mac. On Linux it is `$KIB_STATE_ROOT/fuse.<hash>`, which systemd's rshared `/` already propagates.

Measured on Docker Desktop, in a throwaway probe run before any of this was written: the VM root is **already** `rshared` (no privileged setup step), a tmpfs mounted in one container appears in another, propagation survives the sidecar's real flags (`--user`, `--cap-drop=ALL --cap-add=SYS_ADMIN`, `--userns=host`, `--network none`) reporting `shared` rather than `shared,slave`, the FUSE server mounts **unprivileged**, and an agent container with `cap-drop=ALL`, no `/dev/fuse` and no AppArmor override reads, writes, sees `.env` still redacted and gets correct uids through the view.

Three things the probe found that shaped the implementation:

- **`fusermount3` aborts with "could not determine username"** unless `getpwuid(getuid())` resolves. kib once bound the *host's* `/etc/passwd`; that works on Linux and **cannot** work on macOS, where Open Directory keeps real users out of that file, so uid 501 is missing there too. `_stage_passwd` synthesises two lines instead — more shared code than the original, not less, and no host user table crosses the boundary.
- **The mountpoint must be owned by the mounting uid.** Free on Linux (the user runs `mkdir`); explicit on macOS, where a root VM helper creates it.
- **A stale `ENOTCONN` mount survives the sidecar's death.** Teardown unmounts explicitly, before `docker rm` — the other order orphans it every exit, and the next launch's `rm -rf` would then delete *through* it into the real project.

## What the Mac cannot see, only Docker can reach

The FUSE root lives inside the engine VM, so the Mac cannot create, inspect or unmount it. `_vm_exec` (host/portable.sh) runs a throwaway `--privileged --pid=host` container that `nsenter`s into the VM's mount namespace. That is a macOS-only mechanism **by design**: on Linux the same command would target your real machine, and buying code symmetry with a privileged container there would be a security regression. The Linux branches need no privilege at all.

Five shims carry the entire divergence — `fuse_root_path`, `fuse_root_create`, `fuse_root_destroy`, `fuse_mounted`, `unmount_fuse` — and `tests/check/portability.sh` fails if a sixth appears anywhere else.

`microvm.md` records why kib is not pursuing a hypervisor-isolated substrate.

## Portability contract

Header of `host/portable.sh`, enforced by `check.sh`: host-side scripts are bash-3.2/BSD-clean — stock macOS, no brew. GNU-only tools (`flock setsid sha256sum grep -P notify-send`) and bash-4isms (`declare -A`, `${var,,}`, `readarray`) only inside `host/portable.sh`'s linux branches. Shims: `lock_fd` (perl flock on the inherited fd — open-file-description semantics identical; release with `lock_fd -u` or `exec N>&-`), `hash8`, `detach_pgrp`, `notify_desktop`, `preflight_platform`. `check.sh` unit-tests the shims by forcing the perl/darwin paths on Linux, so the macOS code paths are proven without a Mac. The Wayland notifier's raw `setsid`/`notify-send` are the one allowed exception (structurally Linux-only; advisory warnings).

**Empty arrays.** bash 3.2 expands `"${arr[@]}"` of an *empty* array as an unbound variable under `set -u` — it aborts the launch, and only 4.4 fixed it. Every array ever assigned `()` expands through `${arr[@]+"${arr[@]}"}`, including where it reads as provably non-empty: the reader cannot verify that, and one later edit makes it empty. This shipped once — a sessionless first Mac run died in `start_broker` on `tok_mounts[@]: unbound variable`, because a Mac with no brokered MCP routes is exactly the case where the array is empty. `portability.sh` now derives the `X=()` names per file and fails on any bare expansion left.

**No nested bind mounts.** A `-v` whose destination is inside another `-v`'s destination aborts the whole `docker run` on Docker Desktop — `mountpoint "/run/host_virtiofs/…" is outside of rootfs`. runc resolves the mountpoint *through* the parent bind, so the real path lands in the engine VM's virtiofs view of the host, outside the container rootfs; the check runs after resolution whether or not runc had to create the mountpoint, so pre-creating it is not a workaround. This killed the second Mac launch attempt (the broker's synthetic `.credentials.json` over the shared-assembly dir), and the other three nests — the ro shared assets, the lock witness, the transcripts dir — would each have killed it in turn. `bind_via_link` (host/lifecycle.sh) mounts flat under `/run/kib/` and leaves a symlink to it in the parent's host-side dir; `tests/check/portability.sh` fails on a reintroduced nest. Linux tolerates nesting, so the Linux-only one (the resolv-sync `/dev/null` masks) stays as it is.

**`$HOST_HOME`'s parent is not in the image.** The entrypoint symlinks `$HOST_HOME` → the container home so Claude's absolute-path-keyed project config resolves. On macOS that is `/Users/<user>`, and a debian image has no `/Users`, so `ln` failed ENOENT and the entrypoint's `set -e` killed PID 1. It `mkdir -p "$(dirname …)"` first now. A project *under* `$HOME` no longer reaches that branch at all — the `$PWD` bind's mountpoint creates the whole chain, so `$HOST_HOME` exists and the block is skipped — but a project outside `$HOME` still does, on both platforms.

A **second** entrypoint block links `$HOST_HOME/.claude` → the session config dir, so a host-installed plugin's absolute `installPath` resolves in the box (without it the plugin dangles and its MCP servers silently never start — `enabledPlugins` true, nothing in `/mcp`). It is aimed at `$USER_HOME/.claude`, not `$HOST_HOME/.claude`: the symlink above makes them the same directory, and the original spelling only fired when `$HOST_HOME` happened to be a real directory — which it no longer ever is. **Needs an on-hardware VERIFY** (see "Still open").

**Host-side python is 3.9.** `kib_py` runs whatever `python3` the host has, and stock macOS ships 3.9 (`xcode-select --install`) — so `def f() -> str | None` is a launch-time `TypeError`, not a style question. `kib/host`, `kib/shared` and `kib/broker` therefore carry `from __future__ import annotations` and avoid 3.10+ runtime APIs; only `kib/guest` may assume the image's 3.13. Enforced two ways, because neither is sufficient alone: ruff's `per-file-target-version = py39` + `FA102` catches annotations, and `portability.sh` re-parses each module at `feature_version=(3, 9)` and greps the AST for 3.10-only calls (`zip(strict=)`, `dataclass(slots=)`, …) that fail only when *reached*, which an import smoke test would miss. mypy cannot help — 2.x refuses `--python-version 3.9`.

## `fakeowner`: ownership and mode are advisory in the box

Docker Desktop backs every bind with a `fakeowner` layer over virtiofs. Two consequences, both
found on the first real Mac run and neither reproducible on Linux:

**Ownership is invented, so git refuses the project.** The project reaches the sidecar owned
by `root:root` whatever it is on the host. The FUSE server passed `st_uid`/`st_gid` straight
through, the agent runs as `HOST_UID`, and git therefore reported *"detected dubious ownership
in repository"* for the entire tree — taking `git status`, `./dev.sh` (its file discovery is
`git ls-files`) and four of `security-test.sh`'s "the guard must not break ordinary git"
assertions down with it. `prepare_redaction` now passes `--uid`/`--gid` and the server reports
those **in place of whoever owns the project root, and only them**. Redaction is unaffected:
every rule check is uid-independent, which is what makes the remap safe rather than a hole. It
is passed on both platforms — on Linux the base ids already are the agent's, so the map is
identity and one code path beats a second topology.

It is a remap and not a blanket squash because the two are the same everywhere except where it
matters: a file inside the project owned by *someone else* (a `sudo`-built artifact,
`node_modules` from a root container) keeps its real ids, so the check below still refuses it.
`chown` back to the invented owner is translated to `-1` (no change) so `cp -p`, `tar -x` and
`git checkout` do not try to rewrite the backing file to a uid it never had.

**POSIX permissions are enforced by the kernel, not by the server's identity.** Every backing
syscall runs as the *server*, not the caller, so a passthrough enforces no permission at all by
default: a `chmod 000` file read and wrote fine through the view. The mount carries
`default_permissions`, which makes the kernel re-apply a standard owner/mode check against the
**caller's** ids on every operation. The check is *additive* — a handler's own `EACCES` still
stands, so the stubs (`0444`/`0555`) and every write denial are unaffected. Two consequences
worth knowing:

- Mode bits inside the project now behave as they do on the host. Anything that must stay
  read-only can be a mode bit again, though a `:ro` mount or a guard rule is still stronger.
- Inodes the server creates land **on the host**, so it hands each one (`create`, `mkdir`,
  `symlink`) to the caller with `fchown`/`lchown`. kib runs the sidecar as the host user, which
  makes that a no-op — the invariant is what matters, not the coincidence. Best effort:
  `fakeowner` ignores `chown`, and there the reported ids are invented anyway.

**A recursive `chown` over a bind costs ~30s and buys nothing.** The entrypoint used to
`chown -Rh` the whole session dir to retag the symlink farm it had just planted as root. That
dir also holds `plugins/cache` — 100k+ entries of per-project marketplace clones — and every
one of those metadata ops is a virtiofs round-trip to the Mac, *and* a no-op once it lands,
since `fakeowner` ignores `chown`. It ran before the entrypoint `exec`s `sleep infinity`, so
`wait_for_container_ready` spun on it and the whole cold start stalled ~30s with no output. On
a Linux bind the same walk is ~0.1s, which is why it was invisible for so long. The chown is
now `find -maxdepth 5`: the farm is the only root-created thing in there and plants no deeper
than `plugins/cache/<marketplace>/<plugin>/<version>`, so the walk drops 114k → 900 entries
with the same result. Keep the bound in step if `farm_dir`'s depth arguments ever grow.

**Mode bits do not gate access.** `chmod 0400` on a bind is *recorded* faithfully — `stat` reads
back `400` — but `access(2)` still answers writable. Every chmod-based read-only control there is
a silent no-op on macOS. That is how the broker's synthetic `.credentials.json` shipped writable:
it was a `cp` + `chmod 0400`. It is a `:ro` bind now (via `bind_via_link`, since the destination
nests inside the shared-dir mount). Nothing refreshes it under the broker, so a single-file bind
carries none of the rename risk the real rotating credential does. Host-side `chmod 700` on kib's
own scratch dirs is unaffected — that is APFS, not a bind.

## Host key vs box key — one key again

Claude keys `projects/`, `.claude.json` and `history.jsonl` by its **resolved** cwd. Under the
sidecar the redacted view is bound at the project's **host** path, so that mountpoint makes the
`$HOME`-shaped parent a real directory, the entrypoint's `$HOST_HOME` symlink is never created,
and the resolved cwd *is* the host path. Canonical and the session share one key, and
`config_scope`'s `box` argument is left at its default.

The two diverged during the one window kib mounted the view in-container. With no `$PWD` bind,
`$HOST_HOME` became a symlink to the container home, `/Users/<u>/proj` resolved to
`/home/hostuser/proj`, and the box silently kept a second set of entries there — invisible to the
host's `--resume` and ↑ history, and vice versa, which is exactly the seamless switch
`container-lifecycle.md` exists to protect. (It also made three `security-test.sh` cross-project
assertions fail, which is how it surfaced; they were reporting a key mismatch, not a leak.)

`kib_legacy_box_pwd` (host/config.sh) survives for one job: computing that old key so
`start_container` can find transcripts left under it and fold them back into canonical before
relinking. Delete it once no session dir predates the sidecar restore.

One trap that window exposed, and worth keeping: `merge_history`'s dedupe compared raw text.
Claude writes those lines with JS `JSON.stringify` (no space after separators) and re-keying
round-tripped them through Python's `json.dumps`, which does not produce the same bytes — so
nothing matched and every launch re-appended the whole seeded history. It compares
parsed-and-normalised lines now.

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
