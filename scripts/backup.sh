#!/usr/bin/env bash
set -euo pipefail

TEAMTP_DIR="/opt/teamtp"
BACKUP_DIR="${TEAMTP_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILENAME="teamtp-${TIMESTAMP}.tar.gz"
RETENTION_DAYS=${BACKUP_RETENTION:-30}

mkdir -p "$BACKUP_DIR"

echo "[Backup] Creating backup: ${FILENAME}"

# Stop bots during backup for consistency
for bot in teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
  systemctl stop "$bot" 2>/dev/null || true
done

tar -czf "${BACKUP_DIR}/${FILENAME}" \
  -C "$TEAMTP_DIR" \
  .env \
  config/ \
  shared/ \
  bots/*/{package.json,index.js,tickets.sqlite,data.sqlite,temp-channels.sqlite} \
  panel/{server.js,package.json,public/,routes/,services/} \
  scripts/ \
  2>/dev/null || true

# Restart bots
for bot in teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
  systemctl start "$bot" 2>/dev/null || true
done

echo "[Backup] Created: ${BACKUP_DIR}/${FILENAME}"
SIZE=$(du -h "${BACKUP_DIR}/${FILENAME}" | cut -f1)
echo "[Backup] Size: ${SIZE}"

# Prune old backups
find "$BACKUP_DIR" -name "teamtp-*.tar.gz" -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null
echo "[Backup] Retention: ${RETENTION_DAYS} days"

echo "[Backup] Complete"
