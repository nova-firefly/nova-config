FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    unzip \
    ca-certificates \
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
COPY global-claude.md /opt/global-claude.md
RUN chmod +x /entrypoint.sh

WORKDIR /repos

ENV HOST=0.0.0.0
ENV PORT=4000

EXPOSE 4000 4001

ENTRYPOINT ["/entrypoint.sh"]
# Pinned to v0.1.43 — the last release before v0.1.44 made Projects
# export-only globally (upstream issue BloopAI/vibe-kanban#3396, no
# maintainer response). Bump only when that regression is reverted.
CMD ["npx", "-y", "vibe-kanban@0.1.43"]
