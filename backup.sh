#!/usr/bin/env bash
#
# b2-backup.sh — Daily backup of homelab folders to Backblaze B2 via rclone.
#
# One-time setup (see the chat message for full details):
#   1. Install rclone:   curl https://rclone.org/install.sh | sudo bash
#   2. Create a B2 bucket + Application Key in the Backblaze web console.
#   3. Configure the remote: `rclone config`  (name it to match REMOTE below).
#   4. Edit the CONFIG section below.
#   5. chmod +x b2-backup.sh   and schedule it for 06:00 with cron or systemd.

set -euo pipefail

### ─── CONFIG ──────────────────────────────────────────────────────────────

# rclone remote name (must match what you created with `rclone config`).
REMOTE="b2-backup"

# Destination B2 bucket (create it in the Backblaze console first).
BUCKET="homelab-backup-adhithirumala"

# Folders to back up. Each is mirrored into the bucket preserving its path,
# e.g. /srv/data  ->  b2:my-homelab-backup/srv/data
# No trailing slashes. Add/remove lines freely.
SOURCES=(
  "/home/ubuntu/vaultwarden"
)

# Number of parallel transfers. B2 likes 8–32; rclone's default of 4 is too slow.
TRANSFERS=16

# Where to write logs.
LOG_DIR="/var/log/b2-backup"

# Path to the rclone config. IMPORTANT: this must be the config belonging to the
# user the cron/systemd job runs as. Under root cron, use /root/.config/...
RCLONE_CONFIG="/home/ubuntu/.config/rclone/rclone.conf"

# Optional: a Healthchecks.io ping URL so you get emailed/notified if a backup
# fails or stops running. Create a free check at https://healthchecks.io and
# paste its ping URL here. Leave empty ("") to disable.
HEALTHCHECK_URL=""

### ─── END CONFIG ──────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/backup-$(date +%F).log"

# Keep only the last 30 days of logs.
find "$LOG_DIR" -name 'backup-*.log' -mtime +30 -delete 2>/dev/null || true

timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"; }

ping_hc() {  # $1 = optional path suffix like /start or /fail
  [[ -n "$HEALTHCHECK_URL" ]] || return 0
  curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}${1:-}" >/dev/null 2>&1 || true
}

# Stop two backups overlapping (e.g. a slow run still going at the next 06:00).
exec 9>"/tmp/b2-backup.lock"
if ! flock -n 9; then
  log "Another backup is still running — exiting."
  exit 1
fi

ping_hc "/start"
log "===== Backup started ====="

failed=0
for src in "${SOURCES[@]}"; do
  if [[ ! -d "$src" ]]; then
    log "WARNING: source '$src' does not exist — skipping."
    failed=1
    continue
  fi

  dest="${REMOTE}:${BUCKET}/${src#/}"   # strip leading slash, keep structure
  log "Syncing '$src' -> '$dest'"

  if rclone sync "$src" "$dest" \
        --config "$RCLONE_CONFIG" \
        --fast-list \
        --transfers "$TRANSFERS" \
        --retries 3 \
        --log-file "$LOG_FILE" \
        --log-level INFO \
        --stats-one-line \
        --stats 5m; then
    log "OK: '$src'"
  else
    rc=$?
    log "ERROR: rclone failed for '$src' (exit $rc)"
    failed=1
  fi
done

if [[ "$failed" -eq 0 ]]; then
  log "===== Backup completed successfully ====="
  ping_hc            # success
  exit 0
else
  log "===== Backup finished WITH ERRORS — see log above ====="
  ping_hc "/fail"
  exit 1
fi
