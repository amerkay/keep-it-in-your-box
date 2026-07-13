#!/usr/bin/env bash
# migrate-sessions.sh — one-time migration to per-project Claude Code sessions.
#
# Claude Code runs a singleton background-agent daemon arbitrated by a lock file in
# its config dir. `cc` used to bind-mount host ~/.claude read-write into EVERY
# container, so two concurrent sessions fought over one daemon.lock (and, being in
# separate PID namespaces, each read the other's pid against its own /proc and
# displaced it). The same shared mount also let any container read every other
# project's transcripts, prompt history and paste cache.
#
# This script splits that one directory in two:
#
#   ~/.claude-shared/       shared by every container — login token, settings,
#                           plugins, skills, agents, commands, hooks, CLAUDE.md
#   ~/.claude-sandbox/<slug>/   mounted ONLY in that project's container — daemon,
#                           sessions, jobs, transcripts, history, .claude.json
#
# `cc` then points CLAUDE_CONFIG_DIR at the per-project dir and
# CLAUDE_SECURESTORAGE_CONFIG_DIR at the shared one: isolated state, one login.
#
# Dry run by default. `--apply` copies, then deletes ~/.claude and ~/.claude.json.
#
#   ./migrate-sessions.sh            # show exactly what would happen
#   ./migrate-sessions.sh --apply    # do it
#   ./migrate-sessions.sh --apply --force   # redo over an existing migration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPLY=0
FORCE=0
for arg in "$@"; do
	case "$arg" in
		--apply) APPLY=1 ;;
		--force) FORCE=1 ;;
		-h | --help)
			sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "migrate-sessions.sh: unknown argument '$arg' (try --help)" >&2
			exit 2
			;;
	esac
done

CLAUDE_DIR="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"
SHARED_DIR="$HOME/.claude-shared"
SANDBOX_DIR="$HOME/.claude-sandbox"

# ── Preflight ────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
	echo "❌ python3 is required (JSON surgery on .claude.json)." >&2
	exit 1
fi

if [ -f "$SHARED_DIR/.migrated" ] && [ "$FORCE" != 1 ]; then
	echo "✓ Already migrated ($SHARED_DIR/.migrated exists)." >&2
	echo "  To redo from scratch: ./migrate-sessions.sh --apply --force" >&2
	echo "  (that wipes $SHARED_DIR and $SANDBOX_DIR first)" >&2
	exit 0
fi

if [ ! -d "$CLAUDE_DIR" ] || [ ! -f "$CLAUDE_JSON" ]; then
	echo "❌ Nothing to migrate: expected $CLAUDE_DIR/ and $CLAUDE_JSON." >&2
	exit 1
fi

if [ ! -f "$SCRIPT_DIR/shared-CLAUDE.md" ]; then
	echo "❌ Missing $SCRIPT_DIR/shared-CLAUDE.md (the shared sandbox policy)." >&2
	exit 1
fi

# Copying a directory that a live Claude is writing to yields a torn copy, and
# --apply then deletes it out from under that process. Only enforced for --apply;
# a dry run reads nothing it can damage.
if [ "$APPLY" = 1 ] && [ "${CC_MIGRATE_TEST:-0}" != 1 ]; then
	_busy=""
	if command -v docker >/dev/null 2>&1; then
		_running="$(docker ps --filter 'name=^cc-' --format '{{.Names}}' 2>/dev/null || true)"
		[ -n "$_running" ] && _busy="cc containers still running:"$'\n'"$(printf '%s\n' "$_running" | sed 's/^/     /')"
	else
		echo "⚠️  docker not found — cannot verify that no cc container is running." >&2
	fi
	_pids="$(pgrep -x claude 2>/dev/null || true)"
	if [ -n "$_pids" ]; then
		_busy="${_busy:+$_busy$'\n'}claude processes still running: $(echo "$_pids" | tr '\n' ' ')"
	fi
	if [ -n "$_busy" ]; then
		echo "❌ Refusing to migrate while Claude is running." >&2
		printf '   %s\n' "$_busy" >&2
		echo "   Quit every Claude session (host and container), then re-run." >&2
		exit 1
	fi
fi
[ "${CC_MIGRATE_TEST:-0}" = 1 ] && echo "⚠️  CC_MIGRATE_TEST=1 — safety checks disabled (development only)." >&2

if [ "$APPLY" = 1 ] && [ "$FORCE" = 1 ]; then
	rm -rf "$SHARED_DIR" "$SANDBOX_DIR"
fi

# ── Migrate ──────────────────────────────────────────────────
APPLY="$APPLY" \
	CLAUDE_DIR="$CLAUDE_DIR" CLAUDE_JSON="$CLAUDE_JSON" \
	SHARED_DIR="$SHARED_DIR" SANDBOX_DIR="$SANDBOX_DIR" \
	SHARED_CLAUDE_MD="$SCRIPT_DIR/shared-CLAUDE.md" \
	python3 - <<'PYTHON'
import json, os, re, shutil, sys, time

APPLY      = os.environ["APPLY"] == "1"
SRC        = os.environ["CLAUDE_DIR"]
SRC_JSON   = os.environ["CLAUDE_JSON"]
SHARED     = os.environ["SHARED_DIR"]
SANDBOX    = os.environ["SANDBOX_DIR"]
SHARED_MD  = os.environ["SHARED_CLAUDE_MD"]

# Container-side path of the shared dir. Plugin manifests store absolute install
# paths; they were written against ~/.claude (as /home/kay/.claude when Claude ran
# on the host, /home/hostuser/.claude when it ran in a container). Neither path
# exists after this migration, so they get rewritten to the one path that is always
# mounted in every container.
SHARED_IN_CONTAINER = "/home/hostuser/.claude-shared"

# Project entries Claude records for a cwd that isn't a real project on this host.
JUNK_PROJECTS = {"/", "/workspace"}

SHARED_FILES = [".credentials.json", "settings.json", "keybindings.json"]
SHARED_DIRS  = ["plugins", "skills", "agents", "commands", "hooks"]

# Everything left in ~/.claude after the copies above. Listed so the report can say
# what --apply throws away rather than silently deleting it.
DROPPED = ["plans", "paste-cache", "debug", "backups", "downloads", "shell-snapshots",
           "cache", "sessions", "daemon", "daemon.lock", "daemon.log",
           "daemon.status.json", "stats-cache.json", "mcp-needs-auth-cache.json",
           "statsig", ".last-cleanup", ".sleep-inhibit"]

def slug_of(path):
    """Same scheme Claude uses for ~/.claude/projects/ — non-alphanumerics to '-'."""
    return re.sub(r"[^a-zA-Z0-9]", "-", path)

def size_of(path):
    if os.path.islink(path) or os.path.isfile(path):
        try: return os.path.getsize(path)
        except OSError: return 0
    total = 0
    for root, dirs, files in os.walk(path, followlinks=False):
        for f in files:
            try: total += os.path.getsize(os.path.join(root, f))
            except OSError: pass
    return total

def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024

copied_bytes = 0

def copy(src, dst):
    """Copy a file or tree. Returns bytes, 0 if the source doesn't exist."""
    global copied_bytes
    if not os.path.exists(src):
        return 0
    n = size_of(src)
    copied_bytes += n
    if APPLY:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.isdir(src) and not os.path.islink(src):
            shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst, follow_symlinks=False)
    return n

def write_json(path, obj):
    if APPLY:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            json.dump(obj, fh, indent=2)

def say(*a): print(*a)

# ── Load ─────────────────────────────────────────────────────
with open(SRC_JSON) as fh:
    cj = json.load(fh)

all_projects = cj.get("projects", {}) or {}
projects = {p: e for p, e in all_projects.items() if p not in JUNK_PROJECTS}
skipped_junk = sorted(set(all_projects) - set(projects))

# A slug collision would merge two projects' transcripts into one dir — exactly the
# contamination this migration exists to prevent. Refuse rather than guess.
by_slug = {}
for p in projects:
    by_slug.setdefault(slug_of(p), []).append(p)
collisions = {s: ps for s, ps in by_slug.items() if len(ps) > 1}
if collisions:
    say("❌ Slug collision — two project paths map to one directory name:")
    for s, ps in collisions.items():
        say(f"     {s}")
        for p in ps: say(f"       ← {p}")
    say("   Rename one of the directories and re-run.")
    sys.exit(1)

# Transcript dirs whose project has no .claude.json entry would be orphaned.
have_dirs = set(os.listdir(os.path.join(SRC, "projects"))) if os.path.isdir(os.path.join(SRC, "projects")) else set()
orphan_dirs = sorted(have_dirs - set(by_slug) - {slug_of(p) for p in JUNK_PROJECTS})

mode = "APPLY — writing changes" if APPLY else "DRY RUN — nothing will be written"
say()
say("┌─ cc session isolation: migration ────────────────────────────────")
say(f"│  {mode}")
say(f"│  from  {SRC}/  +  {SRC_JSON}")
say(f"│  to    {SHARED}/     shared: login, settings, plugins, skills")
say(f"│        {SANDBOX}/<slug>/   per-project: daemon, sessions, history")
say("└──────────────────────────────────────────────────────────────────")

# ── Shared dir ───────────────────────────────────────────────
say()
say(f"▶ Shared  →  {SHARED}")
for name in SHARED_FILES:
    src = os.path.join(SRC, name)
    if os.path.exists(src):
        say(f"    COPY   {name:<34} {human(copy(src, os.path.join(SHARED, name))):>10}")
for name in SHARED_DIRS:
    src = os.path.join(SRC, name)
    if os.path.isdir(src):
        say(f"    COPY   {name + '/':<34} {human(copy(src, os.path.join(SHARED, name))):>10}")
    else:
        say(f"    MKDIR  {name + '/':<34} {'(new, empty)':>10}")
        if APPLY:
            os.makedirs(os.path.join(SHARED, name), exist_ok=True)
if APPLY:
    os.makedirs(os.path.join(SHARED, "plugins", "marketplaces"), exist_ok=True)

# Rewrite the plugin manifests' absolute install paths.
for manifest in ("plugins/installed_plugins.json", "plugins/known_marketplaces.json"):
    src = os.path.join(SRC, manifest)
    if not os.path.isfile(src):
        continue
    raw = open(src).read()
    fixed = re.sub(r"/home/[^/\"]+/\.claude/plugins", SHARED_IN_CONTAINER + "/plugins", raw)
    n = len(re.findall(r"/home/[^/\"]+/\.claude/plugins", raw))
    say(f"    EDIT   {manifest:<34} {n} path(s) → {SHARED_IN_CONTAINER}/plugins")
    if APPLY:
        with open(os.path.join(SHARED, manifest), "w") as fh:
            fh.write(fixed)

# Existing user memory carries over as-is. The sandbox policy is NOT written here:
# cc maintains it in a marker-delimited block at the top of this same file on every
# launch, and anything outside that block is treated as the user's. Seeding the
# policy as plain content would make cc's first sync see it as user memory and keep
# a second copy of it below the block.
src_md = os.path.join(SRC, "CLAUDE.md")
if os.path.isfile(src_md) and os.path.getsize(src_md) > 0:
    say(f"    COPY   {'CLAUDE.md':<34} {human(copy(src_md, os.path.join(SHARED, 'CLAUDE.md'))):>10}  (user memory)")
else:
    say(f"    SKIP   {'CLAUDE.md':<34} {'(none)':>10}  cc writes the sandbox policy on first launch")

# Global keys, minus anything project-scoped. This is what a brand-new project's
# .claude.json starts from, so it skips onboarding but knows nothing about any
# other project. githubRepoPaths maps repo → absolute paths, so it is dropped too.
seed = {k: v for k, v in cj.items() if k not in ("projects", "githubRepoPaths")}
seed["projects"] = {}
say(f"    WRITE  {'claude-json.seed':<34} {len(seed) - 1:>7} global keys  (template for new projects)")
write_json(os.path.join(SHARED, "claude-json.seed"), seed)

# ── Per-project dirs ─────────────────────────────────────────
say()
say(f"▶ Projects ({len(projects)})  →  {SANDBOX}/<slug>/")

# history.jsonl and jobs/ are single shared stores keyed by project path; index them
# once, then hand each project only its own rows.
history = {}
history_orphans = 0
hist_path = os.path.join(SRC, "history.jsonl")
if os.path.isfile(hist_path):
    for line in open(hist_path, errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            proj = json.loads(line).get("project")
        except (ValueError, AttributeError):
            history_orphans += 1
            continue
        if proj in projects:
            history.setdefault(proj, []).append(line)
        else:
            history_orphans += 1

jobs = {}
jobs_orphans = 0
jobs_root = os.path.join(SRC, "jobs")
if os.path.isdir(jobs_root):
    for job_id in sorted(os.listdir(jobs_root)):
        state = os.path.join(jobs_root, job_id, "state.json")
        cwd = None
        if os.path.isfile(state):
            try:
                cwd = json.load(open(state)).get("cwd")
            except ValueError:
                pass
        if cwd in projects:
            jobs.setdefault(cwd, []).append(job_id)
        else:
            jobs_orphans += 1

grp_all = cj.get("githubRepoPaths") or {}

for path in sorted(projects):
    slug = slug_of(path)
    dest = os.path.join(SANDBOX, slug)
    entry = projects[path]
    lines = []

    # Transcripts + per-project memory.
    tsrc = os.path.join(SRC, "projects", slug)
    sessions = []
    if os.path.isdir(tsrc):
        n = copy(tsrc, os.path.join(dest, "projects", slug))
        sessions = [f[:-6] for f in os.listdir(tsrc) if f.endswith(".jsonl")]
        lines.append(f"COPY   projects/{slug}".ljust(52) + f"{human(n):>10}  {len(sessions)} session(s)")

    # file-history (rewind/checkpoints), session-env and tasks are all keyed by
    # session UUID, so this project's sessions select its rows out of each.
    for store in ("file-history", "session-env", "tasks"):
        hit, total = 0, 0
        for uid in sessions:
            s = os.path.join(SRC, store, uid)
            if os.path.exists(s):
                total += copy(s, os.path.join(dest, store, uid))
                hit += 1
        if hit:
            lines.append(f"COPY   {store}/ × {hit}".ljust(52) + f"{human(total):>10}")

    # Background jobs, keyed by the cwd they were launched from.
    ids = jobs.get(path, [])
    if ids:
        total = sum(copy(os.path.join(jobs_root, j), os.path.join(dest, "jobs", j)) for j in ids)
        lines.append(f"COPY   jobs/ × {len(ids)}".ljust(52) + f"{human(total):>10}")

    # Prompt history — only this project's lines, so ↑ never surfaces another
    # project's prompts (or its pasted content).
    hl = history.get(path, [])
    if hl:
        lines.append(f"WRITE  history.jsonl".ljust(52) + f"{len(hl):>7} lines")
        if APPLY:
            os.makedirs(dest, exist_ok=True)
            with open(os.path.join(dest, "history.jsonl"), "w") as fh:
                fh.write("\n".join(hl) + "\n")

    # .claude.json: every global key (oauthAccount, onboarding flags, caches) plus
    # exactly one project entry — this one, carrying its own mcpServers, trust flag
    # and allowedTools.
    pj = {k: v for k, v in cj.items() if k not in ("projects", "githubRepoPaths")}
    grp = {repo: [p for p in paths if p == path] for repo, paths in grp_all.items()}
    grp = {repo: paths for repo, paths in grp.items() if paths}
    if grp:
        pj["githubRepoPaths"] = grp
    pj["projects"] = {path: entry}
    mcp = list((entry.get("mcpServers") or {}).keys())
    lines.append(f"WRITE  .claude.json".ljust(52) + f"{'1 project':>9}" + (f"  mcp: {', '.join(mcp)}" if mcp else ""))
    write_json(os.path.join(dest, ".claude.json"), pj)
    if APPLY:
        os.chmod(dest, 0o700)

    say()
    say(f"  {path}")
    say(f"  └─ {slug}/")
    for l in lines:
        say(f"       {l}")

# ── What gets thrown away ────────────────────────────────────
say()
say("▶ Dropped (not copied — stale, machine-local, or not project-scoped)")
dropped_bytes = 0
present = []
for name in DROPPED:
    p = os.path.join(SRC, name)
    if os.path.exists(p):
        n = size_of(p)
        dropped_bytes += n
        present.append(f"{name} ({human(n)})")
for i in range(0, len(present), 3):
    say("    " + "   ".join(present[i:i + 3]))
if history_orphans:
    say(f"    history.jsonl: {history_orphans} line(s) belonging to no migrated project")
if jobs_orphans:
    say(f"    jobs/: {jobs_orphans} job(s) whose cwd is no longer a migrated project")
if skipped_junk:
    say(f"    .claude.json entries for non-project cwds: {', '.join(skipped_junk)}")
if orphan_dirs:
    say(f"    ⚠️  transcript dirs with no .claude.json entry (WOULD BE LOST): {', '.join(orphan_dirs)}")

say()
say("▶ Delete")
say(f"    rm -rf {SRC}".ljust(56) + f"{human(size_of(SRC)):>10}")
say(f"    rm -f  {SRC_JSON}".ljust(56) + f"{human(size_of(SRC_JSON)):>10}")

if APPLY:
    with open(os.path.join(SHARED, ".migrated"), "w") as fh:
        json.dump({"version": 1, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                   "projects": len(projects)}, fh, indent=2)
    shutil.rmtree(SRC)
    os.remove(SRC_JSON)
    for extra in (SRC_JSON + ".backup", SRC_JSON + ".lock"):
        if os.path.exists(extra):
            os.remove(extra)

say()
say(f"  {len(projects)} project(s), {human(copied_bytes)} copied.")
if APPLY:
    say("  ✅ Migrated. ~/.claude and ~/.claude.json are gone; cc now runs isolated per project.")
else:
    say("  DRY RUN — nothing changed. Re-run with --apply to commit.")
say()
PYTHON
