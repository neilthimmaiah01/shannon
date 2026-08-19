#
# Multi-stage Dockerfile for Pentest Agent
# Uses Chainguard Wolfi for minimal attack surface and supply chain security

# Builder stage - Install tools and dependencies
FROM cgr.dev/chainguard/wolfi-base:latest AS builder

# Install system dependencies available in Wolfi
RUN apk update && apk add --no-cache \
    # Core build tools
    build-base \
    git \
    curl \
    wget \
    ca-certificates \
    # Language runtimes
    nodejs-22 \
    npm \
    # Additional utilities
    bash

# Install pnpm
RUN npm install -g --ignore-scripts pnpm@10.33.0

# Build Node.js application in builder to avoid QEMU emulation failures in CI
WORKDIR /app

# Copy workspace manifests for install layer caching
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY apps/worker/package.json ./apps/worker/
COPY apps/cli/package.json ./apps/cli/

RUN pnpm install --frozen-lockfile

COPY . .

# Build worker. CLI not needed in Docker
RUN pnpm --filter @shannon/worker run build

# Production-only deps (pnpm recommends install --prod over prune in monorepos)
RUN rm -rf node_modules apps/*/node_modules && pnpm install --frozen-lockfile --prod

# Runtime stage - Minimal production image
FROM cgr.dev/chainguard/wolfi-base:latest AS runtime

# Install only runtime dependencies
USER root
RUN apk update && apk add --no-cache \
    # Core utilities
    git \
    bash \
    curl \
    ca-certificates \
    shadow \
    # Language runtimes (minimal)
    nodejs-22 \
    npm \
    python3 \
    # Chromium browser and dependencies for Playwright
    chromium \
    # Additional libraries Chromium needs
    nss \
    freetype \
    harfbuzz \
    # X11 libraries for headless browser
    libx11 \
    libxcomposite \
    libxdamage \
    libxext \
    libxfixes \
    libxrandr \
    mesa-gbm \
    # Font rendering
    fontconfig \
    unzip \
    glibc-locale-en \ 
    php-8.1 

# Install Semgrep for static taint analysis
RUN python3 -m ensurepip --upgrade 2>/dev/null; \
    python3 -m pip install semgrep==1.70.0

# Copy Shannon's custom Semgrep rules into the image
COPY apps/worker/prompts/rules/ /opt/shannon/rules/

# Install Java 17 (Temurin aarch64 binary — required by Joern)
RUN mkdir -p /opt/java && \
    curl -L "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.10%2B7/OpenJDK17U-jdk_aarch64_linux_hotspot_17.0.10_7.tar.gz" \
    -o /tmp/jdk.tar.gz && \
    tar -xzf /tmp/jdk.tar.gz -C /opt/java --strip-components=1 && \
    rm /tmp/jdk.tar.gz
ENV JAVA_HOME=/opt/java
ENV PATH="/opt/java/bin:$PATH"

# Install Joern CPG tool
RUN mkdir -p /opt/joern /usr/local/bin && \
    curl -L "https://github.com/joernio/joern/releases/download/v2.0.406/joern-cli.zip" \
    -o /tmp/joern-cli.zip && \
    unzip /tmp/joern-cli.zip -d /opt/joern && \
    rm /tmp/joern-cli.zip && \
    ln -sf /opt/joern/joern-cli/joern /usr/local/bin/joern && \
    ln -sf /opt/joern/joern-cli/joern-parse /usr/local/bin/joern-parse

# Patch php-parser phar to fix $argv issue in PHP 8.x
RUN php -d phar.readonly=0 /opt/joern/joern-cli/frontends/php2cpg/bin/php-parser/php-parser-4.15.8.phar 2>/dev/null; \
    sed -i 's/list(\$operations, \$files, \$attributes) = parseArgs(\$argv);/global \$argv; list(\$operations, \$files, \$attributes) = parseArgs(\$argv);/' \
    /tmp/pharextract/php-parser-4.15.8/bin/php-parse && \
    cp /opt/joern/joern-cli/frontends/php2cpg/bin/php-parser/php-parser.php \
    /opt/joern/joern-cli/frontends/php2cpg/bin/php-parser/php-parser.php.bak && \
    echo '<?php require("/tmp/pharextract/php-parser-4.15.8/bin/php-parse");?>' > \
    /opt/joern/joern-cli/frontends/php2cpg/bin/php-parser/php-parser.php

# Create non-root user
RUN addgroup -g 1001 pentest && \
    adduser -u 1001 -G pentest -s /bin/bash -D pentest

# System-level git config (survives UID remapping in entrypoint)
RUN git config --system user.email "agent@localhost" && \
    git config --system user.name "Pentest Agent" && \
    git config --system --add safe.directory '*'

# Set working directory
WORKDIR /app

# Copy only what the worker needs (skip CLI source, infra, tsdown artifacts)
COPY --from=builder /app/package.json /app/pnpm-workspace.yaml /app/pnpm-lock.yaml /app/.npmrc /app/
COPY --from=builder /app/node_modules /app/node_modules
COPY --from=builder /app/apps/worker /app/apps/worker
COPY --from=builder /app/apps/cli/package.json /app/apps/cli/package.json

RUN npm install -g --ignore-scripts @playwright/cli@0.1.1
RUN mkdir -p /tmp/.claude/skills && \
    playwright-cli install --skills && \
    cp -r .claude/skills/playwright-cli /tmp/.claude/skills/ && \
    rm -rf .claude

# Symlink CLI tools onto PATH
RUN ln -s /app/apps/worker/dist/scripts/save-deliverable.js /usr/local/bin/save-deliverable && \
    chmod +x /app/apps/worker/dist/scripts/save-deliverable.js && \
    ln -s /app/apps/worker/dist/scripts/generate-totp.js /usr/local/bin/generate-totp && \
    chmod +x /app/apps/worker/dist/scripts/generate-totp.js && \
    ln -s /app/apps/worker/dist/scripts/set-report-meta.js /usr/local/bin/set-report-meta && \
    chmod +x /app/apps/worker/dist/scripts/set-report-meta.js

# Create directories for session data and ensure proper permissions
RUN mkdir -p /app/sessions /app/repos /app/workspaces && \
    mkdir -p /tmp/.cache /tmp/.config /tmp/.npm && \
    chmod 777 /app && \
    chmod 777 /tmp/.cache && \
    chmod 777 /tmp/.config && \
    chmod 777 /tmp/.npm && \
    chown -R pentest:pentest /app /tmp/.claude

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Set environment variables
ENV NODE_ENV=production
ENV PATH="/usr/local/bin:$PATH"
ENV SHANNON_DOCKER=true
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_MCP_EXECUTABLE_PATH=/usr/bin/chromium-browser
ENV npm_config_cache=/tmp/.npm
ENV HOME=/tmp
ENV XDG_CACHE_HOME=/tmp/.cache
ENV XDG_CONFIG_HOME=/tmp/.config
ENV NODE_ENV=production
ENV PATH="/usr/local/bin:$PATH"
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["node", "apps/worker/dist/temporal/worker.js"]
