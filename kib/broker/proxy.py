"""Guest — the fixed-upstream reverse proxy and the sidecar's serve loop.

Terminates the agent's plain-HTTP connection, strips the placeholder auth, injects the
REAL credential and re-originates its own TLS to ONE hardcoded upstream per route. No TLS
MITM, no CA in the agent's trust store: the credential is injected, not decrypted.

Two listener shapes, one relay. Each LLM row keeps a dedicated port and forwards the path
verbatim. Every user MCP route shares ONE listener on `MCP_PORT`, picked by a `/mcp/<id>`
prefix that is stripped before forwarding — so adding a route can never collide with another,
and a route that cannot come up is skipped by name instead of taking the launch down.
"""

from __future__ import annotations

import http.client
import json
import os
import posixpath
import ssl
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from kib.broker.credential import Credential, mint_placeholder
from kib.broker.registry import DEF_PROBLEMS, MCP_PORT, MCP_PREFIX, PROVIDERS
from kib.shared.log import stdout_line

# Hop-by-hop headers are never forwarded (RFC 7230 §6.1); we terminate and re-originate,
# so these are ours to manage, not the peer's.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}

#: Routes whose failure to bind aborts the sidecar. Everything else is skipped and NAMED: a
#: user MCP the agent will simply not see beats no session at all.
FAIL_HARD_ROUTES = ("claude",)


class Route:
    """One resolved target: where it goes, what to strip, what to inject, and with which key.

    The upstream is parsed ONCE here rather than per handler class, which is what lets N
    routes share a listener without re-splitting a URL on every request.
    """

    def __init__(self, pid: str, provider: dict[str, Any], cred: Credential) -> None:
        origin = urllib.parse.urlsplit(provider["upstream_origin"])
        self.pid = pid
        self.provider = provider
        self.cred = cred
        self.origin = provider["upstream_origin"]
        self.scheme = origin.scheme
        self.host = origin.hostname
        self.port = origin.port or (443 if origin.scheme == "https" else 80)
        self.strip = set(provider.get("strip_incoming", []))
        self.inject_header: str = provider["inject_header"]
        self.inject_template: str = provider["inject_template"]
        self.listen_port: int = int(provider.get("listen_port") or MCP_PORT)
        self.allow_paths: tuple[str, ...] = tuple(provider.get("allow_paths") or ())
        # Trailing slash off once, here: `allows` compares segment-wise, so `/v1/` and `/v1`
        # are the same rule and normpath never leaves a trailing slash to match against.
        self._allow_bases: tuple[str, ...] = tuple(p.rstrip("/") or "/" for p in self.allow_paths)

    def allows(self, upstream_path: str) -> bool:
        """True if this is a path the route may reach with the real credential attached.

        The upstream ORIGIN was always pinned, so the box could never redirect the credential
        anywhere — but with no path check it could still drive any authenticated request the
        token permits AT that origin (account reads, key minting). Judged on the path the
        upstream will see, so the mux's `/mcp/<id>` prefix is already off, and on the path
        component only: the query is the caller's, and `?beta=true` must not turn an allowed
        path into a refused one. Empty allowlist = unrestricted, which is what every user MCP
        route gets — see registry._finalize_provider. (audit MAC-L2 / R3)

        Decided on the path the upstream RESOLVES, not the bytes we forward: percent-escapes
        are decoded and `.`/`..` collapsed first, or `/v1/../api/oauth/…/create_api_key` walks
        straight through a `/v1/` prefix and the origin's own RFC 3986 normalisation lands it
        on the endpoint this exists to refuse. Matched on segment boundaries for the same
        reason `/api/oauth/profile` must not also mean `/api/oauth/profileEVIL`.
        """
        if not self.allow_paths:
            return True
        path = posixpath.normpath(urllib.parse.unquote(urllib.parse.urlsplit(upstream_path).path))
        return any(path == p or path.startswith(p + "/") for p in self._allow_bases)


def _do_relay(h: BaseHTTPRequestHandler, route: Route, upstream_path: str, body: bytes) -> None:
    """Rebuild the request against `route` and stream the answer back."""
    # Drop hop-by-hop + the agent's placeholder auth, then inject the real credential.
    out_headers: dict[str, str] = {}
    for k, v in h.headers.items():
        lk = k.lower()
        if lk in HOP_BY_HOP or lk in route.strip:
            continue
        out_headers[k] = v
    secret = route.cred.current_secret()
    if secret is None:
        # No usable token → fail loudly instead of sending the literal header "Bearer None"
        # upstream and getting an opaque 401 the agent cannot diagnose. current_secret()
        # already logged the specific cause.
        h.send_error(502, "broker credential unavailable")
        return
    out_headers[route.inject_header] = route.inject_template.format(secret=secret)
    # Host is intentionally NOT set: it is in HOP_BY_HOP, so the agent's "Host: kib-broker:8100"
    # was already dropped, and http.client re-generates the correct upstream Host from the
    # connection. That is precisely what lets one listener serve N different upstreams — put
    # `host` back in the forwarded set and every route would announce the broker's own name.

    ctx = ssl.create_default_context() if route.scheme == "https" else None
    conn = (
        http.client.HTTPSConnection(route.host, route.port, context=ctx, timeout=600)
        if route.scheme == "https"
        else http.client.HTTPConnection(route.host, route.port, timeout=600)
    )
    conn.request(h.command, upstream_path, body=body, headers=out_headers)
    resp = conn.getresponse()

    # Stream the response back UNBUFFERED. Connection: close + read-to-EOF is the simplest
    # correct path for SSE / streamable-HTTP: the agent reads events as they arrive and the
    # socket closes when upstream is done. No re-chunking, no Content-Length juggling.
    h.send_response_only(resp.status, resp.reason)
    for k, v in resp.getheaders():
        if k.lower() in HOP_BY_HOP:
            continue
        h.send_header(k, v)
    h.send_header("Connection", "close")
    h.end_headers()
    while True:
        chunk = resp.read(65536)
        if not chunk:
            break
        h.wfile.write(chunk)
        h.wfile.flush()
    h.close_connection = True
    conn.close()


class _RelayHandler(BaseHTTPRequestHandler):
    """Everything both listener shapes share; only `_resolve` differs."""

    protocol_version = "HTTP/1.1"

    # Silence default logging: it prints the request line only (never headers), but we keep
    # our own single-line breadcrumbs and never want the auth header near a log.
    def log_message(self, *a: Any) -> None:
        pass

    def _resolve(self) -> tuple[Route, str] | None:
        """`(route, upstream path)`, or None having already answered the client."""
        raise NotImplementedError

    def _read_body(self) -> bytes:
        if self.headers.get("transfer-encoding", "").lower() == "chunked":
            chunks: list[bytes] = []
            while True:
                size_line = self.rfile.readline().strip()
                size = int(size_line.split(b";")[0], 16) if size_line else 0
                if size == 0:
                    self.rfile.readline()  # trailing CRLF
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            return b"".join(chunks)
        length = int(self.headers.get("content-length", 0) or 0)
        return self.rfile.read(length) if length else b""

    def _relay(self) -> None:
        pid = "?"
        try:
            # The body is drained before anything else: an unread request body wedges
            # keep-alive, including on the 404 an unknown prefix takes.
            body = self._read_body()
            resolved = self._resolve()
            if resolved is None:
                return
            route, upstream_path = resolved
            pid = route.pid
            if not route.allows(upstream_path):
                stdout_line(f"BROKER-DENY-PATH {pid} {self.command} {upstream_path}")
                self.send_error(404, "path not brokered")
                return
            _do_relay(self, route, upstream_path, body)
        except (BrokenPipeError, ConnectionResetError) as e:
            # A peer went away mid-relay: the agent cancelled a turn, a subagent finished, or
            # the upstream idle-closed a stream. Expected and NOT actionable — so never fire
            # the notifier with it (BROKER-ERR pages the user; a benign transient reset must
            # not cry wolf). Leave a non-matching breadcrumb for log spelunking.
            stdout_line(f"BROKER-PEER-GONE {pid} {e}")
        except Exception as e:  # noqa: BLE001
            # Exception TYPE only, never str(e): a failure raised while handling credential
            # bytes must not put those bytes into a log the notifier tails.
            stdout_line(f"BROKER-ERR {pid} relay failed: {type(e).__name__}")
            try:
                self.send_error(502, "broker upstream error")
            except Exception:  # noqa: BLE001
                pass

    # Names mandated by BaseHTTPRequestHandler's dispatch (do_<METHOD>) — not ours to case.
    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _relay  # noqa: N815


def make_handler(route: Route) -> type[BaseHTTPRequestHandler]:
    """A dedicated listener for ONE route, forwarding the path verbatim (the LLM shape)."""

    class Handler(_RelayHandler):
        def _resolve(self) -> tuple[Route, str] | None:
            return route, self.path

    return Handler


def split_route(path: str, routes: dict[str, Route]) -> tuple[Route, str] | None:
    """`/mcp/<id><rest>[?q]` → the route and the upstream path with the prefix stripped."""
    head, sep, query = path.partition("?")
    if not head.startswith(MCP_PREFIX + "/"):
        return None
    pid, _, tail = head[len(MCP_PREFIX) + 1 :].partition("/")
    route = routes.get(pid)
    if route is None:
        return None
    return route, "/" + tail + sep + query


def make_mux_handler(routes: dict[str, Route]) -> type[BaseHTTPRequestHandler]:
    """The shared MCP listener: pick the route by its `/mcp/<id>` prefix, then strip it."""

    class Handler(_RelayHandler):
        def _resolve(self) -> tuple[Route, str] | None:
            hit = split_route(self.path, routes)
            if hit is None:
                # Names no other route: an agent that guessed a prefix learns nothing about
                # which brokered services exist.
                self.send_error(404, "no such broker route")
                return None
            return hit

    return Handler


def _bind(
    port: int, handler: type[BaseHTTPRequestHandler], label: str
) -> ThreadingHTTPServer | None:
    """Bind and start serving, or breadcrumb why not. The caller decides how fatal that is.

    Every bind goes through here. An unguarded one is what turned a single duplicated port
    into a dead sidecar, a skipped `ready` file and an aborted launch.
    """
    try:
        httpd = ThreadingHTTPServer(("0.0.0.0", port), handler)
    except OSError as e:
        stdout_line(f"BROKER-ERR {label}: cannot listen on :{port} ({e.strerror})")
        return None
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def _build_routes(
    cfg: dict[str, Any], out_dir: str
) -> tuple[list[Route], dict[str, Route], list[tuple[str, str]]]:
    """Resolve the enabled ids into `(LLM routes, muxed MCP routes, [(id, reason) skipped])`.

    Separate from serve() so the fail-soft split is testable without binding a real port.
    """
    llm: list[Route] = []
    mux: dict[str, Route] = {}
    broken: list[tuple[str, str]] = []
    for pid in cfg.get("enabled", []):
        provider = PROVIDERS.get(pid)
        if provider is None:
            broken.append((pid, "no such route in the registry"))
            continue
        # hosted_mcp routes run the MCP server in their OWN sidecar and hold the credential
        # there; the broker never proxies them. Guard even though the host keeps them out of
        # `enabled` — a stray row must not KeyError on the reverse-proxy fields.
        if provider.get("delivery") == "hosted_mcp":
            stdout_line(f"BROKER-SKIP {pid}: hosted_mcp is served by its own sidecar")
            continue
        token_path = cfg.get("token_paths", {}).get(pid)
        if not token_path or not os.path.exists(token_path):
            broken.append((pid, "its credential is missing"))
            continue

        cred = Credential(pid, provider, token_path)
        if cred.current_secret() is None:
            broken.append((pid, "its credential file is present but unusable"))
            continue

        # Mint the placeholder credential file the agent will get, into the shared out dir
        # the host reads. Synthetic — no real credential is opened here or anywhere else.
        try:
            mint_placeholder(os.path.join(out_dir, f"{pid}.cred.json"), provider)
        except OSError as e:
            broken.append((pid, f"its placeholder could not be minted ({e.strerror})"))
            continue

        route = Route(pid, provider, cred)
        if provider.get("delivery") == "reverse_proxy_mcp":
            mux[pid] = route
        else:
            llm.append(route)
    return llm, mux, broken


def _write_broken(out_dir: str, broken: list[tuple[str, str]]) -> None:
    """`<id> <reason>` per line, so the host can name what did not come up.

    Written BEFORE `ready`: the host only reads it after seeing `ready`, so the order is what
    makes the report complete rather than racy.
    """
    with open(os.path.join(out_dir, "broken"), "w") as fh:
        for pid, reason in broken:
            fh.write(f"{pid} {reason}\n")


def serve(config_path: str) -> None:
    """Bring up the LLM listeners plus the shared MCP one, then idle. PID 1 of the sidecar."""
    with open(config_path) as fh:
        cfg = json.load(fh)
    out_dir = cfg.get("out_dir", "/run/broker/out")
    os.makedirs(out_dir, exist_ok=True)

    # A def the registry refused never reaches `enabled`, so say why here too — this log is
    # the only view of it from inside the sidecar.
    for problem in DEF_PROBLEMS:
        stdout_line(f"BROKER-BADDEF providers.d/{problem}")

    llm, mux, broken = _build_routes(cfg, out_dir)
    servers: list[ThreadingHTTPServer] = []

    for route in llm:
        httpd = _bind(route.listen_port, make_handler(route), route.pid)
        if httpd is None:
            broken.append((route.pid, f"port {route.listen_port} is already in use"))
            continue
        servers.append(httpd)
        stdout_line(f"BROKER-UP {route.pid} :{route.listen_port} -> {route.origin}")

    if mux:
        httpd = _bind(MCP_PORT, make_mux_handler(mux), "mcp-mux")
        if httpd is None:
            broken += [(pid, f"the shared MCP port {MCP_PORT} is in use") for pid in mux]
        else:
            servers.append(httpd)
            stdout_line(f"BROKER-UP mcp-mux :{MCP_PORT} ({len(mux)} route(s))")
            for pid, route in mux.items():
                # One breadcrumb per route even though they share a socket, so a log grep for
                # a route id still finds it.
                stdout_line(f"BROKER-UP {pid} {MCP_PREFIX}/{pid} -> {route.origin}")

    fatal = [f"{pid}: {why}" for pid, why in broken if pid in FAIL_HARD_ROUTES]
    if fatal or not servers:
        for line in fatal or ["no routes came up"]:
            stdout_line(f"BROKER-FATAL {line}")
        raise SystemExit(1)

    _write_broken(out_dir, broken)
    for pid, why in broken:
        stdout_line(f"BROKER-SKIP {pid}: {why}")

    # Signal readiness LAST — only after every placeholder is minted and every port is bound.
    # The host polls this file before mounting the placeholder into the agent.
    with open(os.path.join(out_dir, "ready"), "w") as fh:
        fh.write("ok\n")
    stdout_line(f"BROKER-READY {len(servers)} listener(s), {len(broken)} skipped")

    while True:
        time.sleep(3600)
