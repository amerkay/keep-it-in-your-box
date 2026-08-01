"""MCP wiring: inject brokered routes, warn about inline secrets, adopt, add, intercept.

One of these five jobs handles live credentials, so all five share one argv interface here
rather than being split across ad hoc scripts.

All five run HOST-SIDE, before any `docker exec`. That placement is the whole point of the
interceptor: a process's argv is already inside the box by the time the box could inspect
it, so a pasted `kib claude mcp add --header "Authorization: …"` has to be caught out here.

None of them ever prints a secret value.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from typing import Any

from kib.broker import helpers, registry
from kib.shared import cli, jsonio

#: Marks the `.claude.json` entries kib owns, so a launch can drop its own stale ones and
#: never touch a user-authored server.
MARKER = "_kibBroker"


def _is_ours(entry: object) -> bool:
    return isinstance(entry, dict) and bool(entry.get(MARKER))


def _servers(path: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """`(whole config, mcpServers)` for a config file. Missing/corrupt reads as empty."""
    data = jsonio.load_dict(path)
    servers = data.get("mcpServers")
    return data, servers if isinstance(servers, dict) else {}


# ── inject: write every active brokered route into the agent's .claude.json ──────
def inject(args: argparse.Namespace) -> int:
    """Write header-free broker URLs for every active brokered MCP route.

    kib owns these entries: each launch drops the stale ones it owns and rewrites the
    current set, so disabling a provider cleanly removes its entry. The agent never holds a
    credential for them — the broker injects the header on the way out.

    reverse_proxy_mcp routes point at the broker alias; hosted_mcp routes point at their own
    sidecar's network alias, and only if that sidecar actually came up.
    """
    hosted_up = set(args.hosted_up.split())
    specs: list[tuple[str, str, str]] = []
    for pid, p in registry.PROVIDERS.items():
        delivery = p.get("delivery")
        if delivery == "reverse_proxy_mcp":
            token = os.path.join(args.kib_dir, p.get("token_basename", ""))
            if not (os.path.isfile(token) and os.path.getsize(token)):
                continue
            host = args.broker_host
        elif delivery == "hosted_mcp":
            if pid not in hosted_up:
                continue
            host = pid
        else:
            continue
        name = p.get("mcp_server_name") or ""
        if not name:
            continue
        specs.append((name, p.get("mcp_transport") or "http", registry.agent_url(pid, p, host)))

    data, servers = _servers(args.config)
    servers = {k: v for k, v in servers.items() if not _is_ours(v)}
    for name, transport, url in specs:
        servers[name] = {"type": transport, "url": url, MARKER: True}
    data["mcpServers"] = servers
    jsonio.write_atomic(args.config, data)
    if specs:
        names = ", ".join(s[0] for s in specs)
        sys.stderr.write(f"🔐 brokered MCP(s) wired into .claude.json: {names}\n")
    return cli.OK


# ── warn: an inline credential the agent can read (detector, never a blocker) ────
def _inline_secret_reason(entry: dict[str, Any]) -> str | None:
    for k, v in (entry.get("headers") or {}).items():
        if v and helpers.is_auth_header(k, str(v)):
            return "inline auth header"
    for k, v in (entry.get("env") or {}).items():
        if v and helpers.env_is_secret(f"{k}={v}"):
            return f"inline env secret ({k})"
    return None


def warn(args: argparse.Namespace) -> int:
    """Flag MCP entries carrying a credential the agent can read. Warn only, never block.

    Reads CANONICAL `~/.claude.json`, not the session copy: the session copy is rebuilt
    from canonical on every cold start, so a warning raised off it would be stale — and,
    worse, `adopt`'s strip would be silently undone by the next launch's re-assembly.
    """
    for label, path in (("project .mcp.json", args.mcp_json), ("~/.claude.json", args.claude_json)):
        if not path:
            continue
        _, servers = _servers(path)
        for name, entry in servers.items():
            if not isinstance(entry, dict) or _is_ours(entry):
                continue  # our brokered entries carry no secret
            reason = _inline_secret_reason(entry)
            if reason:
                # The value is NEVER printed — only the name and the reason.
                sys.stderr.write(
                    f'⚠️  MCP "{name}" ({label}) carries an {reason} the agent can read — '
                    "it is already sent to the API.\n"
                )
                sys.stderr.write(f"   Broker it instead:  kib mcp adopt {name}\n")
    return cli.OK


# ── adopt: migrate an inline-credential MCP into the broker ──────────────────────
def adopt(args: argparse.Namespace) -> int:
    """Store the secret host-side, strip the inline entry, leave a brokered route behind.

    Only a remote MCP whose upstream matches a reverse_proxy_mcp route can be adopted; a
    local/stdio MCP needs a hosted_mcp definition (`kib broker add … --run …`) instead.
    """
    name = args.name
    hit = None
    for path in (args.mcp_json, args.claude_json):
        if not path:
            continue
        data, servers = _servers(path)
        if isinstance(servers.get(name), dict):
            hit = (path, data, servers, servers[name])
            break
    if hit is None:
        raise cli.AbortError(
            f"no MCP named {name!r} with an inline config found in .mcp.json or .claude.json"
        )
    path, data, servers, entry = hit
    if _is_ours(entry):
        raise cli.AbortError(f"{name!r} is already a brokered entry — nothing to adopt.")

    url = entry.get("url", "")
    hdrname, authval = helpers.find_auth_header(list((entry.get("headers") or {}).items()))
    if not url or not authval:
        raise cli.AbortError(
            f"{name!r} has no inline remote auth header to broker. A local/stdio MCP needs a "
            "hosted_mcp definition (kib broker add … --run …), not adoption."
        )

    # Reuse an existing brokered route for this host, else SYNTHESIZE a provider def from the
    # inline entry — that is what makes adoption work for an MCP we have never heard of. No MCP
    # is built in, so a match is always a prior user route.
    matched = registry.match_upstream_route(url)
    if matched:
        pid, basename, scheme = matched
        where = f"existing route '{pid}'"
    else:
        bad = helpers.validate_route_id(name, registry.BUILTIN_IDS)
        if bad:
            raise cli.AbortError(f"cannot broker {name!r}: {bad}", cli.REFUSED)
        scheme = helpers.scheme_of(authval)
        transport = entry.get("type") if entry.get("type") in ("http", "sse") else "http"
        try:
            prov = helpers.synthesize_reverse_proxy(name, url, hdrname or "", scheme, transport)
        except ValueError as e:
            raise cli.AbortError(str(e)) from e
        basename = prov["token_basename"]
        helpers.write_provider_def(args.providers_dir, name, prov)
        where = f"new provider def {name}.json"

    helpers.store_secret(args.kib_dir, basename, helpers.recover_secret(authval, scheme))

    # Strip the inline entry so the secret leaves the project. The existing mode is preserved:
    # `.mcp.json` is a PROJECT file, often committed, so silently tightening it to 0600 would
    # surprise — unlike the session `.claude.json`, which is kib's own.
    del servers[name]
    data["mcpServers"] = servers
    jsonio.write_atomic(path, data, mode=stat.S_IMODE(os.stat(path).st_mode))

    sys.stderr.write(
        f"🔐 adopted '{name}' via {where}; stored the credential host-side as {basename} "
        f"and removed the inline entry from {os.path.basename(path)}.\n"
    )
    return cli.OK


# ── add: declare a brokered MCP directly ─────────────────────────────────────────
def add(args: argparse.Namespace) -> int:
    """Write a provider def for a remote (header-brokered) or hosted (local) MCP."""
    bad = helpers.validate_route_id(args.name, registry.BUILTIN_IDS)
    if bad:
        raise cli.AbortError(bad, cli.REFUSED)
    dest = os.path.join(args.providers_dir, f"{args.name}.json")
    if os.path.exists(dest) and not args.force:
        raise cli.AbortError(
            f"a route named {args.name!r} already exists ({dest}). Re-run with --force to "
            "replace it, or pick another name.",
            cli.REFUSED,
        )
    extra_env: dict[str, str] = {}
    for item in args.env:
        k, sep, v = item.partition("=")
        if not sep or not k.strip():
            raise cli.AbortError(f"--env expects KEY=VAL, got {item!r}", cli.USAGE)
        extra_env[k.strip()] = v

    if args.url and args.run:
        raise cli.AbortError("give --url (remote MCP) OR --run (hosted MCP), not both.", cli.USAGE)
    if args.url and extra_env:
        raise cli.AbortError(
            "--env only applies to a hosted MCP (--run); a reverse-proxy route has no "
            "server to set env on.",
            cli.USAGE,
        )

    if args.url:
        hdrname, scheme = "Authorization", "Bearer"
        if args.header:
            hdrname, _, sc = args.header.partition(":")
            hdrname, scheme = hdrname.strip(), sc.strip()
        try:
            prov = helpers.synthesize_reverse_proxy(args.name, args.url, hdrname, scheme)
        except ValueError as e:
            raise cli.AbortError("--url must be an http(s) URL", cli.USAGE) from e
    elif args.run:
        if not args.cred_env:
            raise cli.AbortError(
                "--run needs --cred-env <ENV> (the env var the server reads its credential from)",
                cli.USAGE,
            )
        base = f"{args.name}.json" if args.cred_kind == "file" else f"{args.name}-token"
        prov = {
            "id": args.name,
            "delivery": "hosted_mcp",
            "credential_kind": "file_path" if args.cred_kind == "file" else "paste_token",
            "token_basename": base,
            "host_run": args.run.split(),
            "credential_env": args.cred_env,
            "mcp_path": "/mcp",
            "mcp_transport": "http",
            "mcp_server_name": args.name,
            "extra_env": extra_env,
        }
    else:
        raise cli.AbortError(
            "give --url <url> (remote MCP) or --run <cmd> --cred-env <ENV> (hosted MCP)",
            cli.USAGE,
        )

    helpers.write_provider_def(args.providers_dir, args.name, prov)
    sys.stderr.write(
        f"🔐 wrote provider def {args.name}.json ({prov['delivery']}).\n"
        f"   Now add its credential:  kib broker login {args.name}\n"
    )
    return cli.OK


# ── intercept: the front-line preventer for a pasted vendor command ──────────────
# Users don't learn kib's flags; they take a service's `claude mcp add … --header "…"` line and
# swap `claude` → `kib`. Verbatim, that puts the raw secret in the container's argv and then in
# `.claude.json`. Nothing INSIDE the box can fix it, so it is caught here.
_ADD_FLAGS = (("--header", "headers"), ("-H", "headers"), ("--env", "envs"), ("-e", "envs"))


def _parse_add_json(rest: list[str]) -> dict[str, Any]:
    """`mcp add-json <name> '<blob>'` — the JSON form carries the same fields as flags."""
    positionals = [t for t in rest if not t.startswith("-")]
    spec: dict[str, Any] = {}
    if len(positionals) >= 2:
        try:
            spec = json.loads(positionals[1])
        except ValueError:
            return {}  # malformed → let claude handle it
    return {
        "headers": [f"{k}: {v}" for k, v in (spec.get("headers") or {}).items()],
        "envs": [f"{k}={v}" for k, v in (spec.get("env") or {}).items()],
        "url": spec.get("url", ""),
        "name": positionals[0] if positionals else None,
        "transport": spec.get("type", ""),
    }


def _parse_add_flags(rest: list[str]) -> dict[str, Any]:
    """Parse the `claude mcp add` grammar tolerantly: we only need the auth-bearing parts."""
    buckets: dict[str, list[str]] = {"headers": [], "envs": []}
    positionals: list[str] = []
    transport = ""
    i, seen_ddash = 0, False
    while i < len(rest):
        t = rest[i]
        if seen_ddash:
            i += 1
            continue  # tokens after `--` are the stdio command
        if t == "--":
            seen_ddash = True
            i += 1
            continue
        for flag, bucket in _ADD_FLAGS:
            if t == flag and i + 1 < len(rest):
                buckets[bucket].append(rest[i + 1])
                i += 2
                break
            if t.startswith(flag + "="):
                buckets[bucket].append(t.split("=", 1)[1])
                i += 1
                break
        else:
            if t in ("--transport", "-t") and i + 1 < len(rest):
                transport = rest[i + 1]
                i += 2
                continue
            if t.startswith("--transport="):
                transport = t.split("=", 1)[1]
                i += 1
                continue
            if t in ("--scope", "-s") and i + 1 < len(rest):
                i += 2  # ignore the scope value
                continue
            if t.startswith("-"):
                i += 1  # unknown flag
                continue
            positionals.append(t)
            i += 1
    return {
        "headers": buckets["headers"],
        "envs": buckets["envs"],
        "name": positionals[0] if positionals else None,
        "url": positionals[1] if len(positionals) > 1 else "",
        "transport": transport,
    }


def intercept(args: argparse.Namespace) -> int:
    """Classify a `claude mcp add|add-json` invocation and act before it reaches the box.

    Prints exactly one token on stdout — `brokered`, `blocked` or `passthrough` — which the
    launcher maps onto its own exit status. Explanations go to stderr.
    """
    argv = args.argv
    # argparse.REMAINDER keeps the `--` the caller uses to fence off the agent's own flags.
    if argv and argv[0] == "--":
        argv = argv[1:]
    # Drop leading `claude` token(s): one is injected by the `cc` = `kib claude` alias, a
    # second appears only if the user also typed it. Strip in a loop so that habit cannot
    # slip an inline secret past the gate.
    while argv and argv[0] == "claude":
        argv = argv[1:]
    if len(argv) < 2 or argv[0] != "mcp" or argv[1] not in ("add", "add-json"):
        print("passthrough")
        return cli.OK

    rest = argv[2:]
    parsed = _parse_add_json(rest) if argv[1] == "add-json" else _parse_add_flags(rest)
    if not parsed:
        print("passthrough")
        return cli.OK

    name, url = parsed["name"], parsed["url"]
    secret_env = [e for e in parsed["envs"] if helpers.env_is_secret(e)]
    is_remote = bool(re.match(r"https?://", url))
    hname, hval = helpers.find_auth_header(parsed["headers"])
    w = sys.stderr.write

    # Remote + auth header → AUTO-BROKER (the secret never enters the box).
    if is_remote and hval and name and not helpers.validate_route_id(name, registry.BUILTIN_IDS):
        scheme = helpers.scheme_of(hval)
        secret = helpers.recover_secret(hval, scheme)
        if secret:
            try:
                prov = helpers.synthesize_reverse_proxy(
                    name, url, hname or "", scheme, parsed["transport"]
                )
            except ValueError:
                prov = None
            if prov is not None:
                helpers.write_provider_def(args.providers_dir, name, prov)
                dest = helpers.store_secret(args.kib_dir, f"{name}-token", secret)
                w(
                    "🔐 Intercepted an inline MCP credential and brokered it host-side — "
                    "it never entered the sandbox.\n"
                )
                w(
                    f"   • '{name}' → {prov['upstream_origin']}{prov['mcp_path']} "
                    f"(reverse-proxy route {registry.MCP_PREFIX}/{name})\n"
                )
                w(f"   • credential stored host-only: {os.path.basename(dest)} (mode 600)\n")
                w(f"   • provider def: providers.d/{name}.json\n")
                if args.broker_on:
                    w(
                        "   Start a session with `kib` — the agent gets a header-free broker "
                        "URL, not the token.\n"
                    )
                else:
                    w("   ⚠️  The broker is OFF, so this route isn't active yet. Enable it:\n")
                    w("        echo 'broker = on' >> ~/.keep-it-in-your-box/config\n")
                print("brokered")
                return cli.OK

    # Local/stdio server with a secret in --env → BLOCK (it cannot be header-brokered).
    if secret_env and not args.allow:
        nm = name or "<name>"
        w("❌ kib won't carry an inline MCP secret into the sandbox.\n")
        w(
            f"   '{nm}' passes its credential to a LOCAL server via --env, which kib can't "
            "broker: the server\n"
        )
        w("   runs its own code and reads the secret as an env value (and multi-value creds\n")
        w("   like USERNAME+PASSWORD aren't supported yet). Instead:\n")
        w("     • If the service has a remote endpoint, use --header — kib auto-brokers it:\n")
        w(
            '         kib claude mcp add --header "Authorization: Bearer <token>" '
            f"--transport http {nm} <url>\n"
        )
        w("     • Or a single-value hosted server:\n")
        w(f'         kib broker add {nm} --run "<cmd>" --cred-env <ENV>\n')
        w("     • To knowingly accept the secret INSIDE the sandbox, re-run with:\n")
        w("         KIB_ALLOW_INLINE_MCP_SECRET=1 kib claude mcp add …\n")
        print("blocked")
        return cli.OK

    # An auth header we could NOT auto-broker (no remote http(s) URL, no name, or a stdio
    # target) would still ride into the container's argv on passthrough — the exact leak
    # this interceptor exists to prevent. BLOCK it too.
    if hval and not args.allow:
        nm = name or "<name>"
        w("❌ kib won't carry an inline MCP auth header into the sandbox.\n")
        w(
            f"   '{nm}' has an auth header kib couldn't broker — that needs a remote http(s) "
            "URL and a name:\n"
        )
        w(
            '     kib claude mcp add --header "Authorization: Bearer <token>" --transport http '
            f"{nm} <https-url>\n"
        )
        w("   To knowingly accept the secret INSIDE the sandbox, re-run with:\n")
        w("     KIB_ALLOW_INLINE_MCP_SECRET=1 kib claude mcp add …\n")
        print("blocked")
        return cli.OK

    print("passthrough")  # no secret to protect
    return cli.OK


def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="kib mcp", description="MCP brokering, host-side")
    sub = ap.add_subparsers(dest="verb", required=True)

    p = sub.add_parser("inject", help="write brokered routes into the session .claude.json")
    p.add_argument("--config", required=True)
    p.add_argument("--kib-dir", required=True)
    p.add_argument("--broker-host", required=True)
    p.add_argument("--hosted-up", default="", help="space-separated ids whose sidecar came up")
    p.set_defaults(fn=inject)

    p = sub.add_parser("warn", help="flag MCP entries carrying a readable inline credential")
    p.add_argument("--claude-json", required=True)
    p.add_argument("--mcp-json", default="")
    p.set_defaults(fn=warn)

    p = sub.add_parser("adopt", help="migrate an inline-credential MCP into the broker")
    p.add_argument("name")
    p.add_argument("--kib-dir", required=True)
    p.add_argument("--providers-dir", required=True)
    p.add_argument("--claude-json", required=True)
    p.add_argument("--mcp-json", default="")
    p.set_defaults(fn=adopt)

    p = sub.add_parser("add", help="declare a brokered MCP directly")
    p.add_argument("name")
    p.add_argument("--providers-dir", required=True)
    p.add_argument("--url", default="", help="remote MCP endpoint (header-brokered)")
    p.add_argument("--header", default="", help='"Header-Name: Scheme" (Bearer|Basic|"")')
    p.add_argument("--run", default="", help="hosted MCP: the stdio command to run")
    p.add_argument("--cred-env", default="", help="hosted MCP: env var holding the credential")
    p.add_argument("--cred-kind", default="token", choices=("token", "file"))
    p.add_argument("--force", action="store_true", help="replace an existing route of this name")
    p.add_argument("--env", action="append", default=[], metavar="KEY=VAL")
    p.set_defaults(fn=add)

    p = sub.add_parser("intercept", help="classify a pasted `claude mcp add` before it runs")
    p.add_argument("--kib-dir", required=True)
    p.add_argument("--providers-dir", required=True)
    p.add_argument("--allow", action="store_true", help="knowingly carry the secret into the box")
    p.add_argument("--broker-on", action="store_true")
    p.add_argument("argv", nargs=argparse.REMAINDER)
    p.set_defaults(fn=intercept)
    return ap


def main(argv: list[str]) -> int:
    registry.merge_user_providers()
    args = _build_parser().parse_args(argv)
    result: int = args.fn(args)
    return result


if __name__ == "__main__":
    cli.run(main)
