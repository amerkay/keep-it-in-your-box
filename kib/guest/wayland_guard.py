"""Filtering Wayland proxy — the sandbox reads the host clipboard, and writes it only cleaned.

Runs in the guest, in its own `cap-drop=ALL` sidecar.

The socket is mounted for pasting an image FROM the host clipboard, but a raw socket also
grants clipboard WRITES, and a *verbatim* write is host code execution at your next terminal
paste: an embedded ESC[201~ ends bracketed paste early, so the rest is interpreted as typed
input. So the main container never sees the real socket. It talks to this proxy, which relays
the wire protocol and interposes on the one thing that matters — the pipe the compositor hands
back on `send`. Content crosses through `clean_text`, so what reaches the clipboard is inert
text. Reads are untouched, and so is host-side select+copy: your terminal emulator is a host
client and never comes through here.

**The content is the boundary, not the caller.** Refusing writes outright is what broke the
fullscreen TUI's select-to-copy, and no identity check can replace it: the sidecar has its own
PID namespace, so `SO_PEERCRED` yields pid 0, and sharing the agent's namespace to fix that
would let the box — same uid — kill or ptrace the one process holding the real socket. A shim
inside the box is no better; nothing there can hold a secret from anything else there.

Each policy event is one WLGUARD-{DENY,STRIP} line on stdout, which kib's host-side follower
turns into a desktop notification; READY and ERROR go to the log only.
"""

import argparse
import os
import select
import socket
import struct
import threading
from collections.abc import Sequence

from kib.shared.clipboard import MAX_WRITE, clean_text
from kib.shared.log import stdout_line

# ── Protocol facts ───────────────────────────────────────────────────────
# Opcodes are frozen by the protocol XMLs (a released interface may only append
# requests), so hard-coding the few we care about needs no protocol database.
WL_DISPLAY_ID = 1
WL_DISPLAY_GET_REGISTRY = 1
WL_REGISTRY_BIND = 0

# NOTHING is hidden from the registry, deliberately. Every clipboard interface carries both
# the read and the write half, so dropping a global removes the READS we exist to preserve —
# on KWin, wl-clipboard falls back to wl_data_device_manager, and hiding that broke `wl-paste`
# outright. Sanitising the content in flight is strictly better: it keeps the reads AND the
# writes, and costs a hostile client the escape either way.
#
# interface -> {opcode: request name}. A matching client request closes the connection.
DENIED_REQUESTS = {
    # Drag-and-drop, not the clipboard: no window in here has ever had a surface to drag from,
    # and the offer it publishes escapes `send` interposition.
    "wl_data_device": {0: "start_drag"},
}

# interface -> {opcode: interface the new_id becomes}. The new_id is each request's first
# argument. Only what policy reads: every manager's SOURCE (opcode 0), because a source that is
# not tracked here has its `send` fd forwarded untouched — see `_filter`. Devices are tracked
# only where a request is denied on one, which is `wl_data_device.start_drag` alone.
#
# EVERY family the installed wl-clipboard can bind must appear, including the pre-standard
# `gtk_primary_selection_*` (GNOME's, still in wl-clipboard's fallback chain — verified in the
# wl-copy/wl-paste binaries). A missing family is not a missing feature, it is a bypass.
NEW_ID = {
    "zwlr_data_control_manager_v1": {0: "zwlr_data_control_source_v1"},
    # The one row no artefact on a dev box can check: `ext_` is absent from the installed
    # wl-clipboard and ships no XML. Values are the staging promotion of `zwlr_`, which
    # preserves message order — the pytest confirms the table against itself, nothing more.
    "ext_data_control_manager_v1": {0: "ext_data_control_source_v1"},
    "zwp_primary_selection_device_manager_v1": {0: "zwp_primary_selection_source_v1"},
    "gtk_primary_selection_device_manager": {0: "gtk_primary_selection_source"},
    "wl_data_device_manager": {0: "wl_data_source", 1: "wl_data_device"},
}

# source interface -> opcode of its `send` EVENT (server->client, carrying the pipe fd the
# client writes the selection into). That fd is the interposition point. Keys must match
# NEW_ID's sources exactly; `test_every_source_interface_has_a_send_event` pins that.
SEND_EVENT = {
    "wl_data_source": 1,  # events: target=0, send=1, cancelled=2, …
    "zwlr_data_control_source_v1": 0,
    "ext_data_control_source_v1": 0,
    "zwp_primary_selection_source_v1": 0,
    "gtk_primary_selection_source": 0,
}

OFFER = 0  # `offer(mime_type)` is request 0 on every source interface
X11_TEXT = {"STRING", "UTF8_STRING", "TEXT"}  # wl-clipboard offers these alongside text/*

# A selection-carrying interface this file does not know would fail OPEN — untracked source, so
# its `send` fd is forwarded to the client unfiltered and the escape survives. These three
# fragments name every Wayland family that can carry one, so an unrecognised member is refused
# at `bind` and shows up as an alert rather than as a silent bypass. Nothing else is affected:
# a GUI toolkit's protocols do not match, and never reach this test.
SELECTION_FAMILY = ("data_control", "primary_selection", "data_device")

HEADER = struct.Struct("<II")
MAX_FDS = 32


def log(kind: str, detail: object) -> None:
    """One line per event; kib's follower greps DENY and STRIP out of `docker logs`.

    Both prefixes are a contract with `start_wayland_notifier` in host/desktop.sh — rename one
    and the desktop simply stops being told, with nothing failing anywhere.
    """
    stdout_line(f"WLGUARD-{kind} {detail}")


def _read_str(body: bytes, off: int) -> tuple[str, int]:
    """Wayland string: uint32 length (including NUL), then that many bytes, padded to 4."""
    (n,) = struct.unpack_from("<I", body, off)
    off += 4
    s = body[off : off + n - 1].decode("utf-8", "replace") if n else ""
    return s, off + ((n + 3) & ~3)


class Connection:
    """One client of the compositor, proxied. Owns its object-id -> interface map."""

    def __init__(self, client: socket.socket, server: socket.socket, peer: str) -> None:
        self.client = client
        self.server = server
        self.peer = peer
        # id 1 is always wl_display; everything else is learned from the traffic.
        self.objects: dict[int, str] = {WL_DISPLAY_ID: "wl_display"}

    # ── object tracking ──────────────────────────────────────────────────
    def _track_request(self, obj_id: int, opcode: int, body: bytes) -> None:
        """Learn what a newly allocated object id is, from the request that made it."""
        iface = self.objects.get(obj_id)
        if iface == "wl_display" and opcode == WL_DISPLAY_GET_REGISTRY:
            (new_id,) = struct.unpack_from("<I", body, 0)
            self.objects[new_id] = "wl_registry"
            return
        if iface == "wl_registry" and opcode == WL_REGISTRY_BIND:
            # bind(name: uint, interface: string, version: uint, id: new_id) — the
            # interface name travels on the wire, so no protocol database is needed.
            off = 4  # past bind's leading `name` uint, which the guard never needs
            bound, off = _read_str(body, off)
            known = bound in NEW_ID or bound in DENIED_REQUESTS
            if not known and any(f in bound for f in SELECTION_FAMILY):
                raise DeniedError(f"unknown selection interface {bound[:64]!r}")
            (new_id,) = struct.unpack_from("<I", body, off + 4)
            self.objects[new_id] = bound
            return
        made = NEW_ID.get(iface, {}).get(opcode) if iface else None
        if made:
            (new_id,) = struct.unpack_from("<I", body, 0)
            self.objects[new_id] = made

    # ── policy ───────────────────────────────────────────────────────────
    def _denied(self, obj_id: int, opcode: int, body: bytes) -> str | None:
        iface = self.objects.get(obj_id)
        if not iface:
            return None
        # Text only. `clean_text` guarantees nothing about bytes it never sees as text, and a
        # non-text flavour (x-special/… file lists, image/*) has no select-to-copy to serve.
        if iface in SEND_EVENT and opcode == OFFER:
            mime, _ = _read_str(body, 0)
            return None if mime.startswith("text/") or mime in X11_TEXT else "offer(non-text)"
        return DENIED_REQUESTS.get(iface, {}).get(opcode)

    def _sanitising_pipe(self, dst_fd: int) -> int:
        """Swap the compositor's pipe for one of ours; return the end the client gets."""
        read_fd, write_fd = os.pipe()
        threading.Thread(target=self._pump, args=(read_fd, dst_fd), daemon=True).start()
        return write_fd

    def _pump(self, src_fd: int, dst_fd: int) -> None:
        """Client -> compositor, cleaned. Buffered whole: the cap needs the length anyway."""
        try:
            with open(src_fd, "rb", closefd=True) as src, open(dst_fd, "wb", closefd=True) as dst:
                data = src.read(MAX_WRITE + 1)
                if len(data) > MAX_WRITE:
                    log("DENY", f"{self.peer} clipboard write over {MAX_WRITE} bytes — dropped")
                    return
                cleaned, stripped = clean_text(data)
                if stripped:
                    log("STRIP", f"{self.peer} {stripped} control character(s) removed")
                dst.write(cleaned)
        except OSError:
            pass

    # ── pumping ──────────────────────────────────────────────────────────
    def _filter(self, buf: bytes, to_server: bool, fds: list[int]) -> tuple[bytes, bytes]:
        """Consume whole messages from `buf`; return (bytes to forward, leftover).

        `fds` is the pending SCM_RIGHTS batch and is rewritten in place: a compositor pipe
        arriving with a `send` event is replaced by one this proxy cleans on the way through.
        Raises DeniedError on a refused request or an fd it cannot account for.
        """
        out, off, sends = bytearray(), 0, 0
        while len(buf) - off >= HEADER.size:
            obj_id, word = HEADER.unpack_from(buf, off)
            size, opcode = word >> 16, word & 0xFFFF
            if size < HEADER.size or len(buf) - off < size:
                break  # partial message; wait for more
            body = buf[off + HEADER.size : off + size]
            if to_server:
                denied = self._denied(obj_id, opcode, body)
                if denied:
                    raise DeniedError(f"{self.objects.get(obj_id)}.{denied}")
                self._track_request(obj_id, opcode, body)
            elif SEND_EVENT.get(self.objects.get(obj_id, "")) == opcode:
                sends += 1
            out += buf[off : off + size]  # server->client is always forwarded
            off += size
        if not to_server and fds:
            if len(buf) - off:
                # A message is still arriving and it may be the `send` that owns this fd.
                # Forward nothing: handing the fd over first would hand over the compositor's
                # real pipe. Wayland delivers an fd with its message's first bytes, never after.
                return b"", buf
            if not sends:
                # Nothing in this batch can be a selection pipe, so it passes untouched. That
                # is the READ path: wl-clipboard makes a keyboard to get a serial for
                # set_selection, and the compositor answers with a wl_keyboard.keymap fd.
                pass
            elif sends == len(fds):
                # Each `send` carries exactly one fd, so equal counts pair positionally in
                # stream order.
                fds[:] = [self._sanitising_pipe(fd) for fd in fds]
            else:
                # Unresolvable, and guessing wrong leaks the real pipe to the client.
                raise DeniedError(f"unpaired fd (sends={sends} fds={len(fds)})")
        return bytes(out), buf[off:]

    def run(self) -> None:
        bufs = {True: b"", False: b""}  # keyed by to_server
        held: dict[bool, list[int]] = {True: [], False: []}  # received but not yet forwarded
        try:
            while True:
                ready, _, _ = select.select([self.client, self.server], [], [])
                for sock in ready:
                    to_server = sock is self.client
                    dst = self.server if to_server else self.client
                    data, fds, _, _ = socket.recv_fds(sock, 4096, MAX_FDS)
                    if not data and not fds:
                        return  # peer closed
                    held[to_server] += fds
                    bufs[to_server] += data
                    out, bufs[to_server] = self._filter(bufs[to_server], to_server, held[to_server])
                    if out:
                        send_with_fds(dst, out, held[to_server])
                        held[to_server] = []
                    # No payload to carry them on yet: keep the fds until there is.
                    # Wayland lets an fd arrive early, never late.
        except DeniedError as d:
            log("DENY", f"{self.peer} {d} — connection closed")
        except (
            OSError,
            struct.error,
        ):  # ConnectionError is an OSError; struct.error is a short body
            pass
        finally:
            for group in held.values():
                for fd in group:
                    os.close(fd)
            for sock in (self.client, self.server):
                try:
                    sock.close()
                except OSError:
                    pass


class DeniedError(Exception):
    pass


def send_with_fds(sock: socket.socket, data: bytes, fds: Sequence[int]) -> None:
    """socket.send_fds does not loop, and the ancillary rides the FIRST send only."""
    sent = socket.send_fds(sock, [data], list(fds))
    if sent < len(data):
        sock.sendall(data[sent:])
    for fd in fds:
        os.close(fd)


def serve(listen_path: str, upstream_path: str) -> None:
    if os.path.exists(listen_path):
        os.unlink(listen_path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(listen_path)
    os.chmod(listen_path, 0o600)
    server.listen(16)
    log("READY", f"{listen_path} -> {upstream_path}")

    n = 0
    while True:
        client, _ = server.accept()
        n += 1
        try:
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            upstream.connect(upstream_path)
        except OSError as e:
            log("ERROR", f"upstream connect failed: {e}")
            client.close()
            continue
        threading.Thread(target=Connection(client, upstream, f"conn{n}").run, daemon=True).start()


def main() -> None:
    p = argparse.ArgumentParser(prog="kib-wayland-guard", description="filtering Wayland proxy")
    p.add_argument("--upstream", required=True, help="the host compositor socket")
    p.add_argument("--listen", required=True, help="socket to expose to the sandbox")
    a = p.parse_args()
    try:
        serve(a.listen, a.upstream)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
