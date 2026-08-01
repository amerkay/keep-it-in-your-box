"""The MCP paths — the newly-extracted heredocs, one of which handles live credentials.

This is the suite that owes the most: ~380 lines of Python that ran unlinted inside bash for
its whole life. The interceptor especially — it is the only thing standing between a pasted
`kib claude mcp add --header "Authorization: …"` and a secret in the container's argv.

Nothing here writes outside tmp_path, and no assertion prints a secret it did not put there.
"""

import json
import stat
from collections.abc import Callable
from pathlib import Path

import pytest

from kib.host import mcp
from kib.shared import cli


def kib_dir(tmp_path: Path) -> Path:
    d = tmp_path / "kib"
    d.mkdir(exist_ok=True)
    return d


def remote_def(name: str, host: str = "mcp.example.test", path: str = "/http") -> str:
    return json.dumps(
        {
            "id": name,
            "delivery": "reverse_proxy_mcp",
            "upstream_origin": f"https://{host}",
            "inject_header": "Authorization",
            "inject_template": "Bearer {secret}",
            "mcp_path": path,
            "mcp_server_name": name,
        }
    )


# ── inject ───────────────────────────────────────────────────────
def test_inject_writes_a_header_free_broker_url(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    (providers_dir / "remote.json").write_text(remote_def("remote"))
    (kib_dir(tmp_path) / "remote-token").write_text("tok\n")
    cfg = write_json("session/.claude.json", {})

    assert (
        mcp.main(
            [
                "inject",
                "--config",
                str(cfg),
                "--kib-dir",
                str(kib_dir(tmp_path)),
                "--broker-host",
                "kib-broker",
            ]
        )
        == cli.OK
    )
    entry = json.loads(cfg.read_text())["mcpServers"]["remote"]
    assert entry["url"] == "http://kib-broker:8100/mcp/remote/http"
    assert entry[mcp.MARKER] is True
    assert "headers" not in entry


def test_inject_skips_a_route_with_no_credential(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    (providers_dir / "remote.json").write_text(remote_def("remote"))
    cfg = write_json("session/.claude.json", {})
    mcp.main(
        ["inject", "--config", str(cfg), "--kib-dir", str(kib_dir(tmp_path)), "--broker-host", "b"]
    )
    assert json.loads(cfg.read_text())["mcpServers"] == {}


def test_inject_points_a_hosted_mcp_at_its_own_sidecar_only_if_it_came_up(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    (providers_dir / "local.json").write_text(
        json.dumps(
            {
                "id": "local",
                "delivery": "hosted_mcp",
                "host_run": ["uvx", "some-mcp"],
                "credential_env": "L_CRED",
                "mcp_path": "/mcp",
            }
        )
    )
    cfg = write_json("session/.claude.json", {})
    base = [
        "inject",
        "--config",
        str(cfg),
        "--kib-dir",
        str(kib_dir(tmp_path)),
        "--broker-host",
        "b",
    ]

    mcp.main(base)
    assert json.loads(cfg.read_text())["mcpServers"] == {}

    mcp.main([*base, "--hosted-up", "local"])
    assert json.loads(cfg.read_text())["mcpServers"]["local"]["url"] == "http://local:8100/mcp"


def test_inject_prunes_only_entries_we_own(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    """A user-authored server survives; every entry carrying our marker is dropped."""
    cfg = write_json(
        "session/.claude.json",
        {
            "mcpServers": {
                "mine": {"type": "http", "url": "http://user"},
                "current": {mcp.MARKER: True, "url": "STALE_NEW"},
            }
        },
    )
    mcp.main(
        ["inject", "--config", str(cfg), "--kib-dir", str(kib_dir(tmp_path)), "--broker-host", "b"]
    )
    assert list(json.loads(cfg.read_text())["mcpServers"]) == ["mine"]


def test_inject_leaves_unrelated_top_level_keys_alone(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    cfg = write_json("session/.claude.json", {"onboardingComplete": True})
    mcp.main(
        ["inject", "--config", str(cfg), "--kib-dir", str(kib_dir(tmp_path)), "--broker-host", "b"]
    )
    assert json.loads(cfg.read_text())["onboardingComplete"] is True


# ── warn ─────────────────────────────────────────────────────────
def test_warn_names_the_server_and_reason_but_never_the_value(
    write_json: Callable[[str, object], Path], capsys: pytest.CaptureFixture[str]
) -> None:
    cfg = write_json(
        ".mcp.json",
        {
            "mcpServers": {
                "dfs": {"url": "https://x", "headers": {"Authorization": "Basic SEKRIT99"}}
            }
        },
    )
    mcp.main(["warn", "--claude-json", str(cfg)])
    err = capsys.readouterr().err
    assert "dfs" in err and "inline auth header" in err and "kib mcp adopt dfs" in err
    assert "SEKRIT99" not in err


def test_warn_flags_an_env_secret_by_key_name(
    write_json: Callable[[str, object], Path], capsys: pytest.CaptureFixture[str]
) -> None:
    cfg = write_json(".mcp.json", {"mcpServers": {"loc": {"env": {"BASIC_AUTH": "x"}}}})
    mcp.main(["warn", "--claude-json", str(cfg)])
    assert "inline env secret (BASIC_AUTH)" in capsys.readouterr().err


def test_warn_ignores_our_own_brokered_entries(
    write_json: Callable[[str, object], Path], capsys: pytest.CaptureFixture[str]
) -> None:
    cfg = write_json(
        ".mcp.json",
        {"mcpServers": {"ours": {mcp.MARKER: True, "headers": {"Authorization": "Bearer x"}}}},
    )
    mcp.main(["warn", "--claude-json", str(cfg)])
    assert capsys.readouterr().err == ""


def test_warn_survives_a_missing_or_corrupt_config(tmp_path: Path) -> None:
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    assert mcp.main(["warn", "--claude-json", str(bad)]) == cli.OK
    assert mcp.main(["warn", "--claude-json", str(tmp_path / "absent.json")]) == cli.OK


# ── adopt ────────────────────────────────────────────────────────
def adopt_argv(tmp_path: Path, providers_dir: Path, name: str, cfg: Path) -> list[str]:
    return [
        "adopt",
        name,
        "--kib-dir",
        str(kib_dir(tmp_path)),
        "--providers-dir",
        str(providers_dir),
        "--claude-json",
        str(cfg),
    ]


def test_adopt_reuses_an_existing_route_for_the_same_host(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    (providers_dir / "svc.json").write_text(remote_def("svc", host="api.svc.test"))
    cfg = write_json(
        ".mcp.json",
        {
            "mcpServers": {
                "svc2": {
                    "type": "http",
                    "url": "https://api.svc.test/mcp",
                    "headers": {"Authorization": "Bearer TOK123"},
                }
            }
        },
    )
    assert mcp.main(adopt_argv(tmp_path, providers_dir, "svc2", cfg)) == cli.OK

    assert not (providers_dir / "svc2.json").exists(), "adopt synthesized a duplicate route"
    token = kib_dir(tmp_path) / "svc-token"
    assert token.read_text() == "TOK123\n"
    assert stat.S_IMODE(token.stat().st_mode) == 0o600
    assert "svc2" not in json.loads(cfg.read_text())["mcpServers"]


def test_adopt_synthesizes_a_route_for_an_unknown_host(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    """This is what makes adoption generic — no MCP is built in, so most hosts are unknown."""
    cfg = write_json(
        ".mcp.json",
        {
            "mcpServers": {
                "acme": {
                    "type": "http",
                    "url": "https://mcp.acme.test/v1/sse",
                    "headers": {"X-API-Key": "AK_LIVE_9"},
                }
            }
        },
    )
    assert mcp.main(adopt_argv(tmp_path, providers_dir, "acme", cfg)) == cli.OK
    prov = json.loads((providers_dir / "acme.json").read_text())
    assert prov["upstream_origin"] == "https://mcp.acme.test"
    assert "listen_port" not in prov, "a user route must not carry a port of its own"
    assert (kib_dir(tmp_path) / "acme-token").read_text() == "AK_LIVE_9\n"


def test_adopt_preserves_the_project_files_mode(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    """`.mcp.json` is a project file, often committed — adopt must not silently make it 0600."""
    cfg = write_json(
        ".mcp.json",
        {
            "mcpServers": {
                "svc": {
                    "type": "http",
                    "url": "https://api.svc.test/mcp",
                    "headers": {"Authorization": "Bearer TOK"},
                }
            }
        },
    )
    cfg.chmod(0o644)
    mcp.main(adopt_argv(tmp_path, providers_dir, "svc", cfg))
    assert stat.S_IMODE(cfg.stat().st_mode) == 0o644


def test_adopt_refuses_an_unknown_server(tmp_path: Path, providers_dir: Path) -> None:
    cfg = tmp_path / "empty.json"
    cfg.write_text("{}")
    with pytest.raises(cli.AbortError, match="no MCP named"):
        mcp.main(adopt_argv(tmp_path, providers_dir, "ghost", cfg))


def test_adopt_refuses_a_local_server_with_no_auth_header(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    cfg = write_json(".mcp.json", {"mcpServers": {"loc": {"command": "npx", "args": []}}})
    with pytest.raises(cli.AbortError, match="hosted_mcp definition"):
        mcp.main(adopt_argv(tmp_path, providers_dir, "loc", cfg))


def test_adopt_refuses_an_already_brokered_entry(
    tmp_path: Path, providers_dir: Path, write_json: Callable[[str, object], Path]
) -> None:
    cfg = write_json(".mcp.json", {"mcpServers": {"x": {mcp.MARKER: True, "url": "http://b"}}})
    with pytest.raises(cli.AbortError, match="already a brokered entry"):
        mcp.main(adopt_argv(tmp_path, providers_dir, "x", cfg))


# ── add ──────────────────────────────────────────────────────────
def test_add_writes_a_reverse_proxy_def(providers_dir: Path) -> None:
    assert (
        mcp.main(
            [
                "add",
                "svc",
                "--providers-dir",
                str(providers_dir),
                "--url",
                "https://api.svc.test/mcp",
                "--header",
                "X-Key: ",
            ]
        )
        == cli.OK
    )
    prov = json.loads((providers_dir / "svc.json").read_text())
    assert prov["delivery"] == "reverse_proxy_mcp"
    assert prov["inject_header"] == "X-Key"
    assert prov["inject_template"] == "{secret}"


def test_add_writes_a_hosted_def_with_extra_env(providers_dir: Path) -> None:
    assert (
        mcp.main(
            [
                "add",
                "gsc",
                "--providers-dir",
                str(providers_dir),
                "--run",
                "uvx mcp-search-console",
                "--cred-env",
                "GSC_CRED",
                "--cred-kind",
                "file",
                "--env",
                "FLAG=true",
            ]
        )
        == cli.OK
    )
    prov = json.loads((providers_dir / "gsc.json").read_text())
    assert prov["delivery"] == "hosted_mcp"
    assert prov["host_run"] == ["uvx", "mcp-search-console"]
    assert prov["credential_kind"] == "file_path"
    assert prov["token_basename"] == "gsc.json"
    assert prov["extra_env"] == {"FLAG": "true"}


@pytest.mark.parametrize(
    ("argv", "match"),
    [
        (["--url", "https://x", "--run", "cmd"], "not both"),
        (["--url", "https://x", "--env", "A=B"], "only applies to a hosted MCP"),
        (["--run", "cmd"], "needs --cred-env"),
        ([], "give --url"),
        (["--run", "cmd", "--cred-env", "E", "--env", "novalue"], "KEY=VAL"),
        (["--url", "ftp://nope"], "http\\(s\\) URL"),
    ],
)
def test_add_rejects_bad_argument_combinations(
    providers_dir: Path, argv: list[str], match: str
) -> None:
    with pytest.raises(cli.AbortError, match=match) as exc:
        mcp.main(["add", "x", "--providers-dir", str(providers_dir), *argv])
    assert exc.value.code == cli.USAGE


@pytest.mark.parametrize(
    ("name", "match"),
    [
        ("../escape", "usable route name"),
        ("Acme", "usable route name"),
        ("has space", "usable route name"),
        ("claude", "built-in"),
    ],
)
def test_add_refuses_a_name_that_is_not_a_safe_route(
    providers_dir: Path, name: str, match: str
) -> None:
    """The name is a filename stem, a URL path segment AND a word-split bash field."""
    with pytest.raises(cli.AbortError, match=match) as exc:
        mcp.main(["add", name, "--providers-dir", str(providers_dir), "--url", "https://x.test"])
    assert exc.value.code == cli.REFUSED
    assert list(providers_dir.iterdir()) == [], "a refused name still touched providers.d"


def test_add_refuses_to_silently_replace_an_existing_route(providers_dir: Path) -> None:
    argv = ["add", "svc", "--providers-dir", str(providers_dir), "--url", "https://a.test"]
    assert mcp.main(argv) == cli.OK
    with pytest.raises(cli.AbortError, match="already exists"):
        mcp.main([*argv[:-1], "https://b.test"])
    assert (
        json.loads((providers_dir / "svc.json").read_text())["upstream_origin"] == "https://a.test"
    )
    assert mcp.main([*argv[:-1], "https://b.test", "--force"]) == cli.OK
    assert (
        json.loads((providers_dir / "svc.json").read_text())["upstream_origin"] == "https://b.test"
    )


# ── intercept ────────────────────────────────────────────────────
def intercept(tmp_path: Path, providers_dir: Path, *argv: str, allow: bool = False) -> int:
    flags = ["--allow"] if allow else []
    return mcp.main(
        [
            "intercept",
            "--kib-dir",
            str(kib_dir(tmp_path)),
            "--providers-dir",
            str(providers_dir),
            *flags,
            "--",
            *argv,
        ]
    )


def test_intercept_brokers_a_remote_header_form(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    intercept(
        tmp_path,
        providers_dir,
        "claude",
        "mcp",
        "add",
        "--header",
        "Authorization: Basic Zm9vOmJhcg==",
        "--transport",
        "http",
        "dfs",
        "https://mcp.dfs.test/http",
    )
    out = capsys.readouterr()
    assert out.out.strip() == "brokered"
    assert "Zm9vOmJhcg==" not in out.err, "the interceptor echoed the secret it was hiding"
    token = kib_dir(tmp_path) / "dfs-token"
    assert token.read_text() == "Zm9vOmJhcg==\n"
    assert stat.S_IMODE(token.stat().st_mode) == 0o600
    assert (providers_dir / "dfs.json").exists()


def test_intercept_picks_the_auth_header_even_when_it_is_not_first(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The old code took headers[0] and brokered a MIME type."""
    intercept(
        tmp_path,
        providers_dir,
        "mcp",
        "add",
        "--header",
        "Accept: application/json",
        "--header",
        "Authorization: Basic Zm9vOmJhcg==",
        "--transport",
        "http",
        "nf",
        "https://mcp.dfs.test/http",
    )
    assert capsys.readouterr().out.strip() == "brokered"
    assert (kib_dir(tmp_path) / "nf-token").read_text() == "Zm9vOmJhcg==\n"


def test_intercept_blocks_a_local_env_secret(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    intercept(
        tmp_path, providers_dir, "mcp", "add", "loc", "--env", "DFS_PASSWORD=hunter2", "--", "npx"
    )
    out = capsys.readouterr()
    assert out.out.strip() == "blocked"
    assert "hunter2" not in out.err


def test_intercept_blocks_an_unbrokerable_auth_header(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """No remote http(s) URL to point a route at — passing it through would leak the secret."""
    intercept(
        tmp_path, providers_dir, "mcp", "add", "nourl", "--header", "Authorization: Bearer sk-x"
    )
    out = capsys.readouterr()
    assert out.out.strip() == "blocked"
    assert "sk-x" not in out.err


def test_intercept_opt_out_falls_through_to_passthrough(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    intercept(
        tmp_path,
        providers_dir,
        "mcp",
        "add",
        "loc",
        "--env",
        "DFS_PASSWORD=hunter2",
        "--",
        "npx",
        allow=True,
    )
    assert capsys.readouterr().out.strip() == "passthrough"


@pytest.mark.parametrize(
    "argv",
    [
        ("mcp", "add", "plain", "https://example.test/mcp", "--transport", "http"),
        ("mcp", "list"),
        ("claude",),
        ("--resume",),
        (),
    ],
)
def test_intercept_passes_through_anything_without_a_secret(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str], argv: tuple[str, ...]
) -> None:
    """The default must never swallow a real session."""
    intercept(tmp_path, providers_dir, *argv)
    assert capsys.readouterr().out.strip() == "passthrough"


def test_intercept_sees_through_repeated_claude_tokens(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """`kib claude claude mcp add …` is a real habit; it must not slip past the gate."""
    intercept(
        tmp_path,
        providers_dir,
        "claude",
        "claude",
        "mcp",
        "add",
        "x",
        "--env",
        "TOKEN=abc",
        "--",
        "npx",
    )
    assert capsys.readouterr().out.strip() == "blocked"


def test_intercept_handles_the_add_json_form(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    blob = json.dumps(
        {"url": "https://mcp.js.test/http", "headers": {"Authorization": "Bearer sk-json"}}
    )
    intercept(tmp_path, providers_dir, "mcp", "add-json", "js", blob)
    assert capsys.readouterr().out.strip() == "brokered"
    assert (kib_dir(tmp_path) / "js-token").read_text() == "sk-json\n"


def test_intercept_updates_the_route_when_a_vendor_line_is_re_pasted(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Unlike `add`, re-pasting a rotated vendor line SHOULD replace what it wrote before."""
    for secret in ("Bearer sk-old", "Bearer sk-new"):
        intercept(
            tmp_path,
            providers_dir,
            "mcp",
            "add",
            "--header",
            f"Authorization: {secret}",
            "--transport",
            "http",
            "dfs",
            "https://mcp.dfs.test/http",
        )
        assert capsys.readouterr().out.strip() == "brokered"
    assert (kib_dir(tmp_path) / "dfs-token").read_text() == "sk-new\n"


def test_intercept_will_not_broker_a_name_that_is_not_a_safe_route(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """It falls through to the block arm — never passthrough, which would leak the secret."""
    intercept(
        tmp_path,
        providers_dir,
        "mcp",
        "add",
        "--header",
        "Authorization: Bearer sk-x",
        "--transport",
        "http",
        "../evil",
        "https://mcp.dfs.test/http",
    )
    out = capsys.readouterr()
    assert out.out.strip() == "blocked"
    assert "sk-x" not in out.err
    assert list(providers_dir.iterdir()) == []


def test_intercept_passes_through_malformed_add_json(
    tmp_path: Path, providers_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Let claude produce its own parse error rather than guessing at the intent."""
    intercept(tmp_path, providers_dir, "mcp", "add-json", "js", "{not json")
    assert capsys.readouterr().out.strip() == "passthrough"
