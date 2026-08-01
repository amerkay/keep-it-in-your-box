FROM debian:trixie

# Install Node.js via NodeSource repository and all system dependencies in one layer
ARG NODE_MAJOR=26
RUN apt-get update && apt-get install -y curl \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    # Node.js from NodeSource
    nodejs \
    # Core development tools
    build-essential git wget vim nano \
    # Modern shell tools
    # (shellcheck is NOT here: it is pinned to a release binary further down, with shfmt)
    jq ripgrep fzf fd-find bat tmux \
    # Languages and runtimes
    python3 python3-pip python3-venv \
    # RS256 for the broker's OAuth service-account grant (kib/broker/oauth.py, lazily
    # imported — kib/broker must still import on a host that has never seen this).
    python3-cryptography \
    # Database clients (minimal set)
    postgresql-client sqlite3 \
    # Network and system tools
    # (trixie renamed dnsutils -> bind9-dnsutils)
    netcat-openbsd telnet bind9-dnsutils iputils-ping \
    # Media processing.
    # rsvg-convert is the SVG rasterizer tooling expects on PATH; unlike cairosvg it renders
    # through Pango, so a CSS font-family *list* ("ui-monospace, SFMono-Regular, monospace")
    # resolves instead of collapsing to the default sans. cairosvg + Pillow are the
    # library-level fallback, baked in so nothing has to build a venv per session.
    ffmpeg librsvg2-bin python3-pil python3-cairosvg python3-cairocffi \
    fontconfig fonts-dejavu fonts-liberation \
    # Audio (PulseAudio client for voice mode)
    pulseaudio-utils libpulse0 \
    # System administration. util-linux is here for nsenter: on macOS the FUSE root lives
    # inside the engine VM, and kib enters that VM's mount namespace through this image.
    gosu procps util-linux \
    # Clipboard support (Wayland)
    wl-clipboard \
    # Misc utilities
    tree less file unzip zip \
    # Environment management
    direnv \
    # Required for Claude Code's built-in sandbox
    bubblewrap socat \
    # FUSE runtime for the .kibignore redacting mount.
    # trixie's 64-bit time_t transition renamed libfuse2 -> libfuse2t64, and fusepy is
    # packaged, so it comes from apt instead of a PEP 668 --break-system-packages override.
    fuse3 libfuse2t64 python3-fusepy \
    && rm -rf /var/lib/apt/lists/*

# Runtime config for the packages above. Its own RUN so editing either line is a
# seconds-long cached rebuild rather than a full re-do of the apt layer.
# user_allow_other lets the sidecar's FUSE mount use -o allow_other, which is what makes the
# propagated view readable by the agent container's root entrypoint as well as its agent user.
RUN echo 'user_allow_other' > /etc/fuse.conf \
    && echo 'eval "$(direnv hook bash)"' >> /etc/bash.bashrc

# Smoke-test the layers above. Kept as its own cheap RUN on purpose: editing an
# assertion then re-runs in seconds off the cache, instead of re-doing the whole
# ~10-minute apt install. Each check is one an earlier build actually failed on:
# fusepy is 'fusepy' in Debian but 'fuse' from PyPI, and rsvg-convert/cairosvg
# have both been silently absent before.
RUN node --version && npm --version \
    && python3 -c "from fusepy import FUSE, FuseOSError, Operations; print('fusepy OK')" \
    && rsvg-convert --version \
    && python3 -c "import PIL, cairosvg; print('Pillow', PIL.__version__, '/ cairosvg', cairosvg.__version__)" \
    && python3 -c "from cryptography.hazmat.primitives.asymmetric import padding; print('cryptography OK')" \
    && grep -qx 'user_allow_other' /etc/fuse.conf

# Install packages not available in Debian repos
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Python environment management tool)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv \
    && mv /root/.local/bin/uvx /usr/local/bin/uvx

# Install JavaScript/TypeScript development tools.
#
# These land in the SYSTEM prefix, which a version switch does not move — unlike npm/npx, which
# ship inside each node tarball. Only pnpm cares (11.x needs node >=22.13 and CRASHES below),
# so node-fetch.sh gives an older cached line its own copy; this one is ${NODE_MAJOR}'s.
RUN npm install -g \
    ts-node \
    tsx \
    yarn \
    pnpm


# Mountpoint for the user-level Node cache (host/node.sh) — nothing is baked. Created empty so
# nvm sees a valid, empty store on a machine that has cached nothing yet.
RUN mkdir -p /opt/nvm-versions

# nvm, pinned like the other release-binary tools. It is a shell function, so it comes from ONE
# file with three readers — see the ENV BASH_ENV note below. /opt/nvm is the pristine
# root-owned copy and can never BE $NVM_DIR (`nvm install` writes into $NVM_DIR itself), so
# the entrypoint seeds $HOME/.nvm from it; /etc/skel cannot, because docker pre-creates $HOME.
ARG NVM_VERSION=v0.40.6
RUN git clone --depth 1 --branch "$NVM_VERSION" https://github.com/nvm-sh/nvm.git /opt/nvm \
    && rm -rf /opt/nvm/.git \
    && bash -c '. /opt/nvm/nvm.sh && nvm --version' \
    && chmod -R a+rX /opt/nvm \
    && printf '%s\n' \
        'export NVM_DIR="$HOME/.nvm"' \
        '# Lazy: nvm.sh defines 118 functions and Claude Code serialises every captured one' \
        '# into its shell snapshot, replayed on EVERY Bash call (claude-code#31437: ~8s at 199).' \
        '# `use` also repoints $KIB_NODE_CURRENT, the PATH symlink that makes a switch outlive' \
        '# the command. Only `use`: NVM_BIN is unset for ls/current, which would read as system.' \
        'nvm() {' \
        '  unset -f nvm' \
        '  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
        '  nvm "$@" || return' \
        '  [ -n "${KIB_NODE_CURRENT:-}" ] || return 0' \
        '  case "${1:-}" in' \
        '    use)' \
        '      if [ -n "${NVM_BIN:-}" ]; then ln -sfn "${NVM_BIN%/bin}" "$KIB_NODE_CURRENT"' \
        '      else rm -f "$KIB_NODE_CURRENT"; fi ;;' \
        '  esac' \
        '}' \
        > /etc/kib-nvm.sh \
    && printf '%s\n' \
        '. /etc/kib-nvm.sh' \
        '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"' \
        >> /etc/bash.bashrc

# Three readers, one file: /etc/bash.bashrc (terminals), $BASH_ENV (a non-interactive `bash -c`)
# and the ~/.bashrc the entrypoint drops. Only that last one reaches Claude's OWN tool calls,
# which replay a snapshot captured from ~/.bashrc and ignore BASH_ENV entirely (measured).
ENV BASH_ENV=/etc/kib-nvm.sh

# Shell lint/format tools, PINNED and fail-hard.
#
# Both are enforced by ./dev.sh lint and by CI, so a floating version means the same code
# passes here and fails there. They used to float: shfmt was fetched as GitHub "latest"
# (formatting drifts between releases) and shellcheck came from apt (drifts with Debian, and
# never matches the CI runner's apt). Release binaries pinned here are the only way the
# container, CI and a host `brew install` can agree — bump these two lines deliberately, and
# keep them in step with .github/workflows/lint.yml and requirements-dev.txt's comment.
#
# Fail-hard on purpose: a silently-missing formatter turns `dev.sh lint` into a no-op.
ARG SHFMT_VERSION=v3.13.1
ARG SHELLCHECK_VERSION=v0.10.0
RUN set -eu \
    && case "$(uname -m)" in \
        x86_64) SHFMT_ARCH=amd64; SC_ARCH=x86_64 ;; \
        aarch64) SHFMT_ARCH=arm64; SC_ARCH=aarch64 ;; \
        armv7l) SHFMT_ARCH=arm; SC_ARCH=armv6hf ;; \
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/shfmt \
        "https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_${SHFMT_ARCH}" \
    && chmod +x /usr/local/bin/shfmt \
    && curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.${SC_ARCH}.tar.xz" \
        | tar -xJ -C /tmp \
    && install -m 0755 "/tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
    && rm -rf "/tmp/shellcheck-${SHELLCHECK_VERSION}" \
    && shfmt --version && shellcheck --version

# Create symlinks for fd (some systems call it fdfind)
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Install Playwright browsers to a shared location so any UID can use them
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN npx playwright install --with-deps chromium && \
    chmod -R o+rx /opt/playwright-browsers && \
    ln -s "$(find /opt/playwright-browsers -name chrome -type f | head -1)" /usr/local/bin/google-chrome-stable && \
    ln -s /usr/local/bin/google-chrome-stable /usr/local/bin/google-chrome

# Map the monospace names CSS font stacks lead with onto a font that exists here, so a
# cairosvg render that does pick a single family off the stack still lands on a mono face.
RUN printf '%s\n' \
    '<?xml version="1.0"?>' \
    '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">' \
    '<fontconfig>' \
    '  <alias binding="strong"><family>ui-monospace</family><accept><family>monospace</family></accept></alias>' \
    '  <alias binding="strong"><family>SFMono-Regular</family><accept><family>monospace</family></accept></alias>' \
    '  <alias binding="strong"><family>SF Mono</family><accept><family>monospace</family></accept></alias>' \
    '  <alias binding="strong"><family>Menlo</family><accept><family>monospace</family></accept></alias>' \
    '  <alias binding="strong"><family>Monaco</family><accept><family>monospace</family></accept></alias>' \
    '  <alias binding="strong"><family>Consolas</family><accept><family>monospace</family></accept></alias>' \
    '  <alias binding="strong"><family>Cascadia Mono</family><accept><family>monospace</family></accept></alias>' \
    '  <alias binding="strong"><family>JetBrains Mono</family><accept><family>monospace</family></accept></alias>' \
    '  <alias binding="strong"><family>monospace</family><prefer><family>DejaVu Sans Mono</family><family>Liberation Mono</family></prefer></alias>' \
    '</fontconfig>' > /etc/fonts/conf.d/99-kib-monospace.conf \
    && fc-cache -f \
    && fc-match monospace \
    && fc-match ui-monospace

# Python dev tools at the versions pinned in requirements-dev.txt, so `./dev.sh lint` in a
# session matches the host and CI exactly. Installed into their own venv because Debian marks
# the system interpreter EXTERNALLY-MANAGED (PEP 668) — `uv pip install --system` is refused
# there. Symlinked onto PATH and made world-readable: sessions run as the host user's UID,
# not root. Sits above the Claude layer so a version bump keeps this cached.
COPY requirements-dev.txt /opt/requirements-dev.txt
RUN uv venv /opt/dev-tools \
    && uv pip install --no-cache --python /opt/dev-tools/bin/python -r /opt/requirements-dev.txt \
    && ln -s /opt/dev-tools/bin/ruff /usr/local/bin/ruff \
    && ln -s /opt/dev-tools/bin/mypy /usr/local/bin/mypy \
    && ln -s /opt/dev-tools/bin/pytest /usr/local/bin/pytest \
    && chmod -R a+rX /opt/dev-tools \
    && ruff --version && mypy --version && pytest --version

# Mountpoint parent for the sandbox rules: kib binds guest/policy/etc-CLAUDE.md over
# /etc/claude-code/CLAUDE.md at run time. Above the version bump so it stays cached.
RUN mkdir -p /etc/claude-code

# Install Claude Code via official native installer
# NOTE: everything below this line rebuilds on every Claude Code version bump.
# Keep new apt/tooling layers ABOVE it so a routine upgrade stays a fast, cached build.
ARG CLAUDE_VERSION=latest
RUN echo "Installing Claude Code version: ${CLAUDE_VERSION}" && \
    curl -fsSL https://claude.ai/install.sh | bash && \
    install -m 0755 "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude && \
    /usr/local/bin/claude --version && \
    /usr/local/bin/claude --version 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 > /etc/claude-code-version

# Entrypoints + guest shims (after the Claude install so edits don't bust its cache).
#
# The entrypoint is BAKED, not bind-mounted: it is the container's ENTRYPOINT and runs as root,
# so a sandboxed session must not be able to edit it. Changing it needs a rebuild.
COPY guest/entrypoint/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
# The kib package is COPIED here as a fallback, then bind-mounted over at run time from the
# checkout — in the SIDECARS, which are the only containers that import it (the agent's runs no
# kib code). So editing the FUSE server or a sidecar takes effect on the next container with no
# rebuild. The three shims in /usr/local/bin are baked because they never change: each is one
# `exec` line that puts /usr/local/lib on sys.path for that process only. PYTHONPATH is NOT
# an image ENV — it would leak into every process the agent later runs.
COPY kib /usr/local/lib/kib
COPY guest/bin/fuse guest/bin/wayland-guard guest/bin/broker /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
	/usr/local/bin/fuse /usr/local/bin/wayland-guard /usr/local/bin/broker \
	&& chmod -R a+rX /usr/local/lib/kib \
	&& python3 -c "import sys; sys.path.insert(0, '/usr/local/lib'); import kib.shared.rules, kib.broker.cli; print('kib package OK')"

ENV SHELL=/bin/bash
ENV TERM=xterm-256color
ENV DISABLE_AUTOUPDATER=1

# Set entrypoint for user management
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# Default command: Run Claude Code
CMD ["claude", "--dangerously-skip-permissions"]
