#!/usr/bin/env bash
# trigger-wrapper.sh — Kometa entrypoint wrapper
#
# Replaces the kometa container's default entrypoint.  Runs Kometa on the
# configured daily schedule AND immediately whenever the webhook server drops
# a trigger file at $TRIGGER_FILE (written by the kometa-webhook container via
# the shared ./kometa-trigger bind-mount).
#
# Concurrency: flock ensures only one kometa process runs at a time.
# If a trigger arrives while a run is in progress it is silently dropped;
# the next scheduled run (or future trigger) will catch up.

set -euo pipefail

TRIGGER_FILE="${TRIGGER_FILE:-/trigger/run}"
LOCK_FILE="${TRIGGER_FILE}.lock"
SCHEDULE="${KOMETA_TIME:-05:00}"

log() { echo "[kometa-wrapper] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

cleanup() {
  rm -f "$LOCK_FILE"
  # Terminate the background trigger-watcher subshell group.
  kill -- "-$$" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Remove any stale lock left by a previous crash.
rm -f "$LOCK_FILE"

# ---------------------------------------------------------------------------
# run_kometa <reason>
#   Acquires an exclusive non-blocking flock, then runs kometa --run.
#   Returns immediately (without running) if another run already holds the lock.
# ---------------------------------------------------------------------------
run_kometa() {
  local reason="$1"
  (
    if ! flock -n 9; then
      log "[$reason] Another run is already in progress — skipping"
      exit 0
    fi
    log "[$reason] Starting kometa run..."
    python3 /app/kometa.py --config /config/config.yml --run 2>&1 || true
    log "[$reason] Run complete"
  ) 9>"$LOCK_FILE"
}

# ---------------------------------------------------------------------------
# Background: watch for trigger file written by kometa-webhook.
# ---------------------------------------------------------------------------
(
  while true; do
    if [[ -f "$TRIGGER_FILE" ]]; then
      rm -f "$TRIGGER_FILE"
      run_kometa "webhook"
    fi
    sleep 5
  done
) &

log "Started. Daily schedule: $SCHEDULE | trigger file: $TRIGGER_FILE"

# ---------------------------------------------------------------------------
# Main loop: daily scheduler.
# Tracks the calendar date of the last scheduled run so the same minute is
# never triggered twice (even if the loop wakes more than once per minute).
# ---------------------------------------------------------------------------
_last_run_date=""
while true; do
  _today=$(date '+%Y-%m-%d')
  _now=$(date '+%H:%M')
  if [[ "$_now" == "$SCHEDULE" && "$_today" != "$_last_run_date" ]]; then
    _last_run_date="$_today"
    run_kometa "scheduled"
  fi
  sleep 30
done
