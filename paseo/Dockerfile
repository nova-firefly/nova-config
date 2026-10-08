# Paseo (getpaseo/paseo) + the agent CLIs it drives.
#
# The official image ships the daemon and web UI but deliberately no agent
# CLIs, so this child image adds them, following upstream's
# docker/Dockerfile.agents.example. `./nova.sh recreate dev paseo` builds with
# --pull --no-cache, which picks up a new Paseo release and new CLI versions.
#
# Every CLI here is a provider Paseo launches natively once it is on PATH:
#   claude (Claude Code)   codex (Codex)   opencode (OpenCode)
#   copilot (GitHub Copilot CLI)          agy (Google Antigravity CLI)
# Account setup for each is a one-time manual step — see context/stacks.md.
FROM ghcr.io/getpaseo/paseo:latest

# Stay root: the base entrypoint fixes ownership of the mounted volumes as root,
# then drops the daemon and every agent it launches to the `paseo` user (uid 1000)
# via gosu.
USER root

# gh: agents open PRs and call the API with it; it is also the git credential
# helper named in the mounted .gitconfig (see dev/compose.yaml).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# The base image sets HOME=/home/paseo, which becomes the paseo_home volume.
# Build steps run as root, so point HOME elsewhere for them: otherwise npm and the
# agy installer leave root-owned caches in /home/paseo that the paseo user then
# cannot write.
RUN HOME=/root npm install -g \
      @anthropic-ai/claude-code \
      @openai/codex \
      opencode-ai \
      @github/copilot \
    && HOME=/root npm cache clean --force

# Antigravity CLI is a single native binary from Google's installer (no npm
# package). --dir puts it on PATH for every user instead of ~/.local/bin.
RUN curl -fsSL https://antigravity.google/cli/install.sh -o /tmp/agy-install.sh \
    && HOME=/root bash /tmp/agy-install.sh --dir /usr/local/bin \
    && rm -rf /tmp/agy-install.sh /root/.cache/antigravity \
    && test -x /usr/local/bin/agy
