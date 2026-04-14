FROM debian:bookworm

# Install Node.js via NodeSource repository and all system dependencies in one layer
RUN apt-get update && apt-get install -y curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
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
    netcat-openbsd telnet dnsutils iputils-ping \
    # Media processing
    ffmpeg \
    # System administration
    gosu procps \
    # Clipboard support (Wayland)
    wl-clipboard \
    # Misc utilities
    tree less file unzip zip \
    # Environment management
    direnv \
    # Required for Claude Code's built-in sandbox
    bubblewrap socat \
    # FUSE runtime for the .ccignore redacting sidecar
    fuse3 libfuse2 \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --break-system-packages --no-cache-dir fusepy \
    && echo 'user_allow_other' > /etc/fuse.conf \
    && echo 'eval "$(direnv hook bash)"' >> /etc/bash.bashrc

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

# Install JavaScript/TypeScript development tools
RUN npm install -g \
    ts-node \
    tsx \
    yarn \
    pnpm

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

# Install Claude Code via official native installer
ARG CLAUDE_VERSION=latest
RUN echo "Installing Claude Code version: ${CLAUDE_VERSION}" && \
    curl -fsSL https://claude.ai/install.sh | bash && \
    install -m 0755 "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude && \
    /usr/local/bin/claude --version && \
    /usr/local/bin/claude --version 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 > /etc/claude-code-version

# Copy entrypoint script (after Claude install so edits don't bust the cache)
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY ccignore-fuse.py /usr/local/bin/ccignore-fuse.py
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/ccignore-fuse.py

# Audio (PulseAudio client for voice mode)
RUN apt-get update && apt-get install -y pulseaudio-utils libpulse0 && rm -rf /var/lib/apt/lists/*

ENV SHELL=/bin/bash
ENV TERM=xterm-256color
ENV DISABLE_AUTOUPDATER=1

# Set entrypoint for user management
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# Default command: Run Claude Code
CMD ["claude", "--dangerously-skip-permissions"]
