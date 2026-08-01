"""Guest — OAuth 2.0 token minting. The ONE place the broker talks to a token endpoint.

A route whose `credential_kind` is `oauth` stores an OAuth *config* host-side instead of a
ready-made secret; this module exchanges it for a short-lived access token that `Credential`
caches in memory and the relay injects like any other. The config never leaves the sidecar.

── WHY THIS IS ALLOWED TO EXIST, AND WHAT IT STILL MAY NOT DO ────────────────
Minting is not the thing that logged the account out. WRITING a credential was: Anthropic
subscription refresh tokens are single-use and rotating, so persisting a rotated one
invalidates the family for every other holder. Two rules keep that impossible here:

  1. Nothing in this module writes to the credential file, or anywhere else. The minted token
     is a return value; only `Credential` holds it, only in memory.
  2. A `refresh_token` in a token response is DISCARDED and reported (`rotated`). A provider
     that rotates will eventually fail visibly at mint time rather than silently taking the
     user's other sessions down with it.

The LLM row is `paste_token` and can never reach this module — guarded in tests.

`cryptography` is imported LAZILY inside `_sign_rs256`: `kib/broker/*` must import on python
3.9 / stock macOS (CONVENTIONS.md) where it does not exist, and only the service-account grant
needs it. A module-level import would break `kib broker status` on the host.
"""

from __future__ import annotations

import base64
import http.client
import json
import ssl
import time
import urllib.parse
from collections.abc import Sequence
from typing import Any

#: Google's endpoint, the default for both shapes `gcloud` writes. A config may override it.
GOOGLE_TOKEN_URI = "https://oauth2.googleapis.com/token"
JWT_BEARER = "urn:ietf:params:oauth:grant-type:jwt-bearer"

#: Recognised config shapes → the keys each grant cannot run without. `type` is the Google ADC
#: discriminator, reused verbatim so a `gcloud auth application-default login` file works as-is;
#: `client_credentials` is kib's own shape for a generic OAuth service.
REQUIRED_KEYS: dict[str, tuple[str, ...]] = {
    "authorized_user": ("client_id", "client_secret", "refresh_token"),
    "service_account": ("client_email", "private_key"),
    "client_credentials": ("client_id", "client_secret", "token_uri"),
}

#: Re-mint this many seconds before the stated expiry, so a token never expires mid-flight.
EXPIRY_SKEW = 120

#: How long a service-account assertion claims to be valid. Google caps it at one hour.
_JWT_LIFETIME = 3600


class OAuthError(Exception):
    """A mint failed. The message is safe to log — it never carries credential bytes.

    `retryable` separates "we could not tell" (network, rate limit, upstream 5xx) from "this
    credential is bad", so `kib broker probe` can keep its tri-state contract instead of
    reporting a flaky network as a rejected credential.
    """

    def __init__(self, message: str, retryable: bool = False) -> None:
        super().__init__(message)
        self.retryable = retryable


def validate_config(cfg: Any) -> str | None:
    """The reason this OAuth config is unusable, or None if it can mint.

    Shared by the host (`kib broker login`, before storing) and the sidecar (at route build),
    so a credential that logs in cannot then be refused at launch for a different reason.
    """
    if not isinstance(cfg, dict):
        return "the credential file must be a JSON object"
    kind = cfg.get("type")
    if kind not in REQUIRED_KEYS:
        return f'"type" is {kind!r} — expected one of {tuple(REQUIRED_KEYS)}'
    missing = [k for k in REQUIRED_KEYS[kind] if not cfg.get(k)]
    if missing:
        return f"a {kind} config is missing: {', '.join(missing)}"
    return None


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _sign_rs256(signing_input: bytes, private_key_pem: str) -> bytes:
    """RS256 signature. Imports `cryptography` lazily — see the module docstring."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    signed: bytes = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    return signed


def _assertion(cfg: dict[str, Any], scopes: Sequence[str], token_uri: str) -> str:
    """A signed JWT asserting this service account, for the jwt-bearer grant."""
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": cfg["client_email"],
        "scope": " ".join(scopes),
        "aud": token_uri,
        "iat": now,
        "exp": now + _JWT_LIFETIME,
    }
    # A subject to impersonate, for domain-wide delegation. Absent for an ordinary key.
    if cfg.get("subject"):
        claims["sub"] = cfg["subject"]
    signing_input = f"{_b64url(json.dumps(header).encode())}.{_b64url(json.dumps(claims).encode())}"
    return f"{signing_input}.{_b64url(_sign_rs256(signing_input.encode(), cfg['private_key']))}"


def _post_form(token_uri: str, fields: dict[str, str]) -> dict[str, Any]:
    """POST a form-encoded grant and return the parsed JSON. Raises OAuthError."""
    u = urllib.parse.urlsplit(token_uri)
    if u.scheme != "https" or not u.hostname:
        raise OAuthError(f"token_uri must be an https URL, got {token_uri!r}")
    conn = http.client.HTTPSConnection(
        u.hostname, u.port or 443, context=ssl.create_default_context(), timeout=30
    )
    try:
        conn.request(
            "POST",
            urllib.parse.urlunsplit(("", "", u.path or "/", u.query, "")),
            body=urllib.parse.urlencode(fields).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        resp = conn.getresponse()
        status, raw = resp.status, resp.read(65536)
    except OSError as e:
        raise OAuthError(f"could not reach {u.hostname}: {type(e).__name__}", True) from e
    finally:
        conn.close()

    # 429 and 5xx say nothing about the credential; 4xx does.
    retryable = status == 429 or status >= 500
    try:
        data = json.loads(raw)
    except ValueError as e:
        raise OAuthError(f"{u.hostname} answered HTTP {status} with non-JSON", retryable) from e
    if status != 200 or not isinstance(data, dict):
        # Only the two standard error fields are surfaced. The full body is never logged: it
        # is attacker-influenced text heading for a log the notifier tails.
        detail = ""
        if isinstance(data, dict):
            detail = f": {data.get('error', '')} {data.get('error_description', '')}".rstrip()
        raise OAuthError(f"{u.hostname} refused the grant (HTTP {status}){detail}", retryable)
    return data


def mint(cfg: dict[str, Any], scopes: Sequence[str]) -> tuple[str, int, bool]:
    """Exchange an OAuth config for `(access_token, lifetime_seconds, rotated)`.

    `rotated` is True when the response carried a `refresh_token` — which this DISCARDS. The
    caller reports it; persisting it is the incident this module's docstring describes.
    """
    bad = validate_config(cfg)
    if bad:
        raise OAuthError(bad)
    kind = cfg["type"]
    token_uri = str(cfg.get("token_uri") or GOOGLE_TOKEN_URI)

    if kind == "authorized_user":
        # Scopes are fixed at CONSENT time for this grant — Google ignores a narrowing `scope`
        # here — so the route's `scopes` are documentation, not enforcement. See the README.
        fields = {
            "grant_type": "refresh_token",
            "client_id": cfg["client_id"],
            "client_secret": cfg["client_secret"],
            "refresh_token": cfg["refresh_token"],
        }
    elif kind == "service_account":
        fields = {"grant_type": JWT_BEARER, "assertion": _assertion(cfg, scopes, token_uri)}
    else:  # client_credentials — validate_config already refused anything else
        fields = {
            "grant_type": "client_credentials",
            "client_id": cfg["client_id"],
            "client_secret": cfg["client_secret"],
        }
        if scopes:
            fields["scope"] = " ".join(scopes)

    data = _post_form(token_uri, fields)
    token = data.get("access_token")
    if not token or not isinstance(token, str):
        raise OAuthError("the token endpoint returned no access_token")
    try:
        lifetime = int(data.get("expires_in", _JWT_LIFETIME))
    except (TypeError, ValueError):
        lifetime = _JWT_LIFETIME
    return token, lifetime, bool(data.get("refresh_token"))
