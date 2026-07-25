"""Runs INSIDE a container, under `cap-drop=ALL`. Assume every input is hostile.

These modules are bind-mounted from the checkout, not baked, so editing one takes effect
on the next *container* — not the next terminal. Only `kib.shared` and the stdlib may be
imported here: the image has no pip packages beyond the ones the Dockerfile installs.
"""
