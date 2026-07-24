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
    jq ripgrep fzf fd-find bat tmux shellcheck \
    # Languages and runtimes
    python3 python3-pip python3-venv \
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
    # System administration
    # util-linux carries setpriv — the single-container FUSE mode (macOS / Plan H) uses it
    # to drop CAP_SYS_ADMIN from the bounding set after mounting, before the agent runs.
    gosu procps util-linux \
    # Clipboard support (Wayland)
    wl-clipboard \
    # Misc utilities
    tree less file unzip zip \
    # Environment management
    direnv \
    # Required for Claude Code's built-in sandbox
    bubblewrap socat \
    # FUSE runtime for the .ccignore redacting sidecar.
    # trixie's 64-bit time_t transition renamed libfuse2 -> libfuse2t64, and fusepy is
    # packaged, so it comes from apt instead of a PEP 668 --break-system-packages override.
    fuse3 libfuse2t64 python3-fusepy \
    && rm -rf /var/lib/apt/lists/*

# Runtime config for the packages above. Its own RUN so editing either line is a
# seconds-long cached rebuild rather than a full re-do of the apt layer.
# user_allow_other lets the FUSE sidecar mount with -o allow_other, which is what
# makes the redacted view visible to the main container's user.
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
# supergateway bridges a stdio MCP server to streamable-HTTP; the credential-broker's
# hosted-MCP sidecar (cc-lib.sh start_hosted_mcp) runs it to expose a local/client-signed MCP
# (e.g. Google Search Console) over the broker network without the credential entering the
# agent container. Pre-installed so the sidecar needs no runtime npm fetch.
RUN npm install -g \
    ts-node \
    tsx \
    yarn \
    pnpm \
    supergateway

# Install shfmt (shell formatter) - non-blocking, build continues even if this fails
RUN ARCH=$(case $(uname -m) in \
        x86_64) echo amd64;; \
        aarch64) echo arm64;; \
        armv7l) echo arm;; \
        *) echo amd64;; \
    esac) \
    && SHFMT_FALLBACK_VERSION="v3.12.0" \
    && echo "Attempting to install shfmt..." \
    && SHFMT_VERSION=$(curl -s https://api.github.com/repos/mvdan/sh/releases/latest | jq -r .tag_name 2>/dev/null) \
    && if [ -z "$SHFMT_VERSION" ] || [ "$SHFMT_VERSION" = "null" ]; then \
        echo "Failed to fetch latest version, using fallback: $SHFMT_FALLBACK_VERSION"; \
        SHFMT_VERSION="$SHFMT_FALLBACK_VERSION"; \
    else \
        echo "Using latest version: $SHFMT_VERSION"; \
    fi \
    && echo "Downloading shfmt ${SHFMT_VERSION} for architecture: $ARCH" \
    && SHFMT_URL="https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_${ARCH}" \
    && echo "URL: $SHFMT_URL" \
    && if curl -fsSL "$SHFMT_URL" -o /usr/local/bin/shfmt 2>/dev/null; then \
        chmod +x /usr/local/bin/shfmt \
        && echo "shfmt installed successfully: $(/usr/local/bin/shfmt --version)" \
        || echo "shfmt installed but version check failed"; \
    else \
        echo "Warning: Failed to download shfmt, continuing without it"; \
    fi

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
    '</fontconfig>' > /etc/fonts/conf.d/99-cc-monospace.conf \
    && fc-cache -f \
    && fc-match monospace \
    && fc-match ui-monospace

# Install Claude Code via official native installer
# NOTE: everything below this line rebuilds on every Claude Code version bump.
# Keep new apt/tooling layers ABOVE it so a routine upgrade stays a fast, cached build.
ARG CLAUDE_VERSION=latest
RUN echo "Installing Claude Code version: ${CLAUDE_VERSION}" && \
    curl -fsSL https://claude.ai/install.sh | bash && \
    install -m 0755 "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude && \
    /usr/local/bin/claude --version && \
    /usr/local/bin/claude --version 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 > /etc/claude-code-version

# Copy entrypoint script (after Claude install so edits don't bust the cache)
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY ccignore-fuse.py /usr/local/bin/ccignore-fuse.py
# entrypoint-fuse.sh is BAKED (not bind-mounted like the sidecar scripts): it is sourced by
# the baked docker-entrypoint.sh and runs as root with SYS_ADMIN, so editing it needs a
# rebuild. Only used by the single-container FUSE mode (macOS / CC_SINGLE_CONTAINER=1).
COPY entrypoint-fuse.sh /usr/local/bin/entrypoint-fuse.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/ccignore-fuse.py \
	&& chmod 0644 /usr/local/bin/entrypoint-fuse.sh

ENV SHELL=/bin/bash
ENV TERM=xterm-256color
ENV DISABLE_AUTOUPDATER=1

# Set entrypoint for user management
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# Default command: Run Claude Code
CMD ["claude", "--dangerously-skip-permissions"]
