"""Runs as YOU, on the host. Never mounted into a container, never imported by the guest.

Everything here touches the user's real files — canonical `~/.claude`, the host-only
credential store, the project's git config — so it may assume the host's privileges and
must never assume the caller is trustworthy about paths it was handed.
"""
