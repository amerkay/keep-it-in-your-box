#!/usr/bin/env python3
"""Logic tests for cc-broker.py — the credential broker's relay, injection, streaming and
placeholder minting. Pure stdlib, no docker: a fake upstream + an in-process broker instance
prove that the agent's placeholder is stripped, the REAL secret is injected upstream, the
response streams back unbuffered, and the placeholder is synthetic. Run standalone
(`python3 tests/broker-test.py`) or via tests/check.sh.

The regression this suite exists for is the one that logged the account out: the broker must
hold a STATIC token and must never write a credential. `no_write_path` and
`placeholder_is_synthetic` below are the guards — do not relax them to accommodate a
reintroduced refresh loop (see cc-broker.py's docstring for the post-mortem).

Exit status is 0 only if every assertion passes."""
import http.client
import importlib.util
import inspect
import json
import os
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Import cc-broker.py from the repo root (this file lives in tests/).
_BROKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cc-broker.py")
spec = importlib.util.spec_from_file_location("ccbroker", _BROKER)
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

REAL_SECRET = "REAL-sk-ant-oat01-abcdef123456"
seen = {}


# ── fake upstream: records the Authorization it received, streams 3 SSE-ish chunks ──
class Up(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        ln = int(self.headers.get("content-length", 0) or 0)
        seen["body"] = self.rfile.read(ln)
        seen["auth"] = self.headers.get("Authorization")
        seen["xapikey"] = self.headers.get("x-api-key")
        seen["host"] = self.headers.get("Host")
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        for i in range(3):
            self.wfile.write(("data: chunk%d\n\n" % i).encode())
            self.wfile.flush()
            time.sleep(0.02)


up = ThreadingHTTPServer(("127.0.0.1", 0), Up)
up_port = up.server_address[1]
threading.Thread(target=up.serve_forever, daemon=True).start()

# ── the real token: a plain-text file, broker-side only ──
tokf = tempfile.NamedTemporaryFile("w", suffix=".token", delete=False)
tokf.write(REAL_SECRET + "\n")
tokf.close()
os.chmod(tokf.name, 0o600)

provider = {
    "upstream_origin": "http://127.0.0.1:%d" % up_port,
    "inject_header": "Authorization", "inject_template": "Bearer {secret}",
    "strip_incoming": ["authorization", "x-api-key"], "listen_port": 0,
    "placeholder_template": b.PROVIDERS["claude"]["placeholder_template"],
    "placeholder_fake_pointers": b.PROVIDERS["claude"]["placeholder_fake_pointers"],
}
credobj = b.Credential("claude", provider, tokf.name)
broker = ThreadingHTTPServer(("127.0.0.1", 0), b.make_handler(provider, credobj))
br_port = broker.server_address[1]
threading.Thread(target=broker.serve_forever, daemon=True).start()
time.sleep(0.1)

# ── agent sends the PLACEHOLDER, never the real secret ──
c = http.client.HTTPConnection("127.0.0.1", br_port, timeout=10)
c.request("POST", "/v1/messages?beta=true",
          body=b'{"hi":true}',
          headers={"Authorization": "Bearer fake_value_deadbeef",
                   "x-api-key": "fake_value_deadbeef", "content-type": "application/json"})
resp = c.getresponse()
data = resp.read().decode()

# ── placeholder minting (synthetic: takes no real credential as input) ──
ph = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
ph.close()
b.mint_placeholder(ph.name, b.PROVIDERS["claude"])
phd = json.load(open(ph.name))

ok = True


def check(name, cond):
    global ok
    ok = ok and cond
    print(("PASS " if cond else "FAIL ") + name)


def _raises_systemexit(fn):
    try:
        fn()
        return False
    except SystemExit:
        return True


check("upstream received REAL secret", seen.get("auth") == "Bearer " + REAL_SECRET)
check("placeholder auth was stripped (not forwarded)", "fake_value" not in (seen.get("auth") or ""))
check("x-api-key placeholder stripped", seen.get("xapikey") is None)
check("Host set to upstream (agent's Host dropped)",
      seen.get("host") in ("127.0.0.1", "127.0.0.1:%d" % up_port))
check("request body forwarded", seen.get("body") == b'{"hi":true}')
check("response streamed (3 chunks)", data.count("data: chunk") == 3)
check("resp status 200", resp.status == 200)
check("token file trailing newline stripped", credobj.current_secret() == REAL_SECRET)

check("placeholder token is fake", phd["claudeAiOauth"]["accessToken"].startswith("fake_value_"))
check("placeholder refresh token is fake", phd["claudeAiOauth"]["refreshToken"].startswith("fake_value_"))
check("placeholder expiry far-future", phd["claudeAiOauth"]["expiresAt"] == b.FAR_FUTURE_MS)
check("placeholder is mode 600", (os.stat(ph.name).st_mode & 0o777) == 0o600)

# ── REGRESSION GUARDS for the logout bug ──────────────────────────────────────
# 1. mint_placeholder must be synthetic. Its signature takes (out_path, provider) only —
#    if a real-credential path is ever threaded back in, the arity changes and this fails.
sig = list(inspect.signature(b.mint_placeholder).parameters)
check("placeholder_is_synthetic: mint_placeholder takes no real-credential path",
      sig == ["out_path", "provider"])

# 2. No refresh machinery may exist, under any name.
src = open(_BROKER).read()
check("no_refresh_loop: no refresh functions on Credential",
      not any(hasattr(b.Credential, n) for n in
              ("maybe_refresh", "_do_refresh", "_expiry_seconds", "refresh")))
check("no_refresh_loop: module defines no refresh_loop", not hasattr(b, "refresh_loop"))
check("no_refresh_loop: no grant_type=refresh_token anywhere",
      "refresh_token" not in src.replace("refreshToken", ""))

# 3. No write path to a credential. The only writes in the module are the placeholder and
#    the readiness marker, both under out_dir. Assert the token file is never opened for
#    writing, and prove it by permission: a read-only token must still serve requests.
check("no_write_path: token file is never opened for writing",
      'open(self.path, "w' not in src and "open(self.path, 'w" not in src)

os.chmod(tokf.name, 0o400)
c2 = http.client.HTTPConnection("127.0.0.1", br_port, timeout=10)
c2.request("POST", "/v1/messages", body=b'{"x":1}',
           headers={"Authorization": "Bearer fake_value_deadbeef",
                    "content-type": "application/json"})
r2 = c2.getresponse()
r2.read()
check("no_write_path: serves fine with a read-only (0400) token file", r2.status == 200)

# 4. A rotated/replaced token file is picked up without a restart (mtime+size stamp), so a
#    host-side `cc --broker-login` mid-session works.
time.sleep(0.01)
with open(tempfile.gettempdir() + "/_ccb_rot", "w") as fh:
    fh.write("ROTATED-sk-ant-oat01-999999\n")
os.chmod(tokf.name, 0o600)
with open(tokf.name, "w") as fh:
    fh.write("ROTATED-sk-ant-oat01-999999\n")
check("token file re-read after it changes on disk",
      credobj.current_secret() == "ROTATED-sk-ant-oat01-999999")

# 5. An empty token must fail closed — never inject "Bearer None" or "Bearer ".
with open(tokf.name, "w") as fh:
    fh.write("")
check("empty token fails closed (no secret returned)", credobj.current_secret() is None)
c3 = http.client.HTTPConnection("127.0.0.1", br_port, timeout=10)
c3.request("POST", "/v1/messages", body=b'{"x":1}',
           headers={"Authorization": "Bearer fake_value_deadbeef",
                    "content-type": "application/json"})
r3 = c3.getresponse()
r3.read()
check("empty token → 502, request never reaches upstream", r3.status == 502)

# 6. The placeholder token cc injects must be obviously fake and correctly prefixed.
pt = b._fake(b.PROVIDERS["claude"]["token_prefix"])
check("placeholder token is prefixed and fake",
      pt.startswith("sk-ant-oat01-") and b.FAKE_PREFIX in pt)

# 7. probe()'s file-level status arms — the part that decides re-login vs retry — tested
#    WITHOUT the network (an empty/missing token is resolved before any connection). The
#    accepted (0) arm needs a live upstream, so it stays in `cc --broker-status`, not here.
empty = tempfile.NamedTemporaryFile("w", suffix=".token", delete=False)
empty.write("")
empty.close()
check("probe: empty token → 1 (reject, re-login) with no network call",
      b.probe(empty.name, "claude") == 1)
check("probe: unreadable/missing token file → 2 (inconclusive)",
      b.probe(empty.name + ".nope", "claude") == 2)
check("probe: unknown provider is rejected (SystemExit), never a false 'accepted'",
      _raises_systemexit(lambda: b.probe(empty.name, "nosuchprovider")))
os.unlink(empty.name)

os.unlink(tokf.name)
os.unlink(ph.name)
os.unlink(tempfile.gettempdir() + "/_ccb_rot")
print("\nALL OK" if ok else "\nFAILURES")
raise SystemExit(0 if ok else 1)
