#!/usr/bin/env python3
"""cc-broker — host-side credential broker for the keep-it-in-your-box sandbox.

The agent container never holds a real credential. It gets only:
  • a base-URL env var (e.g. ANTHROPIC_BASE_URL) pointed at this broker,
  • a structurally-valid *placeholder* token in the agent's auth env var, and
  • a synthetic placeholder .credentials.json shadowing the real one.

This broker is a **fixed-upstream reverse proxy**: it terminates the agent's plain-HTTP
connection, strips the placeholder auth, injects the REAL credential, and re-originates
its own TLS to ONE hardcoded upstream per route. So there is no TLS MITM and no CA in
the agent's trust store (the credential is injected, not decrypted). A fully compromised
agent can *use* the upstream through the broker but cannot read the token — the win holds
even with egress wide open (docs/FUTURE_TASKS.md G1 / audit H3/H4).

The upstream is fixed per listening port and never chosen by the agent — a forward proxy
would be an egress bypass. Routes are table-valued (PROVIDERS): Claude is wired now;
Codex/Gemini are ready-but-unstarted rows enabled by dropping a host token file.

── THE SECRET IS STATIC. THE BROKER NEVER WRITES IT. ─────────────────────────
Read this before adding a refresh loop back. An earlier version brokered the live
~/.claude-shared/.credentials.json and refreshed it on a 30s timer. That logged the
account out, hard:

  • Anthropic subscription refresh tokens are SINGLE-USE and ROTATE on every refresh.
    The first client to refresh invalidates the token family for every other holder —
    host `claude`, a second project's broker sidecar, any third-party reader.
  • Writing the rotated token back to a *single-file* bind mount cannot use
    temp+rename (EBUSY), so it truncated in place; a lost or torn write kills the
    family permanently.
  • threading.Lock only serialises within ONE process. One broker container per project
    means N unsynchronised refreshers on one host file.

This is a known upstream Claude Code failure mode (anthropics/claude-code #56339, #54443,
#60503), not something clever code can work around. yoloAI — the one peer sandbox shipping
a broker by default — refuses to broker .credentials.json for exactly this reason.

So: the broker's secret is a **long-lived static token in a plain-text file, mounted
READ-ONLY**, produced by `claude setup-token` (Pro/Max) or a console API key. There is no
refresh loop, no expiry tracking, and no write path to any credential. `cc --broker-login`
mints one; `cc --broker-logout` removes it.

Stdlib only — runs off the image's python3, no pip. Started as a sidecar by cc-lib.sh's
start_broker(); see docs/FUTURE_TASKS.md and CLAUDE.md "Credential broker".

Modes:
  --serve --config <f>          run the proxy (PID 1 of the broker sidecar)
  --host-config <id>            emit shell KEY=VALUE facts for cc (single source of truth)
  --make-placeholder <out> <id> mint the synthetic placeholder credential file
  --placeholder-token <id>      print a fresh placeholder token (never a real one)
  --probe <tokenfile> <id>      host-side liveness check: is this token accepted upstream?
"""

import argparse
import http.client
import json
import os
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# A far-future expiry (ms) baked into the placeholder credential so in-sandbox claude
# regards its token as valid and never tries to refresh or /login — it just sends the
# placeholder to the broker, which swaps in the real token. 2286-11-20 in ms.
FAR_FUTURE_MS = 10_000_000_000_000
FAKE_PREFIX = "fake_value_"          # sandbox-runtime's sentinel shape


def _fake(prefix=""):
    """A structurally-plausible but obviously-fake token. os.urandom keeps uuid off the
    import list; the FAKE_PREFIX makes it greppable in a log or a leaked transcript."""
    return prefix + FAKE_PREFIX + os.urandom(16).hex()


# ── Provider/route table — the single source of truth ────────────────────────
# One row per route. `cc` reads the host-facing fields via `--host-config <id>` so the
# bash side never duplicates this table. FIXED upstream per row (never agent-chosen).
#
# `token_basename` names the HOST file (under ~/.keep-it-in-your-box/) holding a static,
# long-lived credential. It is mounted READ-ONLY into the broker and nowhere else.
PROVIDERS = {
    "claude": {
        "delivery": "base_url_env",
        "agent_base_url_env": "ANTHROPIC_BASE_URL",
        # The agent's auth env var, set to a PLACEHOLDER. CLAUDE_CODE_OAUTH_TOKEN takes
        # precedence over .credentials.json, so the agent authenticates through the broker
        # even though the shadowed credential file is also synthetic.
        "agent_token_env": "CLAUDE_CODE_OAUTH_TOKEN",
        "token_prefix": "sk-ant-oat01-",
        "listen_port": 8080,
        "upstream_origin": "https://api.anthropic.com",
        "token_basename": "claude-token",
        # header to inject upstream, and what to strip from the agent's request first.
        "inject_header": "Authorization",
        "inject_template": "Bearer {secret}",
        "strip_incoming": ["authorization", "x-api-key"],
        # Synthetic placeholder shadowing the real credential file in the container. Built
        # from this template — the broker NEVER reads the user's real .credentials.json.
        "placeholder_container_path": "/home/hostuser/.claude-shared/.credentials.json",
        "placeholder_template": {
            "claudeAiOauth": {
                "accessToken": None,          # filled with a fake at mint time
                "refreshToken": None,
                "expiresAt": FAR_FUTURE_MS,
                "refreshTokenExpiresAt": FAR_FUTURE_MS,
                "scopes": ["user:inference", "user:profile"],
                "subscriptionType": "max",
            }
        },
        "placeholder_fake_pointers": [
            "/claudeAiOauth/accessToken",
            "/claudeAiOauth/refreshToken",
        ],
        # Host-side probe: the smallest request that proves the token is accepted.
        "probe": {
            "path": "/v1/messages",
            "headers": {
                "anthropic-version": "2023-06-01",
                "anthropic-beta": "oauth-2025-04-20",
                "content-type": "application/json",
            },
            "body": {
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 1,
                "system": [{"type": "text",
                            "text": "You are Claude Code, Anthropic's official CLI for Claude."}],
                "messages": [{"role": "user", "content": "hi"}],
            },
        },
    },

    # ── ready-but-unstarted (enable by dropping a host token file; no code change) ──
    # Same contract: a STATIC key. For Codex/Gemini that means an api-key, not the
    # ChatGPT/Google OAuth credential — those rotate exactly like Anthropic's.
    "codex": {
        "delivery": "base_url_env",
        "agent_base_url_env": "OPENAI_BASE_URL",
        "agent_token_env": "OPENAI_API_KEY",
        "token_prefix": "sk-",
        "listen_port": 8081,
        "upstream_origin": "https://api.openai.com",
        "token_basename": "openai-token",
        "inject_header": "Authorization",
        "inject_template": "Bearer {secret}",
        "strip_incoming": ["authorization"],
        "placeholder_container_path": "",
        "placeholder_template": None,
        "placeholder_fake_pointers": [],
        "probe": {"path": "/v1/models", "method": "GET", "headers": {}, "body": None},
    },
    "gemini": {
        "delivery": "base_url_env",
        "agent_base_url_env": "GOOGLE_GEMINI_BASE_URL",
        "agent_token_env": "GEMINI_API_KEY",
        "token_prefix": "",
        "listen_port": 8082,
        "upstream_origin": "https://generativelanguage.googleapis.com",
        "token_basename": "gemini-token",
        "inject_header": "x-goog-api-key",
        "inject_template": "{secret}",
        "strip_incoming": ["authorization", "x-goog-api-key"],
        "placeholder_container_path": "",
        "placeholder_template": None,
        "placeholder_fake_pointers": [],
        "probe": {"path": "/v1beta/models", "method": "GET", "headers": {}, "body": None},
    },
}

# Hop-by-hop headers never forwarded (RFC 7230 §6.1); we terminate + re-originate, so these
# are ours to manage, not the peer's.
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
}


# ── JSON pointer (RFC 6901, minimal) ─────────────────────────────────────────
def _ptr_parts(pointer):
    return [p.replace("~1", "/").replace("~0", "~") for p in pointer.strip("/").split("/")]


def json_set(obj, pointer, value):
    parts = _ptr_parts(pointer)
    cur = obj
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    cur[parts[-1]] = value


# ── Placeholder minting (synthetic — reads no real credential) ───────────────
def mint_placeholder(out_path, provider):
    """Write the fake credential file that SHADOWS the real one inside the container.

    Built from `placeholder_template`, never cloned from the user's real credential: the
    broker has no access to it and must not acquire any. Non-secret fields are plausible
    constants so Claude parses the file exactly as it would the real thing."""
    template = provider.get("placeholder_template")
    if template is None:
        return False
    data = json.loads(json.dumps(template))       # deep copy
    for ptr in provider.get("placeholder_fake_pointers", []):
        json_set(data, ptr, _fake())
    tmp = out_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh)
    os.chmod(tmp, 0o600)      # fake tokens only, but claude warns on a world-readable cred
    os.replace(tmp, out_path)
    return True


# ── Credential access ────────────────────────────────────────────────────────
class Credential:
    """Read-only view of one route's static token.

    Cached in memory and re-read only when the file's mtime/size changes, so a host-side
    `cc --broker-login` mid-session is picked up without a restart. There is deliberately
    NO write path: see the module docstring."""

    def __init__(self, pid, provider, token_path):
        self.pid = pid
        self.provider = provider
        self.path = token_path
        self.lock = threading.Lock()
        self._stamp = None
        self._value = None

    def current_secret(self):
        try:
            st = os.stat(self.path)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError as e:
            log("BROKER-ERR %s token file unreadable: %s" % (self.pid, e.strerror))
            return None
        with self.lock:
            if stamp != self._stamp:
                try:
                    with open(self.path) as fh:
                        value = fh.read().strip()
                except OSError as e:
                    log("BROKER-ERR %s token file unreadable: %s" % (self.pid, e.strerror))
                    return None
                if not value:
                    log("BROKER-ERR %s token file is empty" % self.pid)
                    return None
                self._value, self._stamp = value, stamp
            return self._value


# ── Reverse proxy ────────────────────────────────────────────────────────────
def make_handler(provider, cred):
    origin = urllib.parse.urlsplit(provider["upstream_origin"])
    up_host = origin.hostname
    up_port = origin.port or (443 if origin.scheme == "https" else 80)
    strip = set(provider.get("strip_incoming", []))

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        # Silence default logging: it prints the request line only (never headers), but we
        # keep our own single-line breadcrumbs and never want the auth header near a log.
        def log_message(self, *a):
            pass

        def _relay(self):
            try:
                self._do_relay()
            except (BrokenPipeError, ConnectionResetError) as e:
                # A peer went away mid-relay: the agent cancelled a turn, a subagent finished,
                # or the upstream idle-closed a stream. Expected and NOT actionable — so never
                # fire the notifier with it (BROKER-ERR pages the user; a benign transient
                # reset must not cry wolf). Leave a non-matching breadcrumb for log spelunking.
                log("BROKER-PEER-GONE %s %s" % (provider_id_of(provider), e))
            except Exception as e:        # noqa: BLE001
                # Exception TYPE only, never str(e): a failure raised while handling
                # credential bytes must not put those bytes into a log the notifier tails.
                log("BROKER-ERR %s relay failed: %s" % (provider_id_of(provider),
                                                        type(e).__name__))
                try:
                    self.send_error(502, "broker upstream error")
                except Exception:         # noqa: BLE001
                    pass

        def _read_body(self):
            if self.headers.get("transfer-encoding", "").lower() == "chunked":
                chunks = []
                while True:
                    size_line = self.rfile.readline().strip()
                    size = int(size_line.split(b";")[0], 16) if size_line else 0
                    if size == 0:
                        self.rfile.readline()      # trailing CRLF
                        break
                    chunks.append(self.rfile.read(size))
                    self.rfile.readline()
                return b"".join(chunks)
            length = int(self.headers.get("content-length", 0) or 0)
            return self.rfile.read(length) if length else b""

        def _do_relay(self):
            body = self._read_body()

            # Rebuild headers: drop hop-by-hop + the agent's placeholder auth, then inject
            # the real credential and pin Host to the true upstream.
            out_headers = {}
            for k, v in self.headers.items():
                lk = k.lower()
                if lk in HOP_BY_HOP or lk in strip:
                    continue
                out_headers[k] = v
            secret = cred.current_secret()
            if secret is None:
                # No usable token → fail loudly instead of sending the literal header
                # "Bearer None" upstream and getting an opaque 401 the agent can't
                # diagnose. current_secret() already logged the specific cause.
                self.send_error(502, "broker credential unavailable")
                return
            out_headers[provider["inject_header"]] = \
                provider["inject_template"].format(secret=secret)
            # Host is intentionally NOT set: it is in HOP_BY_HOP, so the agent's
            # "Host: cc-broker:8080" was already dropped, and http.client re-generates the
            # correct upstream Host (with :port only when non-default) from the connection.

            ctx = ssl.create_default_context() if origin.scheme == "https" else None
            conn = (http.client.HTTPSConnection(up_host, up_port, context=ctx, timeout=600)
                    if origin.scheme == "https"
                    else http.client.HTTPConnection(up_host, up_port, timeout=600))
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

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _relay

    return Handler


def provider_id_of(provider):
    for pid, p in PROVIDERS.items():
        if p is provider:
            return pid
    return "?"


# ── Logging (single line, stdout; the notifier greps for BROKER-*) ───────────
_log_lock = threading.Lock()


def log(msg):
    with _log_lock:
        sys.stdout.write(msg + "\n")
        sys.stdout.flush()


# ── serve ────────────────────────────────────────────────────────────────────
def serve(config_path):
    with open(config_path) as fh:
        cfg = json.load(fh)
    out_dir = cfg.get("out_dir", "/run/broker/out")
    os.makedirs(out_dir, exist_ok=True)

    servers = []
    for pid in cfg.get("enabled", []):
        provider = PROVIDERS.get(pid)
        if provider is None:
            log("BROKER-SKIP unknown provider %s" % pid)
            continue
        token_path = cfg.get("token_paths", {}).get(pid)
        if not token_path or not os.path.exists(token_path):
            log("BROKER-SKIP %s: no token at %s" % (pid, token_path))
            continue

        cred = Credential(pid, provider, token_path)
        if cred.current_secret() is None:
            log("BROKER-FATAL %s: token file present but unusable" % pid)
            continue

        # Mint the placeholder credential file the agent will get, into the shared out dir
        # cc reads. Synthetic — no real credential is opened here or anywhere else.
        try:
            mint_placeholder(os.path.join(out_dir, "%s.cred.json" % pid), provider)
        except OSError as e:
            log("BROKER-FATAL %s: cannot mint placeholder: %s" % (pid, e.strerror))
            continue

        port = provider["listen_port"]
        httpd = ThreadingHTTPServer(("0.0.0.0", port), make_handler(provider, cred))
        httpd.daemon_threads = True
        servers.append(httpd)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        log("BROKER-UP %s :%d -> %s" % (pid, port, provider["upstream_origin"]))

    if not servers:
        log("BROKER-FATAL no routes came up")
        sys.exit(1)

    # Signal readiness to cc LAST — only after every placeholder is minted and every port
    # is bound. cc polls this file host-side before mounting the placeholder into the agent.
    with open(os.path.join(out_dir, "ready"), "w") as fh:
        fh.write("ok\n")
    log("BROKER-READY %d route(s)" % len(servers))

    while True:
        time.sleep(3600)


# ── host-config (facts for cc; single source of truth) ───────────────────────
def host_config(pid):
    p = PROVIDERS.get(pid)
    if p is None:
        sys.exit("unknown provider: %s" % pid)
    # CCB_ prefix (cc-broker) — distinct from cc-portable's KIB_ user-config vars.
    # A fresh placeholder token is emitted here too so cc gets everything for the agent from
    # ONE python3 spawn on the launch path. It is a fake_value_ sentinel with the provider's
    # prefix — safe to eval (no shell metacharacters), and never a real credential.
    print("CCB_BASE_URL_ENV=%s" % p.get("agent_base_url_env", ""))
    print("CCB_TOKEN_ENV=%s" % p.get("agent_token_env", ""))
    print("CCB_PLACEHOLDER_TOKEN=%s" % _fake(p.get("token_prefix", "")))
    print("CCB_LISTEN_PORT=%d" % p["listen_port"])
    print("CCB_PLACEHOLDER_CONTAINER_PATH=%s" % p.get("placeholder_container_path", ""))
    print("CCB_TOKEN_BASENAME=%s" % p.get("token_basename", ""))
    print("CCB_DELIVERY=%s" % p["delivery"])


# ── probe: is this token accepted upstream? (host-side, never prints the token) ──
def probe(token_path, pid):
    """Exit 0 if the upstream ACCEPTS the token, 1 if it rejects it, 2 if we can't tell.

    Distinguishing 'rejected' from 'something else went wrong' is the whole point: a 401
    means re-login, while a 429/500/network error means try again later and says nothing
    about the token. Prints status and error *type* only — never the token, and never a
    response body, which can echo request content."""
    p = PROVIDERS.get(pid)
    if p is None:
        sys.exit("unknown provider: %s" % pid)
    spec = p.get("probe")
    if not spec:
        print("no probe defined for %s" % pid)
        return 2
    try:
        with open(token_path) as fh:
            token = fh.read().strip()
    except OSError as e:
        print("cannot read the token file: %s" % e.strerror)
        return 2
    if not token:
        print("the token file is empty")
        return 1

    origin = urllib.parse.urlsplit(p["upstream_origin"])
    headers = dict(spec.get("headers", {}))
    headers[p["inject_header"]] = p["inject_template"].format(secret=token)
    body = json.dumps(spec["body"]).encode() if spec.get("body") is not None else None
    method = spec.get("method", "POST" if body else "GET")

    try:
        conn = http.client.HTTPSConnection(origin.hostname, origin.port or 443,
                                           context=ssl.create_default_context(), timeout=30)
        conn.request(method, spec["path"], body=body, headers=headers)
        resp = conn.getresponse()
        status = resp.status
        raw = resp.read(4096)
        conn.close()
    except Exception as e:                # noqa: BLE001
        print("could not reach %s: %s" % (origin.hostname, type(e).__name__))
        return 2

    kind = ""
    try:
        kind = (json.loads(raw).get("error") or {}).get("type", "")
    except Exception:                     # noqa: BLE001
        pass

    if status == 200:
        print("✅ token accepted by %s (HTTP 200)" % origin.hostname)
        return 0
    if status in (401, 403):
        print("❌ token REJECTED by %s (HTTP %d%s) — mint a new one with: cc --broker-login"
              % (origin.hostname, status, ", " + kind if kind else ""))
        return 1
    print("⚠️  inconclusive: %s answered HTTP %d%s. The token was not rejected, so this is "
          "probably rate limiting or an upstream problem — retry."
          % (origin.hostname, status, ", " + kind if kind else ""))
    return 2


def main():
    ap = argparse.ArgumentParser(description="keep-it-in-your-box credential broker")
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--config")
    ap.add_argument("--host-config", metavar="PROVIDER_ID")
    ap.add_argument("--make-placeholder", nargs=2, metavar=("OUT", "PROVIDER_ID"))
    ap.add_argument("--placeholder-token", metavar="PROVIDER_ID")
    ap.add_argument("--probe", nargs=2, metavar=("TOKENFILE", "PROVIDER_ID"))
    args = ap.parse_args()

    if args.host_config:
        host_config(args.host_config)
    elif args.placeholder_token:
        p = PROVIDERS.get(args.placeholder_token)
        if p is None:
            ap.error("unknown provider: %s" % args.placeholder_token)
        print(_fake(p.get("token_prefix", "")))
    elif args.make_placeholder:
        out, pid = args.make_placeholder
        mint_placeholder(out, PROVIDERS[pid])
    elif args.probe:
        raise SystemExit(probe(args.probe[0], args.probe[1]))
    elif args.serve:
        if not args.config:
            ap.error("--serve requires --config")
        serve(args.config)
    else:
        ap.error("one of --serve / --host-config / --make-placeholder / "
                 "--placeholder-token / --probe is required")


if __name__ == "__main__":
    main()
