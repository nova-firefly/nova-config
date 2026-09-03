#!/bin/sh
set -e

# Forward SIGTERM to the supervised child so `docker stop` shuts the session
# down cleanly instead of waiting out the timeout and being SIGKILLed.
term_handler() {
  echo "[entrypoint] Caught termination signal; stopping remote-control ..."
  if [ -n "${CHILD_PID:-}" ]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  exit 0
}
trap term_handler TERM INT

CLAUDE_DIR="/root/.claude"
CLAUDE_JSON_REAL="${CLAUDE_DIR}/claude.json"
CLAUDE_JSON_LINK="/root/.claude.json"
CREDS="${CLAUDE_DIR}/.credentials.json"
SEED_CREDS="${CLAUDE_DEV_SEED_SOURCE:-/mnt/volumes/dev_vibe-kanban-claude/_data/.credentials.json}"
SKILLS_MARKER="${CLAUDE_DIR}/skills/.jeffallan-installed"

mkdir -p "$CLAUDE_DIR"

# ---------------------------------------------------------------------------
# 1. Persist ~/.claude.json inside the volume.
#
# Claude Code splits its state across two paths: ~/.claude/ (credentials,
# skills, settings) and ~/.claude.json (account metadata, onboarding flags,
# workspace trust). Only the first is covered by the /root/.claude volume, so a
# naive setup loses the second on every container recreate and asks you to log
# in again. Keep the real file in the volume and symlink the expected path to
# it. (This is the unfixed bug in beevelop/docker-claude#6.)
# ---------------------------------------------------------------------------
if [ -f "$CLAUDE_JSON_LINK" ] && [ ! -L "$CLAUDE_JSON_LINK" ]; then
  # Reached only when the path is a REAL file rather than our symlink, which
  # means one of two things — and in both, the real file is the newer state:
  #   - first run on a pre-existing container filesystem, or
  #   - Claude Code rewrote the config via temp-file + rename, which replaces
  #     a symlink with a regular file.
  # So the real file always wins over the volume copy. Doing it the other way
  # round would silently discard a fresh login.
  echo "[entrypoint] Migrating /root/.claude.json into the volume ..."
  mv -f "$CLAUDE_JSON_LINK" "$CLAUDE_JSON_REAL"
fi
[ -f "$CLAUDE_JSON_REAL" ] || echo '{}' > "$CLAUDE_JSON_REAL"
ln -sfn "$CLAUDE_JSON_REAL" "$CLAUDE_JSON_LINK"

# ---------------------------------------------------------------------------
# 2. Install claude-skills into ~/.claude/skills/ on first container run.
#    Skills are pre-baked into the image at /opt/claude-skills-staging.
# ---------------------------------------------------------------------------
if [ ! -f "$SKILLS_MARKER" ]; then
  echo "[entrypoint] Installing claude-skills into ${CLAUDE_DIR}/skills/ ..."
  mkdir -p "${CLAUDE_DIR}/skills"
  cp -r /opt/claude-skills-staging/skills/. "${CLAUDE_DIR}/skills/"
  touch "$SKILLS_MARKER"
  echo "[entrypoint] claude-skills installed."
fi

# ---------------------------------------------------------------------------
# 3. Write global CLAUDE.md with auto-skill activation instructions.
#    Always overwrite so updates to the image are picked up on restart.
# ---------------------------------------------------------------------------
cp /opt/global-claude.md "${CLAUDE_DIR}/CLAUDE.md"

# ---------------------------------------------------------------------------
# 4. Seed onboarding + workspace trust.
#
# Remote Control refuses to serve an untrusted workspace, and there is no way
# to accept the trust dialog from a phone. Merge (never overwrite) — this file
# also holds the OAuth account metadata written by `claude /login`.
# ---------------------------------------------------------------------------
node -e "
  const fs = require('fs');
  const path = '${CLAUDE_JSON_REAL}';
  let config = {};
  try { config = JSON.parse(fs.readFileSync(path, 'utf8')); } catch (e) {}
  config.hasCompletedOnboarding = true;
  config.remoteDialogSeen = true;
  config.projects = config.projects || {};
  for (const ws of ['/repos', '/repos/nova-config']) {
    config.projects[ws] = config.projects[ws] || {};
    config.projects[ws].hasTrustDialogAccepted = true;
    config.projects[ws].allowedTools = config.projects[ws].allowedTools || [];
  }
  fs.writeFileSync(path, JSON.stringify(config, null, 2));
"
echo "[entrypoint] Onboarding + workspace trust seeded in ~/.claude.json"

# ---------------------------------------------------------------------------
# 5. Credential bootstrap (optional, first run only).
#
# Remote Control accepts ONLY an interactive OAuth login — no API key, no
# `claude setup-token` token — so there is no declarative way to authenticate.
# vibe-kanban's config volume is visible read-only under /mnt/volumes, and it
# already holds a valid login, so copy it once to make first boot zero-touch.
#
# Caveat: both containers then hold the SAME refresh token. If the token is
# rotated on use, whichever container refreshes second can be logged out. Set
# CLAUDE_DEV_SEED_CREDENTIALS=false and run the login below to get an
# independent credential.
# ---------------------------------------------------------------------------
if [ ! -s "$CREDS" ] && [ "${CLAUDE_DEV_SEED_CREDENTIALS:-true}" != "false" ] && [ -s "$SEED_CREDS" ]; then
  echo "[entrypoint] No credentials yet — seeding from ${SEED_CREDS}"
  echo "[entrypoint] NOTE: this shares one OAuth refresh token with vibe-kanban."
  echo "[entrypoint]       If it gets rotated out, set CLAUDE_DEV_SEED_CREDENTIALS=false"
  echo "[entrypoint]       and log in independently."
  cp "$SEED_CREDS" "$CREDS"
  chmod 600 "$CREDS"
fi

# ---------------------------------------------------------------------------
# 6. Credential gate. Wait rather than hot-looping remote-control against a
#    logged-out state (which would spin and spam the API).
# ---------------------------------------------------------------------------
while [ ! -s "$CREDS" ]; do
  echo "[entrypoint] ============================================================"
  echo "[entrypoint] Not logged in. Claude Code Remote Control requires a one-time"
  echo "[entrypoint] interactive OAuth login (API keys are not supported)."
  echo "[entrypoint]"
  echo "[entrypoint]   docker exec -it claude-dev claude"
  echo "[entrypoint]   then: /login   — complete in a browser, then exit"
  echo "[entrypoint]"
  echo "[entrypoint] No shell on the host? shell.\${NOVA_DOMAIN} is a browser"
  echo "[entrypoint] terminal (Authelia 2FA) that gets you there from any device."
  echo "[entrypoint] Re-checking every 60s ..."
  echo "[entrypoint] ============================================================"
  sleep 60
done

# ---------------------------------------------------------------------------
# 7. Supervisor loop.
#
# In server mode Claude Code gives up and exits after roughly 10 minutes of
# network outage, so an unsupervised container would silently go offline and
# stay offline. `--continue` rejoins the session the previous run created
# (valid for ~4h after it stopped) instead of spawning a duplicate.
# ---------------------------------------------------------------------------
echo "[entrypoint] Starting claude remote-control (session: ${CLAUDE_DEV_SESSION_NAME:-nova})"
while true; do
  # Run in the background and `wait` so the SIGTERM trap above can fire —
  # a foreground child would block signal handling until it returned.
  # shellcheck disable=SC2086  # CLAUDE_DEV_EXTRA_ARGS is intentionally word-split
  claude remote-control --continue \
    --name "${CLAUDE_DEV_SESSION_NAME:-nova}" \
    --permission-mode "${CLAUDE_DEV_PERMISSION_MODE:-acceptEdits}" \
    ${CLAUDE_DEV_EXTRA_ARGS:-} &
  CHILD_PID=$!
  wait "$CHILD_PID" || rc=$?
  echo "[entrypoint] remote-control exited (${rc:-0}); restarting in 10s"
  unset rc CHILD_PID
  sleep 10
done
