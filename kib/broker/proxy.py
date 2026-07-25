"""Guest — the fixed-upstream reverse proxy and the sidecar's serve loop.

Terminates the agent's plain-HTTP connection, strips the placeholder auth, injects the
REAL credential and re-originates its own TLS to ONE hardcoded upstream per route. No TLS
MITM, no CA in the agent's trust store: the credential is injected, not decrypted.
"""

import http.client
import json
import os
import ssl
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from kib.broker.credential import Credential, mint_placeholder
from kib.broker.registry import PROVIDERS, provider_id_of
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


def make_handler(provider: dict[str, Any], cred: Credential) -> type[BaseHTTPRequestHandler]:
    """A request handler bound to one route's upstream and credential."""
    origin = urllib.parse.urlsplit(provider["upstream_origin"])
    up_host = origin.hostname
    up_port = origin.port or (443 if origin.scheme == "https" else 80)
    strip = set(provider.get("strip_incoming", []))

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        # Silence default logging: it prints the request line only (never headers), but we
        # keep our own single-line breadcrumbs and never want the auth header near a log.
        def log_message(self, *a: Any) -> None:
            pass

        def _relay(self) -> None:
            try:
                self._do_relay()
            except (BrokenPipeError, ConnectionResetError) as e:
                # A peer went away mid-relay: the agent cancelled a turn, a subagent
                # finished, or the upstream idle-closed a stream. Expected and NOT
                # actionable — so never fire the notifier with it (BROKER-ERR pages the
                # user; a benign transient reset must not cry wolf). Leave a non-matching
                # breadcrumb for log spelunking.
                stdout_line(f"BROKER-PEER-GONE {provider_id_of(provider)} {e}")
            except Exception as e:  # noqa: BLE001
                # Exception TYPE only, never str(e): a failure raised while handling
                # credential bytes must not put those bytes into a log the notifier tails.
                stdout_line(
                    f"BROKER-ERR {provider_id_of(provider)} relay failed: {type(e).__name__}"
                )
                try:
                    self.send_error(502, "broker upstream error")
                except Exception:  # noqa: BLE001
                    pass

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

        def _do_relay(self) -> None:
            body = self._read_body()

            # Rebuild headers: drop hop-by-hop + the agent's placeholder auth, then inject
            # the real credential.
            out_headers: dict[str, str] = {}
            for k, v in self.headers.items():
                lk = k.lower()
                if lk in HOP_BY_HOP or lk in strip:
                    continue
                out_headers[k] = v
            secret = cred.current_secret()
            if secret is None:
                # No usable token → fail loudly instead of sending the literal header
                # "Bearer None" upstream and getting an opaque 401 the agent cannot
                # diagnose. current_secret() already logged the specific cause.
                self.send_error(502, "broker credential unavailable")
                return
            out_headers[provider["inject_header"]] = provider["inject_template"].format(
                secret=secret
            )
            # Host is intentionally NOT set: it is in HOP_BY_HOP, so the agent's
            # "Host: kib-broker:8080" was already dropped, and http.client re-generates the
            # correct upstream Host (with :port only when non-default) from the connection.

            ctx = ssl.create_default_context() if origin.scheme == "https" else None
            conn = (
                http.client.HTTPSConnection(up_host, up_port, context=ctx, timeout=600)
                if origin.scheme == "https"
                else http.client.HTTPConnection(up_host, up_port, timeout=600)
            )
            conn.request(self.command, self.path, body=body, headers=out_headers)
            resp = conn.getresponse()

            # Stream the response back UNBUFFERED. Connection: close + read-to-EOF is the
            # simplest correct path for SSE / streamable-HTTP: the agent reads events as
            # they arrive and the socket closes when upstream is done. No re-chunking, no
            # Content-Length juggling.
            self.send_response_only(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in HOP_BY_HOP:
                    continue
                self.send_header(k, v)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
            self.close_connection = True
            conn.close()

        # Names mandated by BaseHTTPRequestHandler's dispatch (do_<METHOD>) — not ours to case.
        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _relay  # noqa: N815

    return Handler


def serve(config_path: str) -> None:
    """Bring up one listener per enabled route, then idle. PID 1 of the broker sidecar."""
    with open(config_path) as fh:
        cfg = json.load(fh)
    out_dir = cfg.get("out_dir", "/run/broker/out")
    os.makedirs(out_dir, exist_ok=True)

    servers: list[ThreadingHTTPServer] = []
    for pid in cfg.get("enabled", []):
        provider = PROVIDERS.get(pid)
        if provider is None:
            stdout_line(f"BROKER-SKIP unknown provider {pid}")
            continue
        # hosted_mcp routes run the MCP server in their OWN sidecar and hold the credential
        # there; the broker never proxies them. Guard even though the host keeps them out
        # of `enabled` — a stray row must not KeyError on the reverse-proxy fields.
        if provider.get("delivery") == "hosted_mcp":
            stdout_line(f"BROKER-SKIP {pid}: hosted_mcp is served by its own sidecar")
            continue
        token_path = cfg.get("token_paths", {}).get(pid)
        if not token_path or not os.path.exists(token_path):
            stdout_line(f"BROKER-SKIP {pid}: no token at {token_path}")
            continue

        cred = Credential(pid, provider, token_path)
        if cred.current_secret() is None:
            stdout_line(f"BROKER-FATAL {pid}: token file present but unusable")
            continue

        # Mint the placeholder credential file the agent will get, into the shared out dir
        # the host reads. Synthetic — no real credential is opened here or anywhere else.
        try:
            mint_placeholder(os.path.join(out_dir, f"{pid}.cred.json"), provider)
        except OSError as e:
            stdout_line(f"BROKER-FATAL {pid}: cannot mint placeholder: {e.strerror}")
            continue

        port = provider["listen_port"]
        httpd = ThreadingHTTPServer(("0.0.0.0", port), make_handler(provider, cred))
        httpd.daemon_threads = True
        servers.append(httpd)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        stdout_line(f"BROKER-UP {pid} :{port} -> {provider['upstream_origin']}")

    if not servers:
        stdout_line("BROKER-FATAL no routes came up")
        raise SystemExit(1)

    # Signal readiness LAST — only after every placeholder is minted and every port is
    # bound. The host polls this file before mounting the placeholder into the agent.
    with open(os.path.join(out_dir, "ready"), "w") as fh:
        fh.write("ok\n")
    stdout_line(f"BROKER-READY {len(servers)} route(s)")

    while True:
        time.sleep(3600)
