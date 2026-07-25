# macOS support (Plan H)

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

`kib` runs on any macOS Docker engine. macOS can't host the Linux FUSE sidecar (measured on Docker Desktop 4.78.0: it refuses the `rshared`/`rslave` mount config because bind sources resolve through the `/host_mnt` sharing layer, and the LinuxKit kernel refuses the unprivileged-userns `uid_map` write — so a truly capless-at-creation in-place FUSE exists only inside a real Linux VM, i.e. Colima). Two redaction modes behind one interface (`prepare_redaction`/`verify_redaction_attach`/`teardown_redaction`; `kib` calls only those), chosen by `KIB_FUSE_MODE`:

- **`sidecar`** (Linux): unchanged, strongest isolation.
- **`single`** (macOS; Linux under `KIB_SINGLE_CONTAINER=1` as a **test vehicle**): no sidecar; the container is created with `SYS_ADMIN`+`SETPCAP`+`/dev/fuse`+`apparmor=unconfined` and the baked `guest/entrypoint/entrypoint-fuse.sh` mounts the redacted view over the project path; the real project sits at `/kib/real` under a root-700 parent. Accepted trade: capless-at-runtime, not capless-at-creation. **The cap drop happens per session in `kib`'s `docker exec`, not at PID 1** — exec gets the *container's* cap set, not PID 1's reduced bounding set, so `kib` enters as root and runs `setpriv --bounding-set -sys_admin,-setpcap gosu <uid> …` itself (`setpriv` needs `CAP_SETPCAP` effective, which a `--user` session lacks). `security-test.sh` asserts `CapBnd` lacks both, auto-detects single mode via `KIB_FUSE_INTERNAL=1`, and adjusts the two differing expectations. **Both modes must pass the full suite.**

## Portability contract

Header of `host/portable.sh`, enforced by `check.sh`: host-side scripts are bash-3.2/BSD-clean — stock macOS, no brew. GNU-only tools (`flock setsid sha256sum grep -P notify-send`) and bash-4isms (`declare -A`, `${var,,}`, `readarray`) only inside `host/portable.sh`'s linux branches. Shims: `lock_fd` (perl flock on the inherited fd — open-file-description semantics identical; release with `lock_fd -u` or `exec N>&-`), `hash8`, `detach_pgrp`, `notify_desktop`, `preflight_platform`. `check.sh` unit-tests the shims by forcing the perl/darwin paths on Linux, so the macOS code paths are proven without a Mac. The Wayland notifier's raw `setsid`/`notify-send` are the one allowed exception (structurally Linux-only; advisory warnings).

**Empty arrays.** bash 3.2 expands `"${arr[@]}"` of an *empty* array as an unbound variable under `set -u` — it aborts the launch, and only 4.4 fixed it. Every array ever assigned `()` expands through `${arr[@]+"${arr[@]}"}`, including where it reads as provably non-empty: the reader cannot verify that, and one later edit makes it empty. This shipped once — a sessionless first Mac run died in `start_broker` on `tok_mounts[@]: unbound variable`, because a Mac with no brokered MCP routes is exactly the case where the array is empty. `portability.sh` now derives the `X=()` names per file and fails on any bare expansion left.

**Host-side python is 3.9.** `kib_py` runs whatever `python3` the host has, and stock macOS ships 3.9 (`xcode-select --install`) — so `def f() -> str | None` is a launch-time `TypeError`, not a style question. `kib/host`, `kib/shared` and `kib/broker` therefore carry `from __future__ import annotations` and avoid 3.10+ runtime APIs; only `kib/guest` may assume the image's 3.13. Enforced two ways, because neither is sufficient alone: ruff's `per-file-target-version = py39` + `FA102` catches annotations, and `portability.sh` re-parses each module at `feature_version=(3, 9)` and greps the AST for 3.10-only calls (`zip(strict=)`, `dataclass(slots=)`, …) that fail only when *reached*, which an import smoke test would miss. mypy cannot help — 2.x refuses `--python-version 3.9`.

## Clipboard and DNS on macOS

macOS clipboard: `clipboard-bridge.sh` (host, POSIX sh) watches a spool dir at `/kib-clip`; the entrypoint installs `wl-paste`/`xclip` reader shims and `wl-copy`/`pbcopy` deny-marker shims; the host answers with `pbpaste`/osascript PNG extraction and **never calls `pbcopy`**. Started/stopped like the Wayland notifier including the `200>&- 201>&-`.

DNS sync is skipped on macOS (the engine VM tracks the host resolver). No migration step: on a fresh Mac `ensure_claude_home` creates a minimal `~/.claude` skeleton on first launch (first login populates it); nothing to bootstrap.

## Still open — on-hardware VERIFY (Mac only)

- Which reader Claude invokes for image paste (`WAYLAND_DISPLAY` routes to the `wl-paste` shim; if it's `xclip`/`DISPLAY`, a one-line flip — both shims installed).
- virtiofs file ownership (affects passthrough reads only — `_deny_if_masked` is uid-independent).
