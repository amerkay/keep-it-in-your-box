"""Imported by both the host and the guest — keep it stdlib-only and side-agnostic.

Nothing here may import `kib.host` or `kib.guest`: this is the layer they share, and a
back-edge would drag host-only code into the container.
"""
