"""The Wayland proxy's policy and its one interposition point.

Two properties matter and neither is observable from a running compositor: that a clipboard
write reaches the host stripped of the escape that would end bracketed paste, and that the
proxy never hands the client the compositor's own pipe when it cannot account for an fd.

Messages are built by hand — the wire format is four bytes of object id, two of size, two of
opcode — so no compositor, no wl-clipboard and no socket are needed.
"""

import os
import struct

import pytest

from kib.guest.wayland_guard import NEW_ID, SEND_EVENT, Connection, DeniedError
from kib.shared.clipboard import clean_text

DISPLAY, REGISTRY, SOURCE, DEVICE = 1, 2, 3, 4


def msg(obj_id: int, opcode: int, body: bytes = b"") -> bytes:
    size = 8 + len(body)
    return struct.pack("<II", obj_id, (size << 16) | opcode) + body


def wl_str(s: str) -> bytes:
    raw = s.encode() + b"\0"
    return struct.pack("<I", len(raw)) + raw + b"\0" * (-len(raw) % 4)


def bind(iface: str, new_id: int) -> bytes:
    """registry.bind(name, interface, version, id) — the guard learns the name off the wire."""
    return msg(REGISTRY, 0, struct.pack("<I", 7) + wl_str(iface) + struct.pack("<II", 1, new_id))


@pytest.fixture
def conn() -> Connection:
    c = Connection(None, None, "test")  # type: ignore[arg-type]  # no socket is touched
    c.objects[REGISTRY] = "wl_registry"
    return c


def to_server(c: Connection, data: bytes) -> None:
    c._filter(data, True, [])


# ── the sanitiser ────────────────────────────────────────────────────────
@pytest.mark.parametrize(
    "raw,want",
    [
        (b"plain text", b"plain text"),
        (b"line\ttab\nline", b"line\ttab\nline"),  # tab and newline are content, not control
        (b"echo hi\x1b[201~rm -rf /", b"echo hi[201~rm -rf /"),  # the paste escape dies
        (b"drop\rme", b"dropme"),  # CR would submit at a prompt without bracketed paste
        ("emoji 🎉 box ┌─┐ 漢字".encode(), "emoji 🎉 box ┌─┐ 漢字".encode()),
        (b"c1\xc2\x9bhere", b"c1here"),  # U+009B is CSI: a C1 escape, and invisible
    ],
)
def test_clean_text_keeps_every_visible_glyph(raw: bytes, want: bytes) -> None:
    assert clean_text(raw)[0] == want


def test_clean_text_counts_what_it_removed() -> None:
    assert clean_text(b"a\x1b\x1bb")[1] == 2
    assert clean_text(b"ab")[1] == 0


# ── policy ───────────────────────────────────────────────────────────────
def test_the_write_path_is_allowed(conn: Connection) -> None:
    """Refusing these is what broke the fullscreen TUI's select-to-copy."""
    to_server(conn, bind("ext_data_control_manager_v1", 10))
    to_server(conn, msg(10, 0, struct.pack("<I", SOURCE)))  # create_data_source
    to_server(conn, msg(SOURCE, 0, wl_str("text/plain;charset=utf-8")))  # offer
    to_server(conn, msg(10, 1, struct.pack("<I", DEVICE)))  # get_data_device
    to_server(conn, msg(DEVICE, 0, struct.pack("<II", SOURCE, 0)))  # set_selection
    assert conn.objects[SOURCE] == "ext_data_control_source_v1"


@pytest.mark.parametrize("mime", ["image/png", "x-special/gnome-copied-files", "application/x"])
def test_a_non_text_flavour_is_refused(conn: Connection, mime: str) -> None:
    """clean_text guarantees nothing about bytes it cannot read as text."""
    to_server(conn, bind("wl_data_device_manager", 10))
    to_server(conn, msg(10, 0, struct.pack("<I", SOURCE)))
    with pytest.raises(DeniedError):
        to_server(conn, msg(SOURCE, 0, wl_str(mime)))


def test_start_drag_is_refused(conn: Connection) -> None:
    to_server(conn, bind("wl_data_device_manager", 10))
    to_server(conn, msg(10, 1, struct.pack("<I", DEVICE)))
    with pytest.raises(DeniedError):
        to_server(conn, msg(DEVICE, 0, b"\0" * 16))


# ── the interposition ────────────────────────────────────────────────────
def send_event(conn: Connection, fds: list[int]) -> list[int]:
    """Drive one `send` event server->client and return the fds the client would receive."""
    conn._filter(msg(SOURCE, 0, wl_str("text/plain")), False, fds)
    return fds


def test_the_client_writes_into_our_pipe_and_the_host_gets_it_clean(conn: Connection) -> None:
    to_server(conn, bind("zwlr_data_control_manager_v1", 10))
    to_server(conn, msg(10, 0, struct.pack("<I", SOURCE)))

    host_r, host_w = os.pipe()  # stands in for the compositor's pipe
    (client_w,) = send_event(conn, [host_w])
    assert client_w != host_w, "the client must never receive the compositor's own fd"

    os.write(client_w, b"copied\x1b[201~evil")
    os.close(client_w)
    with os.fdopen(host_r, "rb") as host:
        assert host.read() == b"copied[201~evil"


# (manager, `send` event opcode) — the opcode is the protocol's, read from the interface
# tables compiled into wl-copy, NOT from SEND_EVENT, so a family missing from the guard's
# tables fails on the security assertion rather than on the lookup.
@pytest.mark.parametrize(
    "manager,send_op",
    [
        ("zwlr_data_control_manager_v1", 0),
        ("ext_data_control_manager_v1", 0),
        ("zwp_primary_selection_device_manager_v1", 0),
        # Pre-standard, GNOME's, and still in wl-clipboard's fallback chain — the family that
        # was missing. An untracked source never registers as a `send`, so its fd took the
        # "nothing here can be a selection pipe" path and reached the client RAW.
        ("gtk_primary_selection_device_manager", 0),
        ("wl_data_device_manager", 1),  # wl_data_source: target=0, send=1
    ],
)
def test_every_clipboard_family_is_interposed(conn: Connection, manager: str, send_op: int) -> None:
    to_server(conn, bind(manager, 10))
    to_server(conn, msg(10, 0, struct.pack("<I", SOURCE)))  # create the source
    host_r, host_w = os.pipe()
    fds = [host_w]
    conn._filter(msg(SOURCE, send_op, wl_str("text/plain")), False, fds)
    assert fds[0] != host_w, f"{manager}: the client got the compositor's own pipe"
    os.write(fds[0], b"x\x1by")
    os.close(fds[0])
    with os.fdopen(host_r, "rb") as host:
        assert host.read() == b"xy"


@pytest.mark.parametrize(
    "iface", ["ext_data_control_manager_v2", "kde_primary_selection_manager", "x_data_device_v9"]
)
def test_an_unknown_selection_family_is_refused_at_bind(conn: Connection, iface: str) -> None:
    """The failure this closes is silent: an untracked source means the compositor's own pipe
    reaches the client unfiltered, with the clipboard still appearing to work."""
    with pytest.raises(DeniedError):
        to_server(conn, bind(iface, 10))


@pytest.mark.parametrize("iface", ["zwp_linux_dmabuf_v1", "xdg_wm_base", "wl_seat", "wl_shm"])
def test_a_non_selection_interface_still_binds(conn: Connection, iface: str) -> None:
    """The refusal is scoped to selection-carrying families — nothing else may be caught by it."""
    to_server(conn, bind(iface, 10))
    assert conn.objects[10] == iface


def test_every_source_interface_has_a_send_event() -> None:
    """The tables are two halves of one fact, and a half-added family fails OPEN: the source is
    never recognised, so `_filter` forwards the compositor's pipe unfiltered."""
    assert {made[0] for made in NEW_ID.values()} == set(SEND_EVENT)


def test_an_fd_with_no_send_in_the_batch_passes_through(conn: Connection) -> None:
    """The read path: wl-clipboard makes a keyboard to get a serial for set_selection, and the
    compositor answers with a keymap fd. Refusing it closed the connection and broke wl-paste
    outright — caught against a real compositor, not in review."""
    to_server(conn, bind("wl_seat", 20))
    r, w = os.pipe()
    fds = [r]
    event = msg(20, 4, struct.pack("<II", 1, 8))  # an fd-carrying event that is not `send`
    assert conn._filter(event, False, fds) == (event, b"")
    assert fds == [r], "the compositor's keymap fd must reach the client untouched"
    os.close(r)
    os.close(w)


def test_an_fd_it_cannot_account_for_is_refused(conn: Connection) -> None:
    """A keymap fd in the same batch would otherwise mispair and leak the real pipe."""
    to_server(conn, bind("zwlr_data_control_manager_v1", 10))
    to_server(conn, msg(10, 0, struct.pack("<I", SOURCE)))
    r, w = os.pipe()
    with pytest.raises(DeniedError):
        send_event(conn, [r, w])  # two fds, one send
    os.close(r)
    os.close(w)


def test_an_fd_whose_message_is_still_arriving_is_held(conn: Connection) -> None:
    """Wayland delivers an fd with the first bytes of its message, not the last."""
    to_server(conn, bind("zwlr_data_control_manager_v1", 10))
    to_server(conn, msg(10, 0, struct.pack("<I", SOURCE)))
    r, w = os.pipe()
    partial = msg(SOURCE, 0, wl_str("text/plain"))[:6]
    out, leftover = conn._filter(partial, False, [w])
    assert (out, leftover) == (b"", partial), "nothing forwarded until the message is whole"
    os.close(r)
    os.close(w)
