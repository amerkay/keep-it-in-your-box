# macOS support (Plan H)

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

`cc` runs on any macOS Docker engine. macOS can't host the Linux FUSE sidecar (Docker Desktop refuses shared-mount propagation and blocks unprivileged-userns FUSE — measured, `../FUTURE_TASKS.md` Gate B). Two redaction modes behind one interface (`prepare_redaction`/`verify_redaction_attach`/`teardown_redaction`; `cc` calls only those), chosen by `CC_FUSE_MODE`:

- **`sidecar`** (Linux): unchanged, strongest isolation.
- **`single`** (macOS; Linux under `CC_SINGLE_CONTAINER=1` as a **test vehicle**): no sidecar; the container is created with `SYS_ADMIN`+`SETPCAP`+`/dev/fuse`+`apparmor=unconfined` and the baked `entrypoint-fuse.sh` mounts the redacted view over the project path; the real project sits at `/cc/real` under a root-700 parent. Accepted R2 trade: capless-at-runtime, not capless-at-creation. **The cap drop happens per session in `cc`'s `docker exec`, not at PID 1** — exec gets the *container's* cap set, not PID 1's reduced bounding set, so `cc` enters as root and runs `setpriv --bounding-set -sys_admin,-setpcap gosu <uid> …` itself (`setpriv` needs `CAP_SETPCAP` effective, which a `--user` session lacks). `security-test.sh` asserts `CapBnd` lacks both, auto-detects single mode via `CC_FUSE_INTERNAL=1`, and adjusts the two differing expectations. **Both modes must pass the full suite.**

## Portability contract

Header of `cc-portable.sh`, enforced by `check.sh`: host-side scripts are bash-3.2/BSD-clean — stock macOS, no brew. GNU-only tools (`flock setsid sha256sum grep -P notify-send`) and bash-4isms (`declare -A`, `${var,,}`, `readarray`) only inside `cc-portable.sh`'s linux branches. Shims: `lock_fd` (perl flock on the inherited fd — open-file-description semantics identical; release with `lock_fd -u` or `exec N>&-`), `hash8`, `detach_pgrp`, `notify_desktop`, `preflight_platform`. `check.sh` unit-tests the shims by forcing the perl/darwin paths on Linux, so the macOS code paths are proven without a Mac. The Wayland notifier's raw `setsid`/`notify-send` are the one allowed exception (structurally Linux-only; advisory warnings).

## Clipboard and DNS on macOS

macOS clipboard: `clipboard-bridge.sh` (host, POSIX sh) watches a spool dir at `/cc/clip`; the entrypoint installs `wl-paste`/`xclip` reader shims and `wl-copy`/`pbcopy` deny-marker shims; the host answers with `pbpaste`/osascript PNG extraction and **never calls `pbcopy`**. Started/stopped like the Wayland notifier including the `200>&- 201>&-`.

DNS sync is skipped on macOS (the engine VM tracks the host resolver). No migration step: on a fresh Mac `ensure_claude_home` creates a minimal `~/.claude` skeleton on first launch (first login populates it); nothing to bootstrap.

## Still open — on-hardware VERIFY (Mac only)

- Which reader Claude invokes for image paste (`WAYLAND_DISPLAY` routes to the `wl-paste` shim; if it's `xclip`/`DISPLAY`, a one-line flip — both shims installed).
- virtiofs file ownership (affects passthrough reads only — `_deny_if_masked` is uid-independent).

README "macOS ❌" rows flip only after these pass.
