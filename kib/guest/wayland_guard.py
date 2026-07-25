"""Filtering Wayland proxy — lets the sandbox READ the host clipboard, never write it.

Runs in the guest, in its own `cap-drop=ALL` sidecar.

The socket is mounted for one job — pasting an image FROM the host clipboard — but a raw
socket also grants clipboard WRITES, and a write is host code execution at your next terminal
paste: an embedded ESC[201~ ends bracketed paste early, so the rest is interpreted as typed
input. So the main container never sees the real socket. It talks to this proxy, which relays
the wire protocol verbatim but refuses every request that would set a selection, closing that
connection. Reads are untouched, and so is host-side select+copy — your terminal emulator is a
host client and never comes through here.

Each denial is one WLGUARD-DENY line on stdout, which kib's host-side follower turns into a
desktop notification.
"""

import argparse
import array
import os
import select
import socket
import struct
import threading
from collections.abc import Sequence

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
# outright. Refusing the individual write requests is exactly as strict.
#
# interface -> {opcode: request name}. A matching client request is refused.
DENIED_REQUESTS = {
    "zwlr_data_control_manager_v1": {0: "create_data_source"},
    "ext_data_control_manager_v1": {0: "create_data_source"},
    "zwlr_data_control_device_v1": {0: "set_selection", 2: "set_primary_selection"},
    "ext_data_control_device_v1": {0: "set_selection", 2: "set_primary_selection"},
    "wl_data_device_manager": {0: "create_data_source"},
    "wl_data_device": {0: "start_drag", 1: "set_selection"},
    "zwp_primary_selection_device_manager_v1": {0: "create_data_source"},
    "zwp_primary_selection_device_v1": {0: "set_selection"},
}

# interface -> (opcode, name of the interface the new_id gets). Only the factory
# requests whose product we must police; the new_id is the first argument in each.
DEVICE_FACTORIES = {
    "zwlr_data_control_manager_v1": (1, "zwlr_data_control_device_v1"),
    "ext_data_control_manager_v1": (1, "ext_data_control_device_v1"),
    "wl_data_device_manager": (1, "wl_data_device"),
    "zwp_primary_selection_device_manager_v1": (1, "zwp_primary_selection_device_v1"),
}

HEADER = struct.Struct("<II")
MAX_FDS = 32


def log(kind: str, detail: object) -> None:
    """One line per event; kib's follower greps WLGUARD-DENY out of `docker logs`."""
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
        self.closed = False

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
            (new_id,) = struct.unpack_from("<I", body, off + 4)
            self.objects[new_id] = bound
            return
        factory = DEVICE_FACTORIES.get(iface) if iface else None
        if factory and opcode == factory[0]:
            (new_id,) = struct.unpack_from("<I", body, 0)
            self.objects[new_id] = factory[1]

    # ── policy ───────────────────────────────────────────────────────────
    def _denied(self, obj_id: int, opcode: int) -> str | None:
        iface = self.objects.get(obj_id)
        return DENIED_REQUESTS.get(iface, {}).get(opcode) if iface else None

    # ── pumping ──────────────────────────────────────────────────────────
    def _filter(self, buf: bytes, to_server: bool) -> tuple[bytes, bytes]:
        """Consume whole messages from `buf`; return (bytes to forward, leftover).

        Raises DeniedError when the client attempts a clipboard write.
        """
        out, off = bytearray(), 0
        while len(buf) - off >= HEADER.size:
            obj_id, word = HEADER.unpack_from(buf, off)
            size, opcode = word >> 16, word & 0xFFFF
            if size < HEADER.size or len(buf) - off < size:
                break  # partial message; wait for more
            body = buf[off + HEADER.size : off + size]
            if to_server:
                denied = self._denied(obj_id, opcode)
                if denied:
                    raise DeniedError(f"{self.objects.get(obj_id)}.{denied}")
                self._track_request(obj_id, opcode, body)
            out += buf[off : off + size]  # server->client is always forwarded
            off += size
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
                    data, fds = recv_with_fds(sock)
                    if not data and not fds:
                        return  # peer closed
                    held[to_server] += fds
                    bufs[to_server] += data
                    out, bufs[to_server] = self._filter(bufs[to_server], to_server)
                    if out:
                        send_with_fds(dst, out, held[to_server])
                        held[to_server] = []
                    # No payload to carry them on yet: keep the fds until there is.
                    # Wayland lets an fd arrive early, never late.
        except DeniedError as d:
            log("DENY", f"{self.peer} {d} — connection closed")
        except (OSError, struct.error, ConnectionError):
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


def recv_with_fds(sock: socket.socket) -> tuple[bytes, list[int]]:
    """recvmsg preserving SCM_RIGHTS — clipboard content travels as a pipe fd."""
    fds: list[int] = []
    msg, anc, _, _ = sock.recvmsg(4096, socket.CMSG_SPACE(MAX_FDS * 4))
    for level, ctype, cdata in anc:
        if level == socket.SOL_SOCKET and ctype == socket.SCM_RIGHTS:
            a = array.array("i")
            a.frombytes(cdata[: len(cdata) - (len(cdata) % a.itemsize)])
            fds += list(a)
    return msg, fds


def send_with_fds(sock: socket.socket, data: bytes, fds: Sequence[int]) -> None:
    anc: list[tuple[int, int, array.array[int]]] = []
    if fds:
        anc = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))]
    sent = sock.sendmsg([data], anc)
    while sent < len(data):  # ancillary rides the first send
        sent += sock.send(data[sent:])
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
