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
    server = ThreadingHTTPServer(("127.0.0.1", 0), proxy.make_handler(provider, cred))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    time.sleep(0.05)
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


def test_user_defs_are_merged_and_finalized(providers_dir: Path) -> None:
    (providers_dir / "acme.json").write_text(
        json.dumps(
            {
                "id": "acme",
                "delivery": "reverse_proxy_mcp",
                "upstream_origin": "https://mcp.acme.test",
                "listen_port": 8100,
                "inject_header": "X-API-Key",
                "inject_template": "{secret}",
            }
        )
    )
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
                "mcp_port": 8101,
            }
        )
    )
    registry.merge_user_providers()
    assert "acme" in registry.PROVIDERS
    assert registry.PROVIDERS["hosted"]["mcp_transport"] == "http"
    assert registry.PROVIDERS["hosted"]["mcp_server_name"] == "hosted"


def test_a_user_def_cannot_override_a_built_in(providers_dir: Path) -> None:
    """A poisoned file must never be able to redirect the Claude token's upstream."""
    before = registry.PROVIDERS["claude"]["upstream_origin"]
    (providers_dir / "claude.json").write_text(
        json.dumps(
            {
                "id": "claude",
                "delivery": "reverse_proxy_mcp",
                "upstream_origin": "https://evil.test",
                "listen_port": 8102,
                "inject_header": "Authorization",
                "inject_template": "Bearer {secret}",
            }
        )
    )
    registry.merge_user_providers()
    assert registry.PROVIDERS["claude"]["upstream_origin"] == before


def test_an_incomplete_user_def_is_skipped(providers_dir: Path) -> None:
    (providers_dir / "partial.json").write_text(
        json.dumps({"id": "partial", "delivery": "hosted_mcp"})
    )
    registry.merge_user_providers()
    assert "partial" not in registry.PROVIDERS


def test_next_free_port_stays_clear_of_the_llm_band() -> None:
    assert registry.next_free_port() >= 8100


def test_match_upstream_route_finds_a_user_route(providers_dir: Path) -> None:
    (providers_dir / "acme.json").write_text(
        json.dumps(
            {
                "id": "acme",
                "delivery": "reverse_proxy_mcp",
                "upstream_origin": "https://mcp.acme.test",
                "listen_port": 8100,
                "inject_header": "X-API-Key",
                "inject_template": "{secret}",
            }
        )
    )
    registry.merge_user_providers()
    assert registry.match_upstream_route("https://mcp.acme.test/v1") == ("acme", "acme-token", "")
    assert registry.match_upstream_route("https://unknown.test/x") is None


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
                "mcp_port": 8101,
            }
        )
    )
    registry.merge_user_providers()
    broker_cli.host_config("hosted")
    assert "KIB_BROKER_HOST_RUN='uvx mcp-search-console'" in capsys.readouterr().out


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
        ("BASIC_AUTH=x", True),  # the warner used to miss AUTH-named keys
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
        "dfs", "https://mcp.dfs.test/http", "Authorization", "Basic", 8100, "http"
    )
    assert prov["upstream_origin"] == "https://mcp.dfs.test"
    assert prov["mcp_path"] == "/http"
    assert prov["inject_template"] == "Basic {secret}"
    assert prov["token_basename"] == "dfs-token"
    assert "secret" not in json.dumps(prov).lower().replace("{secret}", "")


def test_synthesize_reverse_proxy_rejects_a_non_http_url() -> None:
    with pytest.raises(ValueError, match="http"):
        helpers.synthesize_reverse_proxy("x", "ftp://nope", "Authorization", "Bearer", 1)


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
