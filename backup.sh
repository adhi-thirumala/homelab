#!/usr/bin/env bash
#
# b2-backup.sh — Daily backup of homelab folders to Backblaze B2 via rclone.
#
# One-time setup:
#   1. Install rclone:   curl https://rclone.org/install.sh | sudo bash
#   2. Create a B2 bucket + Application Key (append-only key recommended).
#   3. Configure the remote: `rclone config`  (name it to match REMOTE below).
#   4. Edit the CONFIG section — especially SOURCES and EXCLUDES.
#   5. chmod +x b2-backup.sh   and schedule it for 06:00 with cron or systemd.

set -euo pipefail

### ─── CONFIG ──────────────────────────────────────────────────────────────

# rclone remote name (must match what you created with `rclone config`).
REMOTE="b2-backup"

# Destination B2 bucket.
BUCKET="homelab-backup-adhithirumala"

# Folders to back up. Each is mirrored into the bucket preserving its path,
# e.g. /home/ubuntu/homelab -> b2-backup:<bucket>/home/ubuntu/homelab
# No trailing slashes. Add one line per folder.
SOURCES=(
  "/home/ubuntu/homelab"
)

# Paths to exclude from the backup. Patterns are matched RELATIVE to each
# source folder above (never absolute) and apply to every source. Use a
# trailing "/**" to drop a directory and everything under it. Delete any line
# you'd rather keep; add your own as needed.
EXCLUDES=(
  "caddy/data/storage/caddy/**" # Caddy cert/key store — re-fetched via ACME on redeploy (keeps access logs)
  "vaultwarden/data/icon_cache/**" # Vaultwarden favicon cache — cosmetic, rebuilt automatically
)

# Number of parallel transfers. B2 likes 8–32; rclone's default of 4 is slow.
TRANSFERS=16

# Where to write logs.
LOG_DIR="/home/ubuntu/b2-backup"

# Absolute path to the rclone config. Set explicitly so it works whether the
# job runs as your user OR as root (systemd/cron) — root won't find it via $HOME.
RCLONE_CONFIG="/home/ubuntu/.config/rclone/rclone.conf"

# Optional Healthchecks.io ping URL (alerts you if a backup fails or stops
# running). Leave empty ("") to disable. Free check at https://healthchecks.io.
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

# Turn the EXCLUDES array into repeated rclone --exclude arguments.
exclude_args=()
for pattern in "${EXCLUDES[@]}"; do
  exclude_args+=( --exclude "$pattern" )
done

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
        "${exclude_args[@]}" \
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
