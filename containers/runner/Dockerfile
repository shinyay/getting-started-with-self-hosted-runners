# -------------------------------------------------------
# GitHub Actions Self-Hosted Runner — Container Image
# -------------------------------------------------------
FROM ubuntu:22.04

ARG RUNNER_VERSION=2.333.1
ARG RUNNER_ARCH=x64

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    git \
    docker.io \
    build-essential \
    libssl-dev \
    libffi-dev \
    python3 \
    zip \
    unzip \
    ca-certificates \
    apt-transport-https \
    libyaml-0-2 \
    # Playwright Chromium runtime libraries (sudoless self-hosted runners
    # cannot run `playwright install --with-deps`, so we bake them in).
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    libatspi2.0-0 \
    libwayland-client0 \
    fonts-liberation \
    fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (`gh`) for workflow steps that auto-create or merge PRs.
# Uses the official cli.github.com apt repository.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Create non-root runner user
RUN useradd -m -u 1000 -s /bin/bash runner

# Set up runner directory
WORKDIR /home/runner/actions-runner

# Download and extract GitHub Actions runner
RUN curl -fsSL \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
      -o actions-runner.tar.gz \
    && tar xzf actions-runner.tar.gz \
    && rm actions-runner.tar.gz

# Install runner dependencies
RUN ./bin/installdependencies.sh

# Copy entrypoint script
COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

# Set ownership
RUN chown -R runner:runner /home/runner

# Pre-create hostedtoolcache for actions that hardcode this path
# (e.g. ruby/setup-ruby, which ignores RUNNER_TOOL_CACHE).
RUN mkdir -p /opt/hostedtoolcache && chown -R runner:runner /opt/hostedtoolcache

# Switch to non-root user
USER runner

ENTRYPOINT ["./entrypoint.sh"]
