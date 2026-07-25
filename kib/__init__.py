"""keep-it-in-your-box — the one importable package behind the `kib` sandbox.

Sub-packages mirror the trust boundary the repo is organised around:

* `kib.shared` — imported by both sides. The reviewable contract: rule parsing, the
  host-executed-config key tables, atomic JSON, exit codes, logging.
* `kib.host`   — runs as the user, on the host. Never enters a container.
* `kib.guest`  — runs inside a container under `cap-drop=ALL`. Assume hostile input.
* `kib.broker` — spans the boundary; every module's docstring names the side it runs on.

Stdlib only: the guest half runs off the image's bare `python3`, so a pip dependency
anywhere reachable from it breaks the launch path.
"""
