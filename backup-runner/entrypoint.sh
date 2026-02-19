#!/bin/sh
# backup-runner/entrypoint.sh
#
# Runs backup plans via the Backrest API on a weekly schedule (Monday 4am).
# Before each attempt, checks that the SFTP host is reachable.
# Retries every 6 hours until success or the next weekly window.
# Sends a Discord alert after 3 consecutive failures.
#
# Environment variables (set in docker-compose):
#   SFTP_HOST           - SFTP destination hostname/IP
#   SFTP_PORT           - SFTP port (default: 22)
#   BACKREST_URL        - Backrest API base URL (default: http://backrest:9898)
#   DISCORD_WEBHOOK_URL - Optional Discord webhook for failure notifications

set -eu

SFTP_HOST="${SFTP_HOST:-}"
SFTP_PORT="${SFTP_PORT:-22}"
BACKREST_URL="${BACKREST_URL:-http://backrest:9898}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

RETRY_INTERVAL_SECONDS=21600  # 6 hours
PLANS="plex-config immich-data"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

notify_discord() {
    msg="$1"
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -s -X POST "$DISCORD_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"content\": \"**Backup Runner** $msg\"}" \
            >/dev/null 2>&1 || true
    fi
}

check_sftp_host() {
    if [ -z "$SFTP_HOST" ]; then
        log "ERROR: SFTP_HOST is not set"
        return 1
    fi
    ssh -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        -p "$SFTP_PORT" \
        -i /root/.ssh/id_ed25519 \
        "${SFTP_USER:-backup}@${SFTP_HOST}" \
        "echo ok" >/dev/null 2>&1
}

dump_immich_postgres() {
    log "Dumping Immich postgres database..."
    # Clear previous dump
    rm -f /immich-db-dump/immich.sql

    # Run pg_dumpall inside the running immich_postgres container
    if ! docker exec immich_postgres pg_dumpall -U postgres > /immich-db-dump/immich.sql 2>/tmp/pg_dump_err; then
        log "ERROR: pg_dumpall failed: $(cat /tmp/pg_dump_err)"
        return 1
    fi
    log "Postgres dump complete ($(du -sh /immich-db-dump/immich.sql | cut -f1))"
}

trigger_plan() {
    plan_id="$1"
    log "Triggering backup plan: $plan_id"

    # POST to Backrest API to start a backup for the given plan
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${BACKREST_URL}/api/v1/plan/${plan_id}/backup" \
        -H "Content-Type: application/json" \
        -d '{}')
    http_code=$(printf '%s' "$response" | tail -n1)
    body=$(printf '%s' "$response" | head -n-1)

    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        log "ERROR: Backrest API returned HTTP $http_code for plan $plan_id: $body"
        return 1
    fi

    # Extract operation ID and poll for completion
    op_id=$(printf '%s' "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -z "$op_id" ]; then
        log "WARNING: Could not extract operation ID from response, assuming success"
        return 0
    fi

    log "Waiting for operation $op_id to complete..."
    for _ in $(seq 1 720); do  # poll up to 1 hour (5s intervals)
        sleep 5
        status_resp=$(curl -s "${BACKREST_URL}/api/v1/operation/${op_id}" 2>/dev/null || echo '{}')
        status=$(printf '%s' "$status_resp" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        case "$status" in
            "STATUS_SUCCESS")
                log "Plan $plan_id completed successfully"
                return 0
                ;;
            "STATUS_ERROR"|"STATUS_SYSTEM_ERROR")
                log "ERROR: Plan $plan_id failed with status: $status"
                log "Response: $status_resp"
                return 1
                ;;
            "STATUS_INPROGRESS"|"STATUS_PENDING"|"")
                # still running, keep polling
                ;;
            *)
                log "WARNING: Unknown status '$status' for plan $plan_id"
                ;;
        esac
    done

    log "ERROR: Timed out waiting for plan $plan_id to complete"
    return 1
}

run_all_backups() {
    log "=== Starting backup run ==="

    # Check SFTP reachability before doing any work
    if ! check_sftp_host; then
        log "SFTP host $SFTP_HOST:$SFTP_PORT is not reachable, skipping backup"
        return 1
    fi
    log "SFTP host is reachable"

    # Dump Immich postgres before backing up
    if ! dump_immich_postgres; then
        log "Aborting backup: postgres dump failed"
        return 1
    fi

    # Run each plan sequentially
    failed=""
    for plan in $PLANS; do
        if ! trigger_plan "$plan"; then
            failed="${failed} ${plan}"
        fi
    done

    if [ -n "$failed" ]; then
        log "Plans failed:${failed}"
        return 1
    fi

    log "=== All backup plans completed successfully ==="
    notify_discord ":white_check_mark: Weekly backup completed successfully"
    return 0
}

# --- Main cron loop ---
# Runs weekly on Monday 4am, retrying every 6h on failure until the next Monday.
# Sends a Discord alert after 3 consecutive failures.

log "Backup runner started. Waiting for Monday 4am schedule..."

# Track the ISO week of the last successful run to avoid double-runs
last_run_week=""

while true; do
    now=$(date '+%u %H %V')  # day_of_week(1=Mon) hour iso_week
    dow=$(echo "$now" | awk '{print $1}')
    hour=$(echo "$now" | awk '{print $2}')
    week=$(echo "$now" | awk '{print $3}')

    # It's Monday (1) and at or after 4am
    if [ "$dow" = "1" ] && [ "$hour" -ge 4 ] && [ "$week" != "$last_run_week" ]; then
        log "Scheduled backup window: Monday $hour:xx (week $week)"
        attempt=0
        while true; do
            attempt=$((attempt + 1))
            log "Attempt $attempt..."
            if run_all_backups; then
                last_run_week="$week"
                log "Backup succeeded on attempt $attempt. Next run: next Monday at 4am."
                sleep 604800  # 7 days - will re-align on wake
                break
            fi

            log "Attempt $attempt failed. Retrying in 6 hours..."

            if [ "$attempt" -eq 3 ]; then
                notify_discord ":rotating_light: Backup has failed **3 times** this week (attempts so far: $attempt). Will keep retrying every 6 hours. Check Backrest logs."
            fi

            sleep "$RETRY_INTERVAL_SECONDS"

            # If we've crossed into a new week, give up and wait for next Monday
            new_week=$(date '+%V')
            if [ "$new_week" != "$week" ]; then
                log "New week started without a successful backup. Resetting for next Monday."
                notify_discord ":x: Backup never succeeded this week after $attempt attempts. Will retry next Monday."
                break
            fi
        done
    else
        # Sleep 60s between schedule checks (lightweight polling)
        sleep 60
    fi
done
