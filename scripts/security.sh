#!/usr/bin/env bash
set -euo pipefail

echo "═══ TeamTP Security Audit ═══"

echo ""
echo "[•] UFW Status:"
ufw status verbose 2>/dev/null | head -10 || echo "  UFW not active"

echo ""
echo "[•] Fail2ban Status:"
fail2ban-client status 2>/dev/null | head -5 || echo "  fail2ban not running"

echo ""
echo "[•] Services:"
for svc in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
  state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
  echo "  $svc: $state"
done

echo ""
echo "[•] Port checks (should show localhost only for query):"
ss -tln | grep -E "10022|10080" || echo "  Query ports not listening"

echo ""
echo "[•] File permissions:"
env_file="/opt/teamtp/.env"
if [[ -f "$env_file" ]]; then
  perm=$(stat -c "%a %U:%G" "$env_file" 2>/dev/null || stat -f "%OLp %u:%g" "$env_file" 2>/dev/null)
  echo "  .env: $perm"
  [[ "$perm" == 600* ]] && echo "  ✓ .env permissions correct" || echo "  ⚠ .env should be 600"
else
  echo "  ⚠ .env not found"
fi

echo ""
echo "[•] Users:"
for u in tsserver teamtp; do
  id "$u" &>/dev/null && echo "  $u: exists" || echo "  $u: missing"
done

echo ""
echo "[•] Unattended upgrades:"
dpkg -l | grep -q unattended-upgrades && echo "  ✓ installed" || echo "  ⚠ not installed"

echo ""
echo "═══ Audit complete ═══"
