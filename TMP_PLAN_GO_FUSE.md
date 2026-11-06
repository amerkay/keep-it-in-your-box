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

## Phase 1: the Go daemon (`guest/fuse/`)

- [ ] go-fuse loopback plus kib's overrides: classify (redact / protect / pass), stubs 0444/0555,
      renders, write refusals, the byte-identical mirror rule, the git config content check,
      `link()` and `rename()` checks on both ends
- [ ] `default_permissions`, `allow_other`, 1 s attr/entry timeouts, keep the page cache only
      while mtime and size are unchanged (today's `auto_cache`)
- [ ] Rules: memoise the rule verdict only (the existence check stays live); SIGHUP applies a
      stricter rule set live
- [ ] Renderers in today's order (dotenv → JSON → YAML), each vouching for the whole file; a YAML
      alias found by the parser → stub; the cheap bails kept off the hot path
- [ ] Log the open-file limit at startup (Go raises it itself)
- [ ] Subcommands for the host: `optouts`, `tightens`, `match` (paths on stdin)
- [ ] `go test`: fixtures and unit tests run in the Dockerfile's Go stage (a failing test fails
      `kib build`); real-mount tests ported from `test_fuse.py` run in CI (needs `/dev/fuse`)
- [ ] Image: `/usr/local/bin/fuse` is the Go binary; drop `python3-fusepy` and `libfuse2t64`

## Phase 2: the host uses Go

- [ ] `host/redaction.sh` (opt-outs, tightens), `host/rules-watch.sh`, `kib/host/gitaudit.py`
      (tracked files a rule hides) call the Go binary: `docker exec` into the redaction
      container, else a `docker run --rm`
- [ ] Delete `fuse.py`, `test_fuse.py`, and of `rules.py`/`render.py` all but what the sync still
      needs (the rest goes with the sync, `TMP_PLAN_GVISOR.md` Phase 3)
- [ ] `security-test.sh` passes in a sandbox, Linux and Mac
- [ ] Docs: `redaction-config-guard.md` (Go, and which Python lessons still apply), the
      `CLAUDE.md` dead ends (passthrough and writeback measured: no)

## Phase 3: VM-local folders off FUSE

- [ ] At container create, find `node_modules`, `.pnpm-store`, `.next`, `.nuxt`, `.turbo`,
      `target`, `.terraform`, `.venv`, `venv` at any depth (stop at a match, skip `.git`)
- [ ] One `<cname>-local` volume, kept like the cache volume; one `volume-subpath` mount per
      folder found
- [ ] Caches by env into `~/.cache`: `PYTHONPYCACHEPREFIX`, `MYPY_CACHE_DIR`, `RUFF_CACHE_DIR`,
      `PYTEST_ADDOPTS=-o cache_dir=…`
- [ ] `etc-CLAUDE.md`: these folders are box-only; one made mid-session is on FUSE until the next
      container

## Check early

- The VM's Docker supports `volume-subpath` (Docker 26+), with runc now and gVisor later
- Go's YAML library on keys PyYAML reads differently (`on`, `yes`): a key may print differently,
  but no value may ever appear

## Accepted costs

- The VM-local folders are box-only; the host keeps its own (`pnpm install` with nvm, `uv sync`)
- A VM-local folder made mid-session goes through FUSE until the next container
- The host's rule checks need the VM (always up while kib runs), about 0.3 s each
- A redacted file may read in a slightly different format than today
