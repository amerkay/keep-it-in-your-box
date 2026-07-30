# Sleep guard

Part of the Keep It in Your Box design notes (`docs/design-notes/`). See `CLAUDE.md` for the rules
that reference this.

`host/sleep-guard.sh`: one host-side daemon per terminal. Every 3s it reads **Claude Code's own
state**, published by hooks running inside the box, and holds `systemd-inhibit` while a session is
working — releasing 30s after it goes idle. Tunables: `SLEEP_GUARD_GRACE`, `SLEEP_GUARD_DEBUG=1`,
`SLEEP_GUARD_LID_SUSPEND`, `SLEEP_GUARD_SETTLE`.

## How the state gets out of the box

`guest/policy/managed-settings.json` registers `guest/policy/sleep-hook.py` on the lifecycle
events; both are bound `:ro` into `/etc/claude-code/`, the Linux **managed-policy** directory that
already carries the sandbox `CLAUDE.md`. The hook writes marker files into `$SLEEP_STATE`
(bind-mounted rw at `/run/kib/sleep`), and `host/sleep-state.sh` reads them.

- **Managed settings, never `~/.claude/settings.json`.** `hooks[].command` there is host code
  execution, the box can write that file, and it loads in every project *and* a host `claude` —
  which is exactly why `validate_shared_settings` **dies** on it. That guard stays. Managed scope
  is the one settings layer outside it: highest precedence, unwritable from in the box (`:ro`), and
  never folded back to canonical. Bound, not baked, so editing it needs a relaunch, not a rebuild.
- **Marker files, never a counter.** Hooks run concurrently; create/unlink are atomic where a
  read-modify-write of a shared count loses updates. One file per live subagent, so
  `SubagentStart`/`SubagentStop` never have to pair up in a single number.

      <root>/<tag>/live          hooks are working at all (SessionStart)
      <root>/<tag>/turn          a turn is in flight (UserPromptSubmit → Stop/StopFailure)
      <root>/<tag>/wait          blocked on the USER (question tool, permission prompt)
      <root>/<tag>/agents/<id>   one file per live subagent

      BUSY := (turn AND NOT wait) OR any agents/*

- **`wait` suppresses only the turn, never the agents.** Background subagents keep running while a
  question sits unanswered, and since 2.1.198 background is the *default* for subagents.
- **Scoped per terminal by `KIB_SESSION_TAG`**, which the hook inherits from the session's environ.
  One container serves every terminal, so container-wide state would have three tabs take three
  inhibitors for one tab's work.
- **The hook never writes stdout and always exits 0.** Stdout on `UserPromptSubmit`/`SessionStart`
  is injected into the model's context, and exit 2 blocks the event. A sleep inhibitor must not be
  able to break a session.

## Why the `wchar` byte sampler was retired

It sampled `wchar` from `/proc/<pid>/io` and inferred "working" from the volume of bytes written to
the terminal. Two holes, neither closable by tuning the threshold:

- **A background subagent writes almost nothing to the terminal.** N agents grinding read as idle,
  the guard released, and the machine slept mid-work. This was the reported failure.
- **A question waiting on the user is indistinguishable from a long think.** Both are silent, so
  the threshold had to choose which to get wrong.

Measured before the change: idle 218–374B/poll, spinner 1.4–2.4KB, streaming 3.5KB+, flush spikes
76–250KB. The numbers were never the problem; *inferring state from output volume* was.

`host/sleep-sample.sh` is **deleted**, along with `sleep-monitor`'s two container-side samples, the
per-tag max, and the system-wide top-writers list. It was briefly kept as "forensics", which was
sentiment: byte volume never held an inhibitor — only a lock does — so it explained nothing about a
machine that will not sleep. What the monitor kept from that window is phantom-input detection,
which *is* a real independent cause of a machine staying awake.

## Failure modes, and what closes each

**There is no fallback, and the poll forks nothing.** A stat of the marker tree is the entire
per-poll cost — no byte sampling, no transcript mtime, no `claude agents --json`, no `docker exec`.
A power-saving daemon that spawns a subprocess every 3s is working against itself, and every one of
those alternatives is a dead end below.

- **Hooks not loading** → no `live` marker → verdict `unknown` → treated as **idle**. That is the
  fail-safe direction: a guard that cannot see state must let the machine sleep, never pin it awake
  on a tree it knows nothing about. The guard warns once, but only `UNKNOWN_WARN=90s` after its own
  launch — it starts *before* the session it watches, so the markers are legitimately absent for the
  first seconds of every launch and an immediate warning would fire every time and mean nothing.
- **`kill -9`** fires neither `Stop` nor `SessionEnd`, so a stale `turn` could in principle pin the
  machine awake — except `kib_cleanup` kills the guard when the session exits, so **no guard can
  outlive the session whose markers it reads**. A liveness probe was written for this and removed as
  dead weight. A lock still held with no live guard is an *orphaned inhibitor*, which is a different
  bug and is what `sleep-monitor`'s ORPHANED check is for.
- **Turn died on an API error** → `StopFailure` clears `turn`; without it nothing would.
- **A subagent's own tool calls** carry `agent_id` and share the parent's `session_id`, so the hook
  ignores every event that carries one except `SubagentStart`/`SubagentStop`. Otherwise a subagent's
  `PostToolUse` would clear a `wait` the user is still sitting on.
- **A hostile session** can only lie about *itself*: the tree is bind-mounted rw, so the guard tests
  marker EXISTENCE and never opens one (nothing for a planted symlink to redirect into), and rejects
  a session dir that is itself a symlink. The worst outcome is a session losing its own inhibitor.

## Unchanged, and still load-bearing

- **Proactive suspend:** logind fires the lid-close suspend exactly **once**; blocked by the
  inhibitor it is dropped, never retried — so a task finishing after lid-close stranded the machine
  awake till morning. On going idle the guard runs `systemctl suspend` itself, only when
  unambiguous: lid shut (`/proc/acpi/button/lid/*/state`), no external display
  (`/sys/class/drm/*/status`, non-eDP/LVDS/DSI connected → docked, keep working), no other
  `claude-code` inhibitor held. Retries each idle poll.
- **Post-resume SETTLE window** (`SLEEP_GUARD_SETTLE=15`): without it the guard re-suspended 273ms
  after wake and wedged AMD s2idle.
- **DEAD ENDS:** `--what=idle` inhibitor (makes lid-close always suspend, killing running tasks —
  the block must stay, the re-trigger is the fix); summing bytes or CPU ticks across pids (any sum
  crosses a fixed threshold once the set is big enough, however idle each member — this pinned sleep
  overnight); **transcript mtime** (measured: **80s of total silence during a single long tool
  call**, because transcripts are written at message boundaries — and `wchar` already counted those
  writes anyway, being the same process); **`claude agents --json` as a fallback** (it does report
  `busy`/`waiting` correctly, but it is a ~0.35s `docker exec` of a Node CLI, and a sleep guard that
  forks one of those on a timer to decide whether to save power has lost the plot — markers or
  nothing).
- macOS: `caffeinate -is`; no proactive-suspend port needed (macOS re-evaluates sleep on assertion
  release). Note Claude Code also runs its own `caffeinate -i -t 300` respawner on macOS with no
  opt-out (anthropics/claude-code#21432); there is no Linux equivalent, which is why the guard
  carries the whole job here.
