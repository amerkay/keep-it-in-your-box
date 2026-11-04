#!/usr/bin/env bash
# Read-only, Linux host: "did the machine sleep, and was Claude working?" (docs/design-notes/sleep-guard.md)
# Writes one report to the repo root, which the sandbox can read.
# Usage: scripts/sleep-incident.sh [hours_back=12] [project_dir]   # no project = every project
set -uo pipefail

HOURS="${1:-12}"
PROJ="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/sleep-incident-$(date +%Y%m%d-%H%M%S).txt"
SINCE="$(date -d "-${HOURS} hours" '+%Y-%m-%d %H:%M:%S')"
SLUG="$([ -n "$PROJ" ] && printf '%s' "$(cd "$PROJ" && pwd)" | sed 's/[^a-zA-Z0-9]/-/g')"
SR="${KIB_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/keep-it-in-your-box}"
# Word-bounded: a bare `lid` matches every "invalid" in the journal.
EVENTS='PM: (suspend|hibernat)|will (suspend|hibernate|sleep|power off)|\bLid (opened|closed)|Power key|Suspend key|System is (rebooting|powering)|battery.*(low|critical)'

sec() { printf '\n===== %s =====\n' "$1"; }

{
    echo "generated $(date -Is)  since $SINCE  project ${PROJ:-<all>}"

    sec "VERDICT INPUTS"
    echo "suspends entered : $(journalctl -k --since "$SINCE" --no-pager 2>/dev/null | grep -ac 'PM: suspend entry')"
    echo "lid closes       : $(journalctl --since "$SINCE" --no-pager 2>/dev/null | grep -ac 'Lid closed')"
    echo "kib locks now    : $(systemd-inhibit --list --no-pager 2>/dev/null | grep -ac claude-code)"
    echo "(0 suspends + steady transcript activity below = it never slept; a dark screen is not sleep)"

    sec "SLEEP / WAKE / LID / POWER EVENTS (system journal)"
    journalctl --since "$SINCE" --no-pager -o short-iso 2>&1 | grep -aE "$EVENTS" | head -300

    sec "POWERDEVIL (KDE; empty elsewhere)"
    journalctl --user --since "$SINCE" --no-pager -o short-iso -u plasma-powerdevil.service 2>&1 | head -150

    sec "INHIBITORS NOW"
    systemd-inhibit --list --no-pager 2>&1

    sec "SLEEP-GUARD MARKER TREES (a tree left behind = its session never ended cleanly)"
    for d in "$SR"/.state/"$SLUG"*.sleep; do
        [ -d "$d" ] && echo "-- ${d##*/}" && find "$d" -printf '%TY-%Tm-%Td %TH:%TM:%.2TS  %P\n' | sort
    done

    sec "TRANSCRIPT ACTIVITY (metadata only — never message content)"
    python3 -I - "$HOME/.claude/projects${SLUG:+/$SLUG}" "$HOURS" <<'PY'
import collections, datetime as dt, json, pathlib, sys, time
base, cut = pathlib.Path(sys.argv[1]), time.time() - float(sys.argv[2]) * 3600
rows = []
for f in base.rglob("*.jsonl"):
    if f.stat().st_mtime < cut:
        continue
    parts = list(f.relative_to(base).parts)  # subagent files count toward their parent session
    parts = parts[: parts.index("subagents")] if "subagents" in parts else parts[:-1] + [f.stem]
    sess = "/".join(parts)[-48:]
    for line in f.open(errors="replace"):
        try:
            e = json.loads(line)
            t = dt.datetime.fromisoformat(e["timestamp"].replace("Z", "+00:00")).astimezone()
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        if t.timestamp() < cut:
            continue
        bits = []
        content = (e.get("message") or {}).get("content")
        for c in content if isinstance(content, list) else []:
            kind = c.get("type") if isinstance(c, dict) else None
            if kind == "tool_use":
                i = c.get("input") or {}
                bits.append("USE %s timeout=%s bg=%s" % (
                    c.get("name"), i.get("timeout"), i.get("run_in_background")))
            elif kind == "tool_result":
                bits.append("RESULT")
        kind = e.get("type", "?") + ("/" + e["subtype"] if e.get("subtype") else "")
        rows.append((t, sess, "sub" if "subagents" in f.parts else "main", kind, " ".join(bits)))
rows.sort(key=lambda r: r[0])
if not rows:
    print("no transcript entries in the window under", base)
    sys.exit()

print("-- entries per hour per session (main | subagents)")
hist = collections.Counter((r[0].strftime("%m-%d %Hh"), r[1], r[2]) for r in rows)
for hour, sess in sorted({(h, s) for h, s, _ in hist}):
    print(f"{hour}  {hist[hour, sess, 'main']:5} | {hist[hour, sess, 'sub']:5}  {sess}")

print("\n-- silences > 5 min across ALL activity (a sleep shows here as hours)")
for a, b in zip(rows, rows[1:]):
    if (b[0] - a[0]).total_seconds() > 300:
        print(f"{a[0]:%m-%d %H:%M:%S} -> {b[0]:%H:%M:%S}  {int((b[0] - a[0]).total_seconds() // 60)} min")
print(f"last entry {rows[-1][0]:%m-%d %H:%M:%S}  ({int(time.time() - rows[-1][0].timestamp())}s ago)")

print("\n-- timeline")
for t, sess, who, kind, bits in rows:
    print(f"{t:%m-%d %H:%M:%S}  {who:4}  {sess[-12:]}  {kind}  {bits}")
PY
} >"$OUT" 2>&1

echo "report: $OUT"
