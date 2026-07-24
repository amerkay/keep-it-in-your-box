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
import re
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
        "credential_kind": "paste_token",   # a token the user pastes (vs a file path)
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
        "credential_kind": "paste_token",
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
        "credential_kind": "paste_token",
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

    # ── No MCP routes are built in ───────────────────────────────────────────────
    # Only the LLMs Claude Code natively speaks (above) are hardcoded. Every MCP — DataForSEO,
    # mcp-gsc, or a service we've never heard of — is USER-DEFINED, added without touching this
    # file (see below). Two worked examples ship in examples/providers/ ready to copy in.
}

# ── User-defined providers: broker ANY MCP, no code change ───────────────────
# The only built-ins are the LLM rows above. A user brokers ANY MCP by dropping a
# provider-definition JSON in ~/.keep-it-in-your-box/providers.d/ — written by `cc --add-mcp`,
# synthesized by `cc --mcp-adopt` from an inline `claude mcp add --header …`, or copied from
# examples/providers/{dataforseo,gsc}.json. cc points CC_PROVIDERS_DIR at that dir (host-side,
# and mounted read-only into the broker sidecar), and _merge_user_providers() folds them onto
# PROVIDERS so list/host_config/serve/match treat a user route exactly like a built-in. A
# definition is a partial provider dict; _finalize fills the rest. The LLM built-ins are NOT
# overridable (a user file named after one is ignored) so a poisoned file can't redirect the
# Claude token's upstream.
#
# Two delivery modes cover every MCP:
#   reverse_proxy_mcp — a REMOTE MCP with a STATIC auth header to a fixed upstream. Brokered
#     exactly like an LLM (inject header, re-originate TLS, no CA, secret never in the sandbox).
#     The agent's .claude.json gets `url: http://cc-broker:<port><mcp_path>` with NO header.
#     (Example: DataForSEO, Basic auth.)
#   hosted_mcp — a LOCAL / client-signed MCP (e.g. a Google service-account JSON signed
#     client-side) that CANNOT be header-brokered. The MCP SERVER runs in its own sidecar
#     (start_hosted_mcp) holding the credential file; the broker never serves it (serve() skips
#     hosted_mcp). The agent reaches it over the broker network at the alias. (Example: mcp-gsc.)
_REQUIRED = {
    "reverse_proxy_mcp": ("upstream_origin", "listen_port", "inject_header", "inject_template"),
    "hosted_mcp": ("host_run", "mcp_port"),
}


def _finalize_provider(pid, p):
    """Fill fields a user file may omit so the rest of the module treats it like a built-in."""
    p.setdefault("credential_kind", "paste_token")
    p.setdefault("token_basename", "%s-token" % pid)
    p.setdefault("mcp_server_name", pid)
    p.setdefault("mcp_path", "")
    p.setdefault("mcp_transport", "http")
    p.setdefault("placeholder_container_path", "")
    p.setdefault("placeholder_template", None)
    p.setdefault("placeholder_fake_pointers", [])
    p.setdefault("probe", None)
    if p.get("delivery") == "reverse_proxy_mcp":
        p.setdefault("inject_header", "Authorization")
        p.setdefault("inject_template", "Bearer {secret}")
        p.setdefault("strip_incoming", [p["inject_header"].lower()])
    elif p.get("delivery") == "hosted_mcp":
        p.setdefault("extra_env", {})
    return p


def _merge_user_providers():
    d = os.environ.get("CC_PROVIDERS_DIR")
    if not d or not os.path.isdir(d):
        return
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, fn)) as fh:
                p = json.load(fh)
        except (OSError, ValueError) as e:
            sys.stderr.write("cc-broker: skipping bad provider def %s (%s)\n" % (fn, type(e).__name__))
            continue
        pid = p.get("id") or fn[:-5]
        if pid in PROVIDERS:                       # never override a built-in preset
            sys.stderr.write("cc-broker: ignoring user def %s — '%s' is a built-in\n" % (fn, pid))
            continue
        need = _REQUIRED.get(p.get("delivery"))
        if not need or not all(p.get(k) not in (None, "", []) for k in need):
            sys.stderr.write("cc-broker: skipping incomplete provider def %s\n" % fn)
            continue
        PROVIDERS[pid] = _finalize_provider(pid, p)


# Next free listen port for a NEW user route: at/above 8100, clear of the built-in LLM band
# (8080–8082), so user MCP routes never collide with a built-in. Read after _merge_user_providers
# so it also counts ports already claimed by existing user defs.
def next_free_port():
    used = [v for p in PROVIDERS.values() for v in (p.get("listen_port"), p.get("mcp_port"))
            if isinstance(v, int)]
    return max(used + [8099]) + 1


def next_port():
    print(next_free_port())


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
        # hosted_mcp routes run the MCP server in their OWN sidecar (start_hosted_mcp) and
        # hold the credential there; the broker never proxies them. Guard even though cc keeps
        # them out of `enabled` — a stray row must not KeyError on the reverse-proxy fields.
        if provider.get("delivery") == "hosted_mcp":
            log("BROKER-SKIP %s: hosted_mcp is served by its own sidecar" % pid)
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
def _emit(key, value):
    """Emit `KEY='value'` shell-quoted, so `eval` in _broker_host_config is safe even when a
    value contains spaces (CCB_HOST_RUN='uvx mcp-search-console') — an unquoted space would be
    read as `VAR=word cmd` and try to run `cmd`."""
    import shlex
    print("%s=%s" % (key, shlex.quote(str(value))))


def host_config(pid):
    p = PROVIDERS.get(pid)
    if p is None:
        sys.exit("unknown provider: %s" % pid)
    # CCB_ prefix (cc-broker) — distinct from cc-portable's KIB_ user-config vars.
    # A fresh placeholder token is emitted here too so cc gets everything for the agent from
    # ONE python3 spawn on the launch path. It is a fake_value_ sentinel with the provider's
    # prefix — safe to eval (no shell metacharacters), and never a real credential.
    _emit("CCB_BASE_URL_ENV", p.get("agent_base_url_env", ""))
    _emit("CCB_TOKEN_ENV", p.get("agent_token_env", ""))
    _emit("CCB_PLACEHOLDER_TOKEN", _fake(p.get("token_prefix", "")))
    _emit("CCB_LISTEN_PORT", p.get("listen_port") or "")   # empty for hosted_mcp
    _emit("CCB_PLACEHOLDER_CONTAINER_PATH", p.get("placeholder_container_path", ""))
    _emit("CCB_TOKEN_BASENAME", p.get("token_basename", ""))
    _emit("CCB_DELIVERY", p["delivery"])
    _emit("CCB_CREDENTIAL_KIND", p.get("credential_kind", ""))
    # MCP wiring (empty for LLM rows): how cc writes this route into the agent's .claude.json,
    # and — for hosted_mcp — the sidecar port the agent reaches.
    _emit("CCB_MCP_SERVER_NAME", p.get("mcp_server_name", ""))
    _emit("CCB_MCP_PATH", p.get("mcp_path", ""))
    _emit("CCB_MCP_TRANSPORT", p.get("mcp_transport", ""))
    _emit("CCB_MCP_PORT", p.get("mcp_port") or p.get("listen_port") or "")
    _emit("CCB_CREDENTIAL_ENV", p.get("credential_env", ""))
    # hosted_mcp only: how to run the MCP server inside its sidecar, plus its extra env
    # (KEY=VAL pairs). Constants in the table; word-split by cc after the eval un-quotes them.
    _emit("CCB_HOST_RUN", " ".join(p.get("host_run", [])))
    _emit("CCB_EXTRA_ENV", " ".join("%s=%s" % (k, v)
                                    for k, v in p.get("extra_env", {}).items()))


# ── registry listing (drives the bash-side provider loop; one line per route) ────
def list_providers():
    """One line per route: `id|delivery|credential_kind|token_basename`. The bash side
    (broker_enabled_providers, cc --login/--status) iterates this instead of duplicating the
    table — the single source of truth stays here. Fields are all `[a-z0-9._-]`, safe to
    word-split in POSIX sh."""
    for pid, p in PROVIDERS.items():
        print("%s|%s|%s|%s" % (pid, p["delivery"],
                               p.get("credential_kind", ""), p.get("token_basename", "")))


# ── Shared cc-side helpers (imported by cc-lib.sh's adopt/add/intercept/warn heredocs) ──
# These four cc subcommands used to hand-roll the same secret-shape tests, reverse-proxy
# provider synthesis, and atomic mode-600 stores in separate python heredocs — three copies that
# drifted (the interceptor flagged `AUTH` env keys the warner missed, and brokered headers[0]
# blindly). Defining them ONCE here — the module the heredocs already import (like
# tests/broker-test.py) — is the single source of truth, so the after-the-fact warner and the
# front-line interceptor cannot disagree about what a secret looks like. All are pure and hold no
# state; none prints a secret.
AUTH_HEADER_NAMES = frozenset(("authorization", "x-api-key", "api-key", "x-goog-api-key"))
_SECRET_KEY_RE = re.compile(r"(TOKEN|KEY|SECRET|PASSWORD|PASSWD|AUTH|CREDENTIAL)", re.I)
_AUTH_SCHEME_RE = re.compile(r"(sk-|Bearer |Basic )")     # a credential-scheme prefix
_B64_VAL_RE = re.compile(r"[A-Za-z0-9+/]{16,}={0,2}$")
_HEX_VAL_RE = re.compile(r"[0-9a-fA-F]{24,}$")


def key_is_secret(k):
    """A header/env NAME that names a credential (Authorization, *_TOKEN, API_KEY, …)."""
    return bool(_SECRET_KEY_RE.search(k or ""))


def value_has_auth_scheme(v):
    """A VALUE that begins with a credential scheme (Bearer/Basic/sk-)."""
    return bool(_AUTH_SCHEME_RE.match(v or ""))


def value_is_secret(v):
    """A VALUE shaped like a credential: a scheme prefix, or a long base64/hex blob. For ENV
    values, where a bare token is common. NOT used for header values — a 16-char MIME type like
    'application/json' is valid base64, so header auth keys off the scheme/name (see
    is_auth_header) to avoid that false positive."""
    v = v or ""
    return bool(value_has_auth_scheme(v) or _B64_VAL_RE.fullmatch(v) or _HEX_VAL_RE.fullmatch(v))


def env_is_secret(kv):
    """True if a `KEY=VALUE` env pair carries a credential — by KEY name or by VALUE shape."""
    k, _, v = kv.partition("=")
    return key_is_secret(k) or value_is_secret(v)


def is_auth_header(name, value):
    """True if an HTTP header carries auth — a known auth NAME, or a scheme-prefixed VALUE
    (Bearer/Basic/sk-). Deliberately NOT the bare base64/hex heuristic: a common header value like
    'application/json' is valid base64 and must not read as a credential."""
    return (name or "").lower() in AUTH_HEADER_NAMES or value_has_auth_scheme(value)


def find_auth_header(headers):
    """Pick the credential-bearing header from ['Name: value', …] or [(name, value), …].
    Prefer a recognised auth NAME, else a scheme-prefixed VALUE — so the auth header need NOT be
    first (the old headers[0] assumption brokered the wrong header). Returns (name, value) or
    (None, None)."""
    pairs = []
    for h in headers:
        if isinstance(h, (list, tuple)):
            n, v = h[0], h[1]
        else:
            n, _, v = h.partition(":")
        pairs.append((n.strip(), v.strip()))
    for n, v in pairs:                       # 1st preference: a recognised auth header name
        if v and (n or "").lower() in AUTH_HEADER_NAMES:
            return n, v
    for n, v in pairs:                       # 2nd: a value carrying an explicit auth scheme
        if v and value_has_auth_scheme(v):
            return n, v
    return None, None


def scheme_of(header_value):
    """The auth-scheme prefix (Bearer/Basic/'') a header value carries."""
    for s in ("Bearer", "Basic"):
        if header_value.startswith(s + " "):
            return s
    return ""


def recover_secret(header_value, scheme):
    """The raw secret with its scheme prefix (if any) stripped."""
    v = header_value
    if scheme and v.startswith(scheme + " "):
        v = v[len(scheme) + 1:]
    return v.strip()


def synthesize_reverse_proxy(name, url, header_name, scheme, port, transport="http"):
    """Build a reverse_proxy_mcp provider def (NO secret in it) from an inline remote MCP entry.
    The one place this dict shape is defined for adopt/add/intercept. Raises ValueError on a
    non-http(s) url."""
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError("cannot parse an http(s) upstream from url %r" % url)
    return {
        "id": name, "delivery": "reverse_proxy_mcp", "credential_kind": "paste_token",
        "upstream_origin": "%s://%s" % (u.scheme, u.netloc),
        "mcp_path": u.path or "",
        "mcp_transport": transport if transport in ("http", "sse") else "http",
        "inject_header": header_name or "Authorization",
        "inject_template": (scheme + " {secret}") if scheme else "{secret}",
        "listen_port": port, "token_basename": "%s-token" % name, "mcp_server_name": name,
    }


def write_provider_def(provdir, name, prov):
    """Atomically write a provider def to <provdir>/<name>.json under a mode-700 dir."""
    os.makedirs(provdir, exist_ok=True)
    os.chmod(provdir, 0o700)
    pf = os.path.join(provdir, name + ".json")
    tmp = pf + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as fh:
        json.dump(prov, fh, indent=2)
    os.replace(tmp, pf)
    return pf


def store_secret(kib, basename, secret):
    """Atomically write a secret to <kib>/<basename>, mode 600, never briefly world-readable.
    The single atomic-store idiom the adopt/intercept heredocs share (bash keeps its own
    _store_secret_file for the paths where the secret is a shell variable)."""
    os.makedirs(kib, exist_ok=True)
    os.chmod(kib, 0o700)
    dest = os.path.join(kib, basename)
    old = os.umask(0o077)
    try:
        tmp = dest + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as fh:
            fh.write(secret + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
    finally:
        os.umask(old)
    return dest


# ── match a URL to a reverse_proxy_mcp route (for cc --mcp-adopt) ─────────────
def match_upstream_route(url):
    """Return `(id, token_basename, auth_scheme)` for an EXISTING reverse_proxy_mcp route (always
    a user-defined one — no MCP is built in) whose upstream host matches `url`'s host, else None.
    Lets `cc --mcp-adopt` reuse a route the user already added for that host instead of
    synthesizing a duplicate. auth_scheme is the literal prefix the inject template puts before
    the secret (Basic / Bearer / empty) so cc can strip it off the inline header to recover the
    raw stored secret."""
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    if not host:
        return None
    for pid, p in PROVIDERS.items():
        if p.get("delivery") != "reverse_proxy_mcp":
            continue
        up = (urllib.parse.urlsplit(p["upstream_origin"]).hostname or "").lower()
        if up and up == host:
            scheme = p.get("inject_template", "{secret}").replace("{secret}", "").strip()
            return pid, p.get("token_basename", ""), scheme
    return None


def match_upstream(url):
    r = match_upstream_route(url)
    if r:
        print("%s|%s|%s" % r)


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
    ap.add_argument("--list-providers", action="store_true",
                    help="emit `id|delivery|credential_kind|token_basename` per route")
    ap.add_argument("--match-upstream", metavar="URL",
                    help="print `id|token_basename|auth_scheme` for the route serving URL's host")
    ap.add_argument("--next-port", action="store_true",
                    help="print the next free listen port for a new user-defined route")
    ap.add_argument("--make-placeholder", nargs=2, metavar=("OUT", "PROVIDER_ID"))
    ap.add_argument("--placeholder-token", metavar="PROVIDER_ID")
    ap.add_argument("--probe", nargs=2, metavar=("TOKENFILE", "PROVIDER_ID"))
    args = ap.parse_args()
    _merge_user_providers()          # fold ~/.keep-it-in-your-box/providers.d/*.json onto the LLM built-ins

    if args.host_config:
        host_config(args.host_config)
    elif args.list_providers:
        list_providers()
    elif args.next_port:
        next_port()
    elif args.match_upstream:
        match_upstream(args.match_upstream)
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
        ap.error("one of --serve / --host-config / --list-providers / --make-placeholder / "
                 "--placeholder-token / --probe is required")


if __name__ == "__main__":
    main()
