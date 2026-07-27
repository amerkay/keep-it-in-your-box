"""The credential broker: relay, injection, streaming, minting — and the logout guards.

The regression this suite exists for is the one that logged the account out: the broker must
hold a STATIC token and must never write a credential. `test_no_write_path_*` and
`test_placeholder_is_synthetic` are those guards — do not relax them to accommodate a
reintroduced refresh loop (see kib/broker/__init__.py for the post-mortem).

Pure stdlib, no docker: a fake upstream plus an in-process broker prove the agent's
placeholder is stripped, the REAL secret is injected upstream, and the response streams back.
"""

import http.client
import inspect
import json
import os
import stat
import threading
import time
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

from kib.broker import cli as broker_cli
from kib.broker import credential, helpers, proxy, registry

REAL_SECRET = "REAL-sk-ant-oat01-abcdef123456"
BROKER_SRC = Path(inspect.getfile(credential)).parent


class _Upstream(BaseHTTPRequestHandler):
    """Records what actually reached the far side, and streams three SSE-ish chunks back."""

    seen: dict[str, Any] = {}
    protocol_version = "HTTP/1.1"

    def log_message(self, *a: Any) -> None:
        pass

    def do_POST(self) -> None:
        length = int(self.headers.get("content-length", 0) or 0)
        _Upstream.seen = {
            "body": self.rfile.read(length),
            "auth": self.headers.get("Authorization"),
            "xapikey": self.headers.get("x-api-key"),
            "host": self.headers.get("Host"),
            "path": self.path,
        }
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        for i in range(3):
            self.wfile.write(f"data: chunk{i}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.01)


@pytest.fixture(scope="module")
def upstream() -> Iterator[int]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Upstream)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield int(server.server_address[1])
    server.shutdown()
    server.server_close()


@pytest.fixture
def token_file(tmp_path: Path) -> Path:
    path = tmp_path / "claude-token"
    path.write_text(REAL_SECRET + "\n")
    path.chmod(0o600)
    return path


def reverse_provider(upstream: int, path: str = "") -> dict[str, Any]:
    """A reverse_proxy_mcp row pointed at the fake upstream. No port — routes are muxed."""
    return {
        "delivery": "reverse_proxy_mcp",
        "upstream_origin": f"http://127.0.0.1:{upstream}",
        "inject_header": "Authorization",
        "inject_template": "Bearer {secret}",
        "strip_incoming": ["authorization", "x-api-key"],
        "mcp_path": path,
    }


def listen(handler: type[Any]) -> ThreadingHTTPServer:
    """Serve `handler` on an ephemeral port; the caller shuts it down."""
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    time.sleep(0.05)
    return server


@pytest.fixture
def route(upstream: int, token_file: Path) -> Iterator[tuple[int, credential.Credential]]:
    """A live broker listener in front of the fake upstream. Yields (port, credential)."""
    provider = {
        "upstream_origin": f"http://127.0.0.1:{upstream}",
        "inject_header": "Authorization",
        "inject_template": "Bearer {secret}",
        "strip_incoming": ["authorization", "x-api-key"],
        "listen_port": 0,
    }
    cred = credential.Credential("claude", provider, str(token_file))
    server = listen(proxy.make_handler(proxy.Route("claude", provider, cred)))
    yield int(server.server_address[1]), cred
    server.shutdown()
    server.server_close()


def post(port: int, path: str = "/v1/messages", body: bytes = b'{"hi":true}') -> tuple[int, str]:
    """One agent-shaped request, sending the PLACEHOLDER auth the real agent would send."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        conn.request(
            "POST",
            path,
            body=body,
            headers={
                "Authorization": "Bearer fake_value_deadbeef",
                "x-api-key": "fake_value_deadbeef",
                "content-type": "application/json",
            },
        )
        resp = conn.getresponse()
        return resp.status, resp.read().decode()
    finally:
        conn.close()


# ── relay ────────────────────────────────────────────────────────
def test_the_real_secret_reaches_upstream(route: tuple[int, Any], upstream: int) -> None:
    status, _ = post(route[0])
    assert status == 200
    assert _Upstream.seen["auth"] == "Bearer " + REAL_SECRET


def test_the_agents_placeholder_never_leaves_the_broker(route: tuple[int, Any]) -> None:
    post(route[0])
    assert "fake_value" not in (_Upstream.seen["auth"] or "")
    assert _Upstream.seen["xapikey"] is None, "a stripped header was forwarded anyway"


def test_host_is_re_originated_to_the_upstream(route: tuple[int, Any], upstream: int) -> None:
    post(route[0])
    assert _Upstream.seen["host"] in ("127.0.0.1", f"127.0.0.1:{upstream}")


def test_the_body_is_forwarded_verbatim(route: tuple[int, Any]) -> None:
    post(route[0], body=b'{"x":42}')
    assert _Upstream.seen["body"] == b'{"x":42}'


def test_the_response_streams_unbuffered(route: tuple[int, Any]) -> None:
    _, data = post(route[0])
    assert data.count("data: chunk") == 3


def test_a_trailing_newline_in_the_token_file_is_stripped(route: tuple[int, Any]) -> None:
    assert route[1].current_secret() == REAL_SECRET


# ── the path allowlist (audit MAC-L2 / R3) ───────────────────────
# The origin was always pinned, so the credential could never be redirected. This is the other
# half: what the box can DO against that origin with a token it never sees.
@pytest.fixture
def gated(upstream: int, token_file: Path) -> Iterator[int]:
    provider = {
        "upstream_origin": f"http://127.0.0.1:{upstream}",
        "inject_header": "Authorization",
        "inject_template": "Bearer {secret}",
        "strip_incoming": [],
        "listen_port": 0,
        "allow_paths": ["/v1/", "/api/oauth/profile"],
    }
    cred = credential.Credential("claude", provider, str(token_file))
    server = listen(proxy.make_handler(proxy.Route("claude", provider, cred)))
    yield int(server.server_address[1])
    server.shutdown()
    server.server_close()


@pytest.mark.parametrize("path", ["/v1/messages", "/v1/messages?beta=true", "/api/oauth/profile"])
def test_an_allowed_path_still_relays(gated: int, path: str) -> None:
    """The query string is the caller's — `?beta=true` must not turn an allowed path away."""
    assert post(gated, path=path)[0] == 200


@pytest.mark.parametrize(
    "path",
    [
        "/api/oauth/claude_cli/create_api_key",  # the mint the audit reached for
        "/api/organizations",
        "/v1beta/models",  # a neighbouring prefix, not this route's
        "/",
        # The upstream normalises before it routes (RFC 3986), so an allowlist that matches the
        # bytes we forward rather than the path they RESOLVE to is no allowlist at all.
        "/v1/../api/oauth/claude_cli/create_api_key",
        "/v1/./../api/organizations",
        "/v1/..%2fapi/oauth/claude_cli/create_api_key",
        # Prefix vs segment: `/api/oauth/profile` must not also mean everything spelled like it.
        "/api/oauth/profileEVIL",
    ],
)
def test_a_path_outside_the_allowlist_is_refused(gated: int, path: str) -> None:
    _Upstream.seen = {}
    assert post(gated, path=path)[0] == 404
    assert _Upstream.seen == {}, "the request reached upstream with the real token attached"


def test_every_llm_route_has_an_allowlist() -> None:
    """A built-in row brokers the user's own account token; an unbounded one is the finding."""
    for pid, p in registry.PROVIDERS.items():
        assert p.get("allow_paths"), pid


# ── the logout guards ────────────────────────────────────────────
def test_placeholder_is_synthetic() -> None:
    """mint_placeholder takes (out_path, provider) only — thread a real-credential path back
    in and the arity changes, which is what this catches."""
    assert list(inspect.signature(credential.mint_placeholder).parameters) == [
        "out_path",
        "provider",
    ]


def test_no_refresh_machinery_exists_under_any_name() -> None:
    for name in ("maybe_refresh", "_do_refresh", "_expiry_seconds", "refresh"):
        assert not hasattr(credential.Credential, name)
    src = "".join(p.read_text() for p in sorted(BROKER_SRC.glob("*.py")))
    assert "refresh_token" not in src.replace("refreshToken", "")
    assert "grant_type" not in src


def test_no_write_path_to_a_credential() -> None:
    src = "".join(p.read_text() for p in sorted(BROKER_SRC.glob("*.py")))
    assert 'open(self.path, "w' not in src
    assert "open(self.path, 'w" not in src


def test_no_write_path_serves_fine_with_a_read_only_token(
    route: tuple[int, Any], token_file: Path
) -> None:
    """Proved by permission, not just by inspection."""
    token_file.chmod(0o400)
    try:
        assert post(route[0])[0] == 200
    finally:
        token_file.chmod(0o600)


def test_a_rotated_token_is_picked_up_without_a_restart(
    route: tuple[int, Any], token_file: Path
) -> None:
    """A host-side `kib broker login` mid-session must take effect."""
    _, cred = route
    assert cred.current_secret() == REAL_SECRET
    time.sleep(0.01)
    token_file.write_text("ROTATED-sk-ant-oat01-999999\n")
    assert cred.current_secret() == "ROTATED-sk-ant-oat01-999999"


def test_an_empty_token_fails_closed(route: tuple[int, Any], token_file: Path) -> None:
    """Never inject "Bearer None" and hand the agent an opaque 401 to puzzle over."""
    port, cred = route
    token_file.write_text("")
    assert cred.current_secret() is None
    assert post(port)[0] == 502


# ── placeholder minting ──────────────────────────────────────────
def test_minted_placeholder_is_fake_and_mode_600(tmp_path: Path) -> None:
    out = tmp_path / "cred.json"
    assert credential.mint_placeholder(str(out), registry.PROVIDERS["claude"]) is True
    data = json.loads(out.read_text())
    assert data["claudeAiOauth"]["accessToken"].startswith(credential.FAKE_PREFIX)
    assert data["claudeAiOauth"]["refreshToken"].startswith(credential.FAKE_PREFIX)
    assert data["claudeAiOauth"]["expiresAt"] == credential.FAR_FUTURE_MS
    assert stat.S_IMODE(out.stat().st_mode) == 0o600


def test_a_provider_with_no_template_mints_nothing(tmp_path: Path) -> None:
    assert (
        credential.mint_placeholder(str(tmp_path / "x.json"), {"placeholder_template": None})
        is False
    )


def test_the_placeholder_token_is_prefixed_and_obviously_fake() -> None:
    token = credential.fake(registry.PROVIDERS["claude"]["token_prefix"])
    assert token.startswith("sk-ant-oat01-") and credential.FAKE_PREFIX in token


# ── probe: the file-level arms, without the network ──────────────
def test_probe_on_an_empty_token_is_a_rejection(tmp_path: Path) -> None:
    empty = tmp_path / "empty.token"
    empty.write_text("")
    assert broker_cli.probe(str(empty), "claude") == 1


def test_probe_on_a_missing_token_is_inconclusive(tmp_path: Path) -> None:
    assert broker_cli.probe(str(tmp_path / "nope.token"), "claude") == 2


def test_probe_on_an_unknown_provider_never_reads_as_accepted(tmp_path: Path) -> None:
    empty = tmp_path / "empty.token"
    empty.write_text("")
    with pytest.raises(Exception, match="unknown provider"):
        broker_cli.probe(str(empty), "nosuchprovider")


# ── the registry ─────────────────────────────────────────────────
def test_only_llms_are_built_in() -> None:
    """No MCP may ever be hardcoded again — every MCP is user-defined (providers.d)."""
    assert all(p.get("delivery") == "base_url_env" for p in registry.PROVIDERS.values())


def test_every_built_in_row_is_complete() -> None:
    required = (
        "agent_base_url_env",
        "agent_token_env",
        "listen_port",
        "upstream_origin",
        "inject_header",
        "inject_template",
        "token_basename",
    )
    for pid, p in registry.PROVIDERS.items():
        assert p.get("credential_kind") in ("paste_token", "file_path"), pid
        assert all(p.get(k) not in (None, "", []) for k in required), pid


def user_def(providers_dir: Path, name: str, **over: Any) -> Path:
    """Write a minimal valid reverse_proxy_mcp def, overriding/removing fields per test."""
    prov: dict[str, Any] = {
        "id": name,
        "delivery": "reverse_proxy_mcp",
        "upstream_origin": f"https://mcp.{name}.test",
        "inject_header": "X-API-Key",
        "inject_template": "{secret}",
    }
    prov.update(over)
    path = providers_dir / f"{name}.json"
    path.write_text(json.dumps({k: v for k, v in prov.items() if v is not None}))
    return path


def test_user_defs_are_merged_and_finalized(providers_dir: Path) -> None:
    user_def(providers_dir, "acme")
    (providers_dir / "hosted.json").write_text(
        json.dumps(
            {
                "id": "hosted",
                "delivery": "hosted_mcp",
                "credential_kind": "file_path",
                "token_basename": "hosted.json",
                "host_run": ["uvx", "mcp-search-console"],
                "credential_env": "HT_CRED",
                "extra_env": {"HT_FLAG": "true"},
            }
        )
    )
    registry.merge_user_providers()
    assert registry.DEF_PROBLEMS == []
    assert "acme" in registry.PROVIDERS
    assert registry.PROVIDERS["hosted"]["mcp_transport"] == "http"
    assert registry.PROVIDERS["hosted"]["mcp_server_name"] == "hosted"
    # Hosted rows get the shared number inside their own netns; nothing is user-settable.
    assert registry.PROVIDERS["hosted"]["mcp_port"] == registry.MCP_PORT


def test_a_user_def_cannot_override_a_built_in(providers_dir: Path) -> None:
    """A poisoned file must never be able to redirect the Claude token's upstream."""
    before = registry.PROVIDERS["claude"]["upstream_origin"]
    user_def(providers_dir, "claude", upstream_origin="https://evil.test")
    registry.merge_user_providers()
    assert registry.PROVIDERS["claude"]["upstream_origin"] == before
    assert any("built-in" in p for p in registry.DEF_PROBLEMS)


@pytest.mark.parametrize(
    ("over", "needle"),
    [
        ({"inject_header": None}, "inject_header"),
        ({"delivery": "wat"}, "delivery"),
        ({"listen_port": 8100}, "listen_port"),
        ({"upstream_origin": "https://mcp.x.test/http"}, "mcp_path"),
        ({"upstream_origin": "notaurl"}, "upstream_origin"),
        ({"id": "Acme"}, "route name"),
    ],
)
def test_a_bad_def_is_refused_and_the_field_is_named(
    providers_dir: Path, over: dict[str, Any], needle: str
) -> None:
    """'skipping incomplete provider def' with no field named is what made this unfixable."""
    user_def(providers_dir, "acme", **over)
    registry.merge_user_providers()
    assert "acme" not in registry.PROVIDERS and "Acme" not in registry.PROVIDERS
    assert any(needle in p for p in registry.DEF_PROBLEMS), registry.DEF_PROBLEMS
    assert all(p.startswith("acme.json:") for p in registry.DEF_PROBLEMS)


def test_a_missing_hosted_field_is_named_not_counted(providers_dir: Path) -> None:
    (providers_dir / "partial.json").write_text(
        json.dumps({"id": "partial", "delivery": "hosted_mcp"})
    )
    registry.merge_user_providers()
    assert "partial" not in registry.PROVIDERS
    assert registry.DEF_PROBLEMS == ['partial.json: "host_run" is missing']


def test_a_def_that_is_not_dot_json_is_reported_not_ignored(providers_dir: Path) -> None:
    """Silently skipping it is exactly how a hand-authored def vanishes without a word."""
    (providers_dir / "directus").write_text("{}")
    registry.merge_user_providers()
    assert registry.DEF_PROBLEMS == [
        "directus: only *.json files are read — rename it to directus.json"
    ]


def test_a_defs_id_must_match_its_filename(providers_dir: Path) -> None:
    """Otherwise `kib broker login <file stem>` and the route it wrote disagree."""
    user_def(providers_dir, "acme", id="other")
    registry.merge_user_providers()
    assert "other" not in registry.PROVIDERS
    assert any("must match" in p for p in registry.DEF_PROBLEMS)


def test_unparseable_json_is_reported_without_echoing_the_file(providers_dir: Path) -> None:
    (providers_dir / "acme.json").write_text('{"token": "sk-ant-SEKRIT99"')
    registry.merge_user_providers()
    assert registry.DEF_PROBLEMS and "SEKRIT99" not in " ".join(registry.DEF_PROBLEMS)


def test_no_route_carries_its_own_port(providers_dir: Path) -> None:
    """The knob that produced the incident must not exist for a user route at all."""
    user_def(providers_dir, "acme")
    registry.merge_user_providers()
    assert "listen_port" not in registry.PROVIDERS["acme"]


def test_route_urls_are_prefixed_per_route(providers_dir: Path) -> None:
    user_def(providers_dir, "acme", mcp_path="/http")
    registry.merge_user_providers()
    p = registry.PROVIDERS["acme"]
    assert registry.route_path("acme", p) == "/mcp/acme/http"
    assert registry.agent_url("acme", p, "kib-broker") == "http://kib-broker:8100/mcp/acme/http"
    # An LLM row is reached by env var, not a URL — it must not produce one.
    assert registry.route_path("claude", registry.PROVIDERS["claude"]) == ""


@pytest.mark.parametrize(
    "name", ["", "Acme", "a/b", "../etc", "a b", "a%2f", "-lead", "x" * 65, "claude"]
)
def test_validate_route_id_refuses_anything_unsafe(name: str) -> None:
    """One validator for a filename stem, a URL path segment and a word-split bash field."""
    assert helpers.validate_route_id(name, registry.BUILTIN_IDS) is not None


@pytest.mark.parametrize("name", ["acme", "dfs-mcp", "a.b_c", "x9"])
def test_validate_route_id_accepts_ordinary_names(name: str) -> None:
    assert helpers.validate_route_id(name, registry.BUILTIN_IDS) is None


def test_match_upstream_route_finds_a_user_route(providers_dir: Path) -> None:
    user_def(providers_dir, "acme")
    registry.merge_user_providers()
    assert registry.match_upstream_route("https://mcp.acme.test/v1") == ("acme", "acme-token", "")
    assert registry.match_upstream_route("https://unknown.test/x") is None


# ── the path mux: one listener, N routes ─────────────────────────
def test_the_prefix_is_stripped_before_forwarding(upstream: int, token_file: Path) -> None:
    prov = reverse_provider(upstream, "/http")
    routes = {"dfs": proxy.Route("dfs", prov, credential.Credential("dfs", prov, str(token_file)))}
    server = listen(proxy.make_mux_handler(routes))
    try:
        assert post(int(server.server_address[1]), "/mcp/dfs/http")[0] == 200
        assert _Upstream.seen["path"] == "/http", "the /mcp/<id> prefix reached the upstream"
        assert _Upstream.seen["auth"] == "Bearer " + REAL_SECRET
    finally:
        server.shutdown()
        server.server_close()


def test_a_query_string_survives_the_strip(upstream: int, token_file: Path) -> None:
    prov = reverse_provider(upstream)
    routes = {"dfs": proxy.Route("dfs", prov, credential.Credential("dfs", prov, str(token_file)))}
    server = listen(proxy.make_mux_handler(routes))
    try:
        post(int(server.server_address[1]), "/mcp/dfs/v1/x?a=1&b=2")
        assert _Upstream.seen["path"] == "/v1/x?a=1&b=2"
    finally:
        server.shutdown()
        server.server_close()


def test_each_route_on_the_shared_listener_gets_its_own_credential(
    upstream: int, tmp_path: Path
) -> None:
    """The whole risk of one socket for N upstreams: never inject route A's key into B."""
    routes = {}
    for name, secret in (("a", "SECRET-A"), ("b", "SECRET-B")):
        tok = tmp_path / f"{name}-token"
        tok.write_text(secret + "\n")
        prov = reverse_provider(upstream)
        routes[name] = proxy.Route(name, prov, credential.Credential(name, prov, str(tok)))
    server = listen(proxy.make_mux_handler(routes))
    try:
        port = int(server.server_address[1])
        post(port, "/mcp/a/x")
        assert _Upstream.seen["auth"] == "Bearer SECRET-A"
        post(port, "/mcp/b/x")
        assert _Upstream.seen["auth"] == "Bearer SECRET-B"
    finally:
        server.shutdown()
        server.server_close()


def test_one_dead_credential_does_not_take_the_other_route_down(
    upstream: int, tmp_path: Path
) -> None:
    """Fail-soft has to hold per REQUEST too, not just at bind time."""
    live, dead = tmp_path / "live", tmp_path / "dead"
    live.write_text(REAL_SECRET + "\n")
    dead.write_text("")
    routes = {}
    for name, tok in (("live", live), ("dead", dead)):
        prov = reverse_provider(upstream)
        routes[name] = proxy.Route(name, prov, credential.Credential(name, prov, str(tok)))
    server = listen(proxy.make_mux_handler(routes))
    try:
        port = int(server.server_address[1])
        assert post(port, "/mcp/dead/x")[0] == 502
        assert post(port, "/mcp/live/x")[0] == 200
    finally:
        server.shutdown()
        server.server_close()


@pytest.mark.parametrize("path", ["/mcp/ghost/x", "/mcp/", "/v1/messages", "/mcpx/dfs"])
def test_an_unknown_prefix_is_a_404_that_names_no_other_route(
    upstream: int, token_file: Path, path: str
) -> None:
    prov = reverse_provider(upstream)
    routes = {"dfs": proxy.Route("dfs", prov, credential.Credential("dfs", prov, str(token_file)))}
    server = listen(proxy.make_mux_handler(routes))
    try:
        status, body = post(int(server.server_address[1]), path)
        assert status == 404
        assert "dfs" not in body
    finally:
        server.shutdown()
        server.server_close()


# ── fail-soft: a bad route is named, not fatal ───────────────────
def build(enabled: list[str], tokens: dict[str, str], out: Path) -> Any:
    return proxy._build_routes({"enabled": enabled, "token_paths": tokens}, str(out))


def test_a_route_with_no_credential_is_broken_not_raised(
    providers_dir: Path, tmp_path: Path, token_file: Path
) -> None:
    user_def(providers_dir, "acme")
    registry.merge_user_providers()
    llm, mux, broken = build(
        ["claude", "acme"], {"claude": str(token_file), "acme": "/nope"}, tmp_path
    )
    assert [r.pid for r in llm] == ["claude"] and mux == {}
    assert broken == [("acme", "its credential is missing")]


def test_only_claude_is_fail_hard() -> None:
    """A user MCP that cannot come up must never cost the user their session."""
    assert proxy.FAIL_HARD_ROUTES == ("claude",)


def test_bind_returns_none_instead_of_raising(upstream: int, token_file: Path) -> None:
    """The unguarded bind is what turned one duplicated port into an aborted launch."""
    prov = reverse_provider(upstream)
    handler = proxy.make_handler(
        proxy.Route("x", prov, credential.Credential("x", prov, str(token_file)))
    )
    taken = listen(handler)
    try:
        assert proxy._bind(int(taken.server_address[1]), handler, "x") is None
    finally:
        taken.shutdown()
        taken.server_close()


def test_broken_names_every_skipped_route(tmp_path: Path) -> None:
    proxy._write_broken(str(tmp_path), [("acme", "its credential is missing")])
    assert (tmp_path / "broken").read_text() == "acme its credential is missing\n"


def test_broken_is_written_before_ready() -> None:
    """The host reads `broken` only after `ready`, so this order is what makes it complete."""
    src = inspect.getsource(proxy.serve)
    assert src.index("_write_broken(") < src.index('"ready"'), "ready would land first"


# ── the host-facing output contracts bash parses ─────────────────
def test_host_config_shell_quotes_a_multiword_value(
    providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Unquoted, `KIB_BROKER_HOST_RUN=uvx mcp-search-console` would eval as `VAR=uvx cmd`."""
    (providers_dir / "hosted.json").write_text(
        json.dumps(
            {
                "id": "hosted",
                "delivery": "hosted_mcp",
                "host_run": ["uvx", "mcp-search-console"],
                "credential_env": "HT_CRED",
            }
        )
    )
    registry.merge_user_providers()
    broker_cli.host_config("hosted")
    assert "KIB_BROKER_HOST_RUN='uvx mcp-search-console'" in capsys.readouterr().out


def test_host_config_gives_bash_the_route_path_not_a_port(
    providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    user_def(providers_dir, "acme", mcp_path="/http")
    registry.merge_user_providers()
    broker_cli.host_config("acme")
    out = capsys.readouterr().out
    assert "KIB_BROKER_MCP_URL_PATH=/mcp/acme/http" in out
    assert "KIB_BROKER_MCP_PORT=8100" in out
    assert "KIB_BROKER_LISTEN_PORT=''" in out


def test_list_providers_is_one_safe_line_per_route(capsys: pytest.CaptureFixture[str]) -> None:
    broker_cli.list_providers()
    for line in capsys.readouterr().out.splitlines():
        assert line.count("|") == 3
        assert " " not in line, "a field with a space would break POSIX word-splitting"


# ── the shared secret-shape helpers ──────────────────────────────
def test_find_auth_header_picks_the_auth_header_not_the_first() -> None:
    assert helpers.find_auth_header(["Accept: application/json", "Authorization: Bearer xyz"]) == (
        "Authorization",
        "Bearer xyz",
    )


def test_find_auth_header_accepts_tuples() -> None:
    assert helpers.find_auth_header(
        [("Accept", "application/json"), ("X-API-Key", "abc123def456ghi789")]
    ) == ("X-API-Key", "abc123def456ghi789")


def test_find_auth_header_returns_none_when_absent() -> None:
    assert helpers.find_auth_header(["Accept: application/json"]) == (None, None)


@pytest.mark.parametrize(
    ("kv", "secret"),
    [
        ("DATAFORSEO_PASSWORD=hunter2", True),
        ("BASIC_AUTH=x", True),  # AUTH-named keys are the case a naive matcher misses
        ("X=sk-ant-abc123", True),
        ("X=" + "a" * 24, True),
        ("REGION=us-east-1", False),
    ],
)
def test_env_is_secret(kv: str, secret: bool) -> None:
    assert helpers.env_is_secret(kv) is secret


def test_is_auth_header_does_not_use_the_base64_heuristic() -> None:
    """'application/json' is valid base64 — it must not read as a credential."""
    assert helpers.is_auth_header("x-api-key", "anything") is True
    assert helpers.is_auth_header("X-Custom", "Basic Zm9v") is True
    assert helpers.is_auth_header("Accept", "application/json") is False


def test_synthesize_reverse_proxy_shape() -> None:
    prov = helpers.synthesize_reverse_proxy(
        "dfs", "https://mcp.dfs.test/http", "Authorization", "Basic", "http"
    )
    assert prov["upstream_origin"] == "https://mcp.dfs.test"
    assert prov["mcp_path"] == "/http"
    assert prov["inject_template"] == "Basic {secret}"
    assert prov["token_basename"] == "dfs-token"
    assert "listen_port" not in prov, "a per-route port is the knob that took a launch down"
    assert "secret" not in json.dumps(prov).lower().replace("{secret}", "")


def test_synthesize_reverse_proxy_rejects_a_non_http_url() -> None:
    with pytest.raises(ValueError, match="http"):
        helpers.synthesize_reverse_proxy("x", "ftp://nope", "Authorization", "Bearer")


def test_scheme_round_trip() -> None:
    assert helpers.scheme_of("Basic Zm9v") == "Basic"
    assert helpers.recover_secret("Basic Zm9v", "Basic") == "Zm9v"
    assert helpers.scheme_of("raw-token") == ""
    assert helpers.recover_secret("raw-token", "") == "raw-token"


def test_store_secret_is_mode_600(tmp_path: Path) -> None:
    dest = helpers.store_secret(str(tmp_path / "kib"), "acme-token", "s3cr3t")
    assert Path(dest).read_text() == "s3cr3t\n"
    assert stat.S_IMODE(os.stat(dest).st_mode) == 0o600


def test_write_provider_def_lands_under_a_700_dir(tmp_path: Path) -> None:
    provdir = tmp_path / "providers.d"
    path = helpers.write_provider_def(str(provdir), "acme", {"id": "acme"})
    assert json.loads(Path(path).read_text())["id"] == "acme"
    assert stat.S_IMODE(provdir.stat().st_mode) == 0o700
