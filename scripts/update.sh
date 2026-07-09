#!/usr/bin/env bash
set -euo pipefail

TEAMTP_DIR="/opt/teamtp"

echo "═══ TeamTP Updater ═══"

# Pre-update backup
echo "[Update] Pre-update backup..."
"${TEAMTP_DIR}/scripts/backup.sh"

# Pull latest code if git repo
if [[ -d "${TEAMTP_DIR}/.git" ]]; then
  echo "[Update] Pulling latest code..."
  cd "$TEAMTP_DIR" && git pull 2>/dev/null || echo "[Update] Git pull failed, continuing"
fi

# Update npm deps
echo "[Update] Updating dependencies..."
for dir in panel bots/level-bot bots/temp-channel-bot bots/support-bot; do
  if [[ -f "${TEAMTP_DIR}/${dir}/package.json" ]]; then
    echo "  ${dir}..."
    cd "${TEAMTP_DIR}/${dir}" && npm ci --silent 2>/dev/null || npm install --silent 2>/dev/null || true
  fi
done

# Reload systemd
echo "[Update] Reloading systemd..."
systemctl daemon-reload

# Restart services
echo "[Update] Restarting services..."
for svc in teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
  systemctl restart "$svc" 2>/dev/null && echo "  ${svc}: restarted" || echo "  ${svc}: failed"
  sleep 1
done

echo "[Update] Complete"
