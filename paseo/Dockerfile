# Paseo (getpaseo/paseo) + the agent CLIs it drives.
#
# The official image ships the daemon and web UI but deliberately no agent
# CLIs, so this child image adds them, following upstream's
# docker/Dockerfile.agents.example. `./nova.sh recreate dev paseo` builds with
# --pull --no-cache, which picks up both a new Paseo release and new CLI versions.
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

RUN npm install -g @anthropic-ai/claude-code @openai/codex \
    && npm cache clean --force
