FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    unzip \
    ca-certificates \
    procps \
    && curl -fsSL https://get.docker.com | sh \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

# Pre-bake claude-skills so they can be installed into the ~/.claude volume on first run
RUN git clone --depth=1 https://github.com/Jeffallan/claude-skills /opt/claude-skills-staging \
    && rm -rf /opt/claude-skills-staging/.git

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
COPY global-claude.md /opt/global-claude.md
RUN chmod +x /entrypoint.sh /healthcheck.sh

WORKDIR /repos

# No EXPOSE and no ports: `claude remote-control` is outbound-only (HTTPS to
# api.anthropic.com). There is nothing to route and nothing to listen on.
#
# No CMD: the entrypoint IS the application. Claude Code is installed at build
# time by npm above, so — unlike vibe-kanban — there is no `npx` fetch at
# container start and no version pinned in two places.
ENTRYPOINT ["/entrypoint.sh"]
