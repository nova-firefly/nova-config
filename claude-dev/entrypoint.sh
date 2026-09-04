#!/bin/sh
set -e

CLAUDE_DIR="/root/.claude"
CLAUDE_JSON_REAL="${CLAUDE_DIR}/claude.json"
CLAUDE_JSON_LINK="/root/.claude.json"
CREDS="${CLAUDE_DIR}/.credentials.json"
SEED_CREDS="${CLAUDE_DEV_SEED_SOURCE:-/mnt/volumes/dev_vibe-kanban-claude/_data/.credentials.json}"
SKILLS_MARKER="${CLAUDE_DIR}/skills/.jeffallan-installed"
REPOS_ROOT="${CLAUDE_DEV_REPOS_ROOT:-/repos}"
EXPECTED_FILE="/run/claude-dev-expected"

# PIDs of the supervisor subshells, one per server. Space separated.
CHILD_PIDS=""

# Forward SIGTERM to every supervisor so `docker stop` shuts all the servers
# down cleanly instead of waiting out the timeout and being SIGKILLed.
term_handler() {
  echo "[entrypoint] Caught termination signal; stopping all servers ..."
  for p in $CHILD_PIDS; do
    kill -TERM "$p" 2>/dev/null || true
  done
  for p in $CHILD_PIDS; do
    wait "$p" 2>/dev/null || true
  done
  exit 0
}
trap term_handler TERM INT

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
# 4. Discover repos.
#
# One `claude remote-control` server per git checkout under $REPOS_ROOT. The
# server's working directory decides where its sessions live, and --spawn
# worktree needs that directory to BE a git repo — $REPOS_ROOT itself is just a
# folder of checkouts, so a single server rooted there could only ever run
# --spawn same-dir, where concurrent sessions edit one tree and conflict.
#
# CLAUDE_DEV_REPOS (space separated names) narrows the set; unset discovers all.
# ---------------------------------------------------------------------------
REPOS=""
SERVER_COUNT=0

is_git_repo() {
  # .git is a directory in a normal clone and a file inside a worktree.
  [ -e "$1/.git" ]
}

if [ -n "${CLAUDE_DEV_REPOS:-}" ]; then
  for name in $CLAUDE_DEV_REPOS; do
    if is_git_repo "${REPOS_ROOT}/${name}"; then
      REPOS="${REPOS} ${name}"
      SERVER_COUNT=$((SERVER_COUNT + 1))
    else
      echo "[entrypoint] WARNING: CLAUDE_DEV_REPOS names '${name}', but ${REPOS_ROOT}/${name} is not a git repo — skipping."
    fi
  done
else
  for dir in "${REPOS_ROOT}"/*/; do
    [ -d "$dir" ] || continue
    is_git_repo "${dir%/}" || continue
    name=$(basename "${dir%/}")
    REPOS="${REPOS} ${name}"
    SERVER_COUNT=$((SERVER_COUNT + 1))
  done
fi

if [ "$SERVER_COUNT" -eq 0 ]; then
  # An empty /repos must not make the container useless — fall back to a single
  # server at the root. It has to be same-dir: worktree mode requires a git repo
  # and $REPOS_ROOT is not one.
  echo "[entrypoint] WARNING: no git repos found under ${REPOS_ROOT}."
  echo "[entrypoint]          Falling back to one --spawn same-dir server there."
  echo "[entrypoint]          Clone a repo into ${REPOS_ROOT} and restart for per-repo servers."
  REPOS="."
  SERVER_COUNT=1
  SPAWN_MODE="same-dir"
else
  SPAWN_MODE="worktree"
  echo "[entrypoint] Found ${SERVER_COUNT} repo(s):${REPOS}"
fi

# ---------------------------------------------------------------------------
# 5. Seed onboarding + per-repo workspace trust.
#
# Trust is keyed on the GIT REPOSITORY ROOT, and trusting a parent covers
# subdirectories "apart from a git repository nested inside it" — so trusting
# $REPOS_ROOT does NOT cover the checkouts inside it. Every repo needs its own
# entry or its first session stops on a trust prompt no phone can answer.
#
# Merge, never overwrite: this file also holds the OAuth account metadata.
# ---------------------------------------------------------------------------
TRUST_PATHS="$REPOS_ROOT"
for name in $REPOS; do
  if [ "$name" = "." ]; then continue; fi
  TRUST_PATHS="${TRUST_PATHS} ${REPOS_ROOT}/${name}"
done

CLAUDE_JSON_REAL="$CLAUDE_JSON_REAL" TRUST_PATHS="$TRUST_PATHS" node -e '
  const fs = require("fs");
  const path = process.env.CLAUDE_JSON_REAL;
  let config = {};
  try { config = JSON.parse(fs.readFileSync(path, "utf8")); } catch (e) {}
  config.hasCompletedOnboarding = true;
  config.remoteDialogSeen = true;
  config.projects = config.projects || {};
  for (const ws of process.env.TRUST_PATHS.trim().split(/\s+/)) {
    config.projects[ws] = config.projects[ws] || {};
    config.projects[ws].hasTrustDialogAccepted = true;
    config.projects[ws].allowedTools = config.projects[ws].allowedTools || [];
  }
  fs.writeFileSync(path, JSON.stringify(config, null, 2));
'
echo "[entrypoint] Onboarding + workspace trust seeded for:${TRUST_PATHS}"

# ---------------------------------------------------------------------------
# 6. Credential bootstrap (optional, first run only).
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
# 7. Credential gate. Wait rather than hot-looping remote-control against a
#    logged-out state (which would spin and spam the API), once per server.
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
# 8. Supervise one server per repo.
#
# In server mode Claude Code gives up and exits after roughly 10 minutes of
# network outage, so an unsupervised server would silently go offline and stay
# offline. Each repo gets its own relaunch loop.
#
# NOTE: --continue is deliberately absent. The docs are explicit that it "can't
# be combined with --session-id, --spawn, --capacity, or --create-session-in-dir",
# and this uses --spawn, so passing it would be rejected outright.
#
# --create-session-in-dir is left at its default (on): in worktree mode that
# pre-created session stays in the repo root so there is always somewhere to
# type, while every on-demand session spawned from the app gets its own
# worktree under <repo>/.claude/worktrees/ on a `worktree-<name>` branch.
# ---------------------------------------------------------------------------
# Forward a supervisor subshell's TERM down to the server it owns. Without
# this the top-level handler would kill the supervisor and orphan the claude
# process underneath it, leaving it to be SIGKILLed at the stop timeout.
supervise_term() {
  if [ -n "${_child:-}" ]; then
    kill -TERM "$_child" 2>/dev/null || true
    wait "$_child" 2>/dev/null || true
  fi
  exit 0
}

supervise() {
  # $1 = working directory, $2 = display name
  _dir="$1"
  _name="$2"
  cd "$_dir" || exit 1

  _child=""
  trap supervise_term TERM INT

  while true; do
    # Background + wait so the trap above can fire while the server runs.
    # shellcheck disable=SC2086  # CLAUDE_DEV_EXTRA_ARGS is intentionally word-split
    claude remote-control \
      --spawn "$SPAWN_MODE" \
      --name "$_name" \
      --remote-control-session-name-prefix "$_name" \
      --permission-mode "${CLAUDE_DEV_PERMISSION_MODE:-acceptEdits}" \
      ${CLAUDE_DEV_EXTRA_ARGS:-} &
    _child=$!
    _rc=0
    wait "$_child" || _rc=$?
    _child=""
    echo "[entrypoint] [${_name}] remote-control exited (${_rc}); restarting in 10s"
    sleep 10
  done
}

mkdir -p "$(dirname "$EXPECTED_FILE")"
echo "$SERVER_COUNT" > "$EXPECTED_FILE"

for name in $REPOS; do
  if [ "$name" = "." ]; then
    dir="$REPOS_ROOT"
    label="${CLAUDE_DEV_SESSION_NAME:-nova}"
  else
    dir="${REPOS_ROOT}/${name}"
    label="$name"
  fi
  echo "[entrypoint] Starting server: ${label} (${dir}, --spawn ${SPAWN_MODE})"
  supervise "$dir" "$label" &
  CHILD_PIDS="${CHILD_PIDS} $!"
done

# ---------------------------------------------------------------------------
# 9. Re-adopt sessions the app spawned into worktrees.
#
# The per-repo servers above create sessions but never re-attach to them. On
# restart each server only re-creates its own ROOT session — that ID is derived
# from the directory, so it comes back and looks like a resume — while every
# session spawned from the app is orphaned: worktree, branch and transcript all
# survive on disk, but nothing serves them, so they vanish from claude.ai.
#
# --continue cannot fix this. The "last session" record is keyed to the
# directory the SERVER ran in (the repo root), so --continue from inside a
# worktree resolves to the ROOT session and is then refused as already served.
# --session-id takes the claude.ai session ID, and the spawner encodes exactly
# that in the directory name — .claude/worktrees/bridge-cse_<id> — so the ID is
# recoverable from disk with no extra bookkeeping. Worktrees not named that way
# (hand-made, or renamed) carry no ID and are skipped.
#
# Three deliberate limits:
#   - No relaunch loop. --session-id implies single-session mode and exits when
#     the session ends, so a supervisor would resurrect finished sessions
#     forever. One attempt each, failures logged and skipped, never fatal.
#   - Adoption only works for ~4h after the server stopped. Worktrees accumulate
#     and most are long dead, so only those whose transcript was touched inside
#     that window are tried — otherwise every boot would spawn a doomed process
#     per worktree ever created.
#   - Adopters are NOT counted in $EXPECTED_FILE. The healthcheck compares with
#     -ge, so the extra processes are harmless, and a finished session exiting
#     must not turn the container unhealthy.
# ---------------------------------------------------------------------------
# Transcripts live in ~/.claude/projects/<path with / . _ all mapped to ->.
transcript_dir_for() {
  echo "${CLAUDE_DIR}/projects/$(echo "$1" | tr '/._' '---')"
}

adopt_term() {
  if [ -n "${_adopted:-}" ]; then
    kill -TERM "$_adopted" 2>/dev/null || true
    wait "$_adopted" 2>/dev/null || true
  fi
  exit 0
}

# Mirrors supervise(): background + wait so the trap can fire mid-session.
adopt_session() {
  # $1 = worktree dir, $2 = claude.ai session id, $3 = display name
  _dir="$1"
  _sid="$2"
  _name="$3"
  cd "$_dir" || exit 1

  _adopted=""
  trap adopt_term TERM INT

  # shellcheck disable=SC2086  # CLAUDE_DEV_EXTRA_ARGS is intentionally word-split
  claude remote-control \
    --session-id "$_sid" \
    --name "$_name" \
    --permission-mode "${CLAUDE_DEV_PERMISSION_MODE:-acceptEdits}" \
    ${CLAUDE_DEV_EXTRA_ARGS:-} &
  _adopted=$!
  _rc=0
  wait "$_adopted" || _rc=$?
  _adopted=""

  if [ "$_rc" -ne 0 ]; then
    echo "[entrypoint] [${_name}] could not re-adopt ${_sid} (exit ${_rc}); reopen it from the app if you still need it"
  fi
}

ADOPTED=0
for name in $REPOS; do
  if [ "$name" = "." ]; then
    dir="$REPOS_ROOT"
    label="${CLAUDE_DEV_SESSION_NAME:-nova}"
  else
    dir="${REPOS_ROOT}/${name}"
    label="$name"
  fi

  for wt in "${dir}"/.claude/worktrees/bridge-cse_*; do
    # An unmatched glob stays literal in POSIX sh; -d filters it out.
    [ -d "$wt" ] || continue

    # Skip anything outside the ~4h adoption window (see above). No transcript
    # touched recently means the session is dead; do not waste a process on it.
    tdir=$(transcript_dir_for "$wt")
    [ -d "$tdir" ] || continue
    [ -n "$(find "$tdir" -maxdepth 1 -name '*.jsonl' -mmin -240 2>/dev/null | head -n 1)" ] || continue

    sid="session_${wt##*/bridge-cse_}"
    echo "[entrypoint] [${label}] re-adopting ${sid} (${wt})"
    adopt_session "$wt" "$sid" "$label" &
    CHILD_PIDS="${CHILD_PIDS} $!"
    ADOPTED=$((ADOPTED + 1))
  done
done

if [ "$ADOPTED" -gt 0 ]; then
  echo "[entrypoint] Re-adopted ${ADOPTED} worktree session(s)."
fi

echo "[entrypoint] ${SERVER_COUNT} server(s) running. Waiting."
wait
