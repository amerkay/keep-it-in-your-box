"""Guest — the broker's read-only view of one route's credential, and placeholder minting.

There is deliberately no write path to any credential in this module; see the package
docstring for the post-mortem of the version that had one. An `oauth` route reads an OAuth
config here and exchanges it (kib/broker/oauth.py) for an access token held ONLY in memory —
the config file itself is never rewritten.
"""

from __future__ import annotations

import json
import os
import threading
import time
from typing import Any

from kib.broker import oauth
from kib.shared.log import stdout_line

# A far-future expiry (ms) baked into the placeholder credential so in-sandbox claude
# regards its token as valid and never tries to refresh or /login — it just sends the
# placeholder to the broker, which swaps in the real token. 2286-11-20 in ms.
FAR_FUTURE_MS = 10_000_000_000_000
FAKE_PREFIX = "fake_value_"  # sandbox-runtime's sentinel shape

#: Minimum seconds between two 401-forced re-mints on one route. See Credential.invalidate.
REMINT_INTERVAL = 30


def fake(prefix: str = "") -> str:
    """A structurally-plausible but obviously-fake token.

    `os.urandom` keeps uuid off the import list; FAKE_PREFIX makes it greppable in a log
    or a leaked transcript.
    """
    return prefix + FAKE_PREFIX + os.urandom(16).hex()


def _ptr_parts(pointer: str) -> list[str]:
    """RFC 6901 JSON pointer, the minimal subset the placeholder templates need."""
    return [p.replace("~1", "/").replace("~0", "~") for p in pointer.strip("/").split("/")]


def json_set(obj: dict[str, Any], pointer: str, value: Any) -> None:
    parts = _ptr_parts(pointer)
    cur = obj
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    cur[parts[-1]] = value


def mint_placeholder(out_path: str, provider: dict[str, Any]) -> bool:
    """Write the fake credential file that SHADOWS the real one inside the container.

    Built from `placeholder_template`, never cloned from the user's real credential: the
    broker has no access to it and must not acquire any. Non-secret fields are plausible
    constants so Claude parses the file exactly as it would the real thing.

    The signature is load-bearing — `tests/broker/test_broker.py` asserts it takes no
    real-credential path, so threading one back in fails the suite.
    """
    template = provider.get("placeholder_template")
    if template is None:
        return False
    data = json.loads(json.dumps(template))  # deep copy
    for ptr in provider.get("placeholder_fake_pointers", []):
        json_set(data, ptr, fake())
    tmp = out_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh)
    os.chmod(tmp, 0o600)  # fake tokens only, but claude warns on a world-readable cred
    os.replace(tmp, out_path)
    return True


class Credential:
    """Read-only view of one route's credential, and the secret the relay should inject.

    The file is cached in memory and re-read only when its mtime/size changes. For a
    `paste_token` route that file IS the secret; for an `oauth` route it is a config, and the
    injected secret is an access token minted from it and cached until just before it expires.
    """

    def __init__(
        self, pid: str, provider: dict[str, Any], token_path: str, out_dir: str = ""
    ) -> None:
        self.pid = pid
        self.provider = provider
        self.path = token_path
        self.out_dir = out_dir
        self.is_oauth = provider.get("credential_kind") == "oauth"
        self.lock = threading.Lock()
        self._stamp: tuple[int, int] | None = None
        self._value: str | None = None
        self._token: str | None = None
        self._expires_at = 0.0
        self._last_forced = 0.0
        self._rotation_warned = False

    def current_secret(self) -> str | None:
        """The secret to inject upstream, or None having already logged why not.

        One lock for the whole path: minting under it serialises a herd of concurrent
        requests into a single exchange, which is what we want on a cold cache.
        """
        with self.lock:
            raw = self._file_locked()
            if raw is None:
                return None
            return self._minted_locked(raw) if self.is_oauth else raw

    def check(self) -> str | None:
        """Why this credential is unusable, or None. Cheap — it never mints.

        Used at route build. Minting here instead would put an HTTPS round trip on the launch
        path and let one transient network blip mark a route broken for the whole life of the
        container; lazily, the same blip is a 502 on one request and self-heals.
        """
        with self.lock:
            raw = self._file_locked()
            if raw is None:
                return "its credential file is missing, empty or unreadable"
            if not self.is_oauth:
                return None
            try:
                cfg = json.loads(raw)
            except ValueError:
                return "its credential file is not valid JSON"
            return oauth.validate_config(cfg)

    def invalidate(self, stale: str) -> None:
        """Drop the cached access token so the next call re-mints, if `stale` is still it.

        The relay calls this on a 401: the upstream has the final say on whether a token is
        good, and can revoke one long before the expiry it advertised. Gated twice, because a
        401 does NOT always mean the token is dead — a request outside the granted scopes
        401/403s forever, and ungated that would re-mint on every request:

          * `stale` must still be the cached token, so a burst of concurrent 401s costs one
            mint rather than one each;
          * and no more than one forced mint per REMINT_INTERVAL, so a sequential loop of bad
            requests cannot walk the token endpoint into a rate limit — which would take the
            route down for the requests that *are* valid.
        """
        if not self.is_oauth:
            return
        with self.lock:
            now = time.time()
            if self._token != stale or now - self._last_forced < REMINT_INTERVAL:
                return
            self._last_forced = now
            self._token, self._expires_at = None, 0.0

    # ── internals: every one of these runs with self.lock held ──────────────
    def _file_locked(self) -> str | None:
        try:
            st = os.stat(self.path)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError as e:
            stdout_line(f"BROKER-ERR {self.pid} credential file unreadable: {e.strerror}")
            return None
        if stamp != self._stamp:
            try:
                with open(self.path) as fh:
                    value = fh.read().strip()
            except OSError as e:
                stdout_line(f"BROKER-ERR {self.pid} credential file unreadable: {e.strerror}")
                return None
            if not value:
                stdout_line(f"BROKER-ERR {self.pid} credential file is empty")
                return None
            # A replaced config invalidates the token minted from the old one.
            self._value, self._stamp = value, stamp
            self._token, self._expires_at = None, 0.0
        return self._value

    def _minted_locked(self, raw: str) -> str | None:
        if self._token and time.time() < self._expires_at:
            return self._token
        try:
            cfg = json.loads(raw)
        except ValueError:
            return self._mint_failed("the credential file is not valid JSON")
        try:
            token, lifetime, rotated = oauth.mint(cfg, self.provider.get("scopes", []))
        except oauth.OAuthError as e:
            return self._mint_failed(str(e))

        if rotated and not self._rotation_warned:
            # Once per process: a rotating provider would otherwise page the user on every
            # mint. Discarding is deliberate — see kib/broker/oauth.py.
            self._rotation_warned = True
            stdout_line(
                f"BROKER-ERR {self.pid} the token endpoint returned a rotated refresh_token; "
                "it was DISCARDED (the broker never writes a credential). This route will stop "
                "working when the provider invalidates the stored one — re-run kib broker login."
            )
        self._token = token
        # Floor the skew at half the lifetime: a provider issuing a token that lives 60s would
        # otherwise cache it for 0s and re-mint on EVERY request, each under this lock.
        self._expires_at = time.time() + max(lifetime - oauth.EXPIRY_SKEW, lifetime // 2)
        self._write_state(cfg.get("type", ""), "ok")
        return token

    def _mint_failed(self, why: str) -> str | None:
        """Breadcrumb + publish the failure, and hand back the None the caller returns.

        The BROKER-ERR prefix is what the desktop notifier tails, so a route that stops
        minting pages the user instead of silently 502ing.
        """
        stdout_line(f"BROKER-ERR {self.pid} could not mint an access token: {why}")
        self._write_state("", why)
        return None

    def _write_state(self, grant: str, outcome: str) -> None:
        """Publish non-secret mint state for `kib broker status`. NEVER the token.

        Best-effort: this is a diagnostic, and failing to write it must not fail a request.
        """
        if not self.out_dir:
            return
        state = {
            "grant": grant,
            "scopes": self.provider.get("scopes", []),
            "expires_at": int(self._expires_at),
            "last_mint": outcome,
        }
        try:
            path = os.path.join(self.out_dir, f"{self.pid}.oauth")
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(state, fh)
            os.replace(tmp, path)
        except OSError:
            pass
