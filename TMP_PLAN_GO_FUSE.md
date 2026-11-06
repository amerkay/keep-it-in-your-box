# TMP plan: the redaction view in Go (delete when done)

Decided 2026-11-06 from `tmp_gofuse_probe.sh` and `tmp_writeback_probe.sh` (kib-vm, kernel 7.0).
Comes before `TMP_PLAN_GVISOR.md`.

## Measured

- `pnpm install` through the view (`sn-frontend`): Python 98.6 s, stock go-fuse 23.4 s, no FUSE 9.8 s
- Scratch project: Go 3–14× faster than Python on every test (git status, find, 3000 files,
  reads, pnpm, uv)
- Passthrough (needs a root daemon): faster reads only, no gain on writes or installs → not used
- Writeback cache: a host edit that changes a file's size never reaches the box; not faster → never
- Edit delay, both ways: 2–8 ms with Go, as with Python

## Decisions

- Go, `go-fuse` v2 (a released tag), built in `kib build` by a Go stage; static binary
- Full port: `kib/guest/fuse.py`, `kib/shared/render.py`, `kib/shared/rules.py` → Go. One
  matcher: the host's rule checks call the Go binary in the VM
- The daemon runs as the user, as today: same `docker run` flags, same CLI (`--src --mnt --uid
  --gid --patterns-file --guard-file`), SIGHUP reload
- Renders: same verdicts and key names as Python; the format may differ
- Tests: `go test`; fixtures recorded from Python before it goes
- Off FUSE: the VM-local folders, at any depth, on VM volumes; Python caches moved by env
- No setting, no fallback: Go replaces Python once it passes

## Phase 0: fixtures from Python — ✅ done

- [x] `tests/fixtures/redaction/`: `rules.json` (verdicts, opt-outs, tightens), `render.json` +
      `render/` (one input file per shape case), `gitconfig.json` (entries, write checks),
      `fs.json` (steps against a tree, as a mount sees them, and the tree after)
- [x] `record.py` writes them from today's Python; `tests/guest/test_redaction_fixtures.py`
      fails when they are stale. A `note` marks each place Go is meant to differ
- Found, for Phase 1:
  - Matching is case-sensitive: on a case-insensitive disk (macOS, once `~` is mounted) `.ENV`
    opens the real `.env` and `.GIT/hooks/x` writes the real hook. Go folds case (stricter)
  - `!*` un-redacts every `.env`, but the launch's opt-out list misses it (it only names
    negations that match a guard path literally). Go names every wildcard negation too
  - `git_ini_entries` stays in Python on the host too (`asset_scan`): `gitconfig.json` keeps
    the two in step
  - A `@close` refusal (a short mirror) may not reach `close()` on a real mount; Go's mount
    tests check the tree after instead

## Phase 1: the Go daemon (`guest/fuse/`) — ✅ code done, awaiting your test

- [x] `view.go`: classify (redact / protect / pass), stubs 0444/0555, renders, write refusals,
      the byte-identical mirror rule (refused at close, removed if short), the git config
      check on rename, `link()` source and target, `rename()` both ends, exchange refused
- [x] `default_permissions`, `allow_other`, 1 s timeouts, page cache kept only while mtime+size
      and the rules are unchanged; SIGHUP reloads and drops every cached page and name
- [x] Inode numbers per path (as libfuse's were); opens via `openat2`, no symlink on the way
- [x] `rules.go` (case folded), `render.go`, `gitini.go`; subcommands `optouts`, `tightens`
- [x] `go test`: fixtures (rules, renders, git config) in the Dockerfile's Go stage; `fs.json`
      on a real mount in CI (`KIB_FUSE_TESTS=1`) and `tmp_go_mount_test.sh` in kib-vm
- [x] Image: `/usr/local/bin/fuse` is the Go binary; `python3-fusepy`, `libfuse2t64` dropped

## Phase 2: the host uses Go — ✅ code done, awaiting your test

- [x] `host/redaction.sh` + `host/rules-watch.sh`: opt-outs and tightens via `_rules` (the
      sidecar's binary, `docker exec`; a throwaway container for the cold-start opt-out list)
- [x] Deleted `kib/guest/fuse.py`, `test_fuse.py`, `record.py`, `rules.py`'s opt-out/tightens;
      `tests/shared/test_redaction_fixtures.py` holds the remaining Python copies to the spec
- [ ] `security-test.sh` passes in a sandbox, Linux and Mac (yours to run)
- [x] Docs: `redaction-config-guard.md`, `CLAUDE.md`, `CONVENTIONS.md`, `architecture.md`
- Moved to `TMP_PLAN_GVISOR.md` Phase 3: `gitaudit`'s tracked-file match (still `rules.py`,
  which the sync needs until then)

## Phase 3: VM-local folders off FUSE — ✅ code done, awaiting your test

- [x] `local_dirs` (host/redaction.sh): the names at any depth (depth ≤ 6, not inside `.git` or a
      match), kept only where the redacted view has the parent; plus a root `node_modules` /
      `.venv` that `package.json` / `pyproject.toml` / `requirements.txt` implies
- [x] One volume per folder, `<cname>-local-<hash8>`, kept like the cache; the entrypoint
      chowns each root (`KIB_LOCAL_DIRS`). Every engine, VM or not
- [x] Caches by env into `~/.cache`: `PYTHONPYCACHEPREFIX`, `MYPY_CACHE_DIR`, `RUFF_CACHE_DIR`,
      `PYTEST_ADDOPTS=-o cache_dir=…`
- [x] `etc-CLAUDE.md`, `container-lifecycle.md`

## Accepted costs

- The VM-local folders are box-only; the host keeps its own (`pnpm install` with nvm, `uv sync`)
- A VM-local folder made mid-session goes through FUSE until the next container; the first
  container after this change starts each with an empty volume (one reinstall)
- The host's rule checks `docker exec` into the sidecar (~0.1 s), or start a container for the
  cold-start opt-out list
- A redacted file may read in a slightly different format than today
- Rules match case-insensitively: on Linux `README.md` also covers `readme.md`
- `kib build` pulls `golang:1.27-trixie` once; FUSE view edits need a rebuild now
