#!/usr/bin/env bash
# TimyabSpeak CLI — /usr/local/bin/teamtp
# Version: 2.0.0
set -euo pipefail

CLI_VERSION="2.0.0"
TEAMTP_DIR="${TEAMTP_DIR:-/opt/teamtp}"
ENV_FILE="${TEAMTP_DIR}/.env"

# ─── Colors ───
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
  BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ─── Symbols ───
if [[ "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" =~ \.UTF[-]?8 ]]; then
  OK='✓'; ER='✗'; WN='⚠'; IN='ℹ'
else
  OK='+'; ER='x'; WN='!'; IN='i'
fi

ok()    { echo -e "  ${GREEN}${OK}${NC} $*"; }
err()   { echo -e "  ${RED}${ER}${NC} $*" >&2; }
warn()  { echo -e "  ${YELLOW}${WN}${NC} $*"; }
info()  { echo -e "  ${CYAN}${IN}${NC} $*"; }

# ─── Load .env ───
load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE" 2>/dev/null || true
    set +a
  fi
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: status
# ══════════════════════════════════════════════════════════════════

cmd_status() {
  load_env
  echo ""
  echo -e "  ${BOLD}Service Status${NC}"
  echo ""

  for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    local state status_color
    state=$(systemctl is-active "$s" 2>/dev/null || echo "inactive")
    case "$state" in
      active)   status_color="${GREEN}${OK} active${NC}" ;;
      *)        status_color="${RED}${ER} ${state}${NC}" ;;
    esac
    printf "  %-26s %b\n" "$s" "$status_color"
  done

  local ver
  ver="$(grep TEAMTP_VERSION "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "unknown")"
  echo ""
  echo -e "  ${DIM}Version: ${ver}${NC}"
  echo ""
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: restart
# ══════════════════════════════════════════════════════════════════

cmd_restart() {
  local svcs=(teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot)
  for s in "${svcs[@]}"; do
    printf "  Restarting %s..." "$s"
    if systemctl restart "$s" 2>/dev/null; then
      echo -e " ${GREEN}${OK}${NC}"
    else
      echo -e " ${YELLOW}${WN}${NC} (not found or failed)"
    fi
  done
  echo ""
  echo -e "  ${GREEN}${OK}${NC} All services restarted."
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: bot
# ══════════════════════════════════════════════════════════════════

cmd_bot() {
  local bot_name="$1" bot_action="$2"

  if [[ -z "${bot_name:-}" || -z "${bot_action:-}" ]]; then
    err "Usage: teamtp bot <level|temp|support> <on|off|restart|status>"
    exit 1
  fi

  case "$bot_name" in
    level|temp|support) ;;
    *) err "Unknown bot '${bot_name}'. Use: level, temp, or support."; exit 1 ;;
  esac

  local svc="teamtp-${bot_name}-bot"

  case "$bot_action" in
    on|start)
      if systemctl start "$svc" 2>/dev/null; then
        ok "${bot_name}: started"
      else
        err "${bot_name}: failed to start (service not found?)"
        exit 1
      fi
      ;;
    off|stop)
      if systemctl stop "$svc" 2>/dev/null; then
        ok "${bot_name}: stopped"
      else
        err "${bot_name}: failed to stop"
        exit 1
      fi
      ;;
    restart)
      if systemctl restart "$svc" 2>/dev/null; then
        ok "${bot_name}: restarted"
      else
        err "${bot_name}: failed to restart"
        exit 1
      fi
      ;;
    status)
      local state status_color
      state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
      case "$state" in
        active) status_color="${GREEN}active${NC}" ;;
        *)      status_color="${RED}${state}${NC}" ;;
      esac
      printf "  %s: %b\n" "$bot_name" "$status_color"
      ;;
    *)
      err "Unknown action '${bot_action}'. Use: on, off, restart, or status."
      exit 1
      ;;
  esac
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: panel
# ══════════════════════════════════════════════════════════════════

cmd_panel() {
  load_env

  local ip proto="http"
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"
  [[ "${WIZARD_SSL:-}" =~ ^(letsencrypt|self-signed)$ ]] && proto="https"

  echo ""
  echo -e "  ${BOLD}Panel Access${NC}"
  echo ""
  printf "  %-14s http://localhost:%s\n" "Local:" "${PORT_PANEL:-3000}"
  printf "  %-14s %s://%s\n" "External:" "$proto" "$ip"
  if [[ -n "${WIZARD_DOMAIN:-}" ]]; then
    printf "  %-14s %s://panel.%s\n" "Domain:" "$proto" "$WIZARD_DOMAIN"
  fi

  if [[ "${WIZARD_SSL:-}" == "self-signed" ]]; then
    echo ""
    warn "Self-signed certificate — browsers will show a security warning."
  fi

  echo ""
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: ssl
# ══════════════════════════════════════════════════════════════════

cmd_ssl() {
  if ! command -v certbot &>/dev/null; then
    err "certbot is not installed."
    exit 1
  fi

  info "Renewing SSL certificates..."
  if certbot renew --non-interactive 2>&1; then
    systemctl reload nginx 2>/dev/null || true
    ok "SSL certificates renewed."
  else
    err "SSL renewal failed. Check: certbot renew --dry-run"
    exit 1
  fi
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: backup
# ══════════════════════════════════════════════════════════════════

cmd_backup() {
  load_env

  local stamp f
  stamp=$(date +%Y%m%d-%H%M%S)
  f="${TEAMTP_DIR}/backups/teamtp-${stamp}.tar.gz"
  mkdir -p "${TEAMTP_DIR}/backups"

  echo ""
  info "Creating backup..."

  for bot in teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl stop "$bot" 2>/dev/null || true
  done

  local files_to_backup=()
  for item in .env config shared scripts; do
    [[ -e "${TEAMTP_DIR}/${item}" ]] && files_to_backup+=("$item")
  done
  for db in bots/level-bot/data.sqlite bots/temp-channel-bot/temp-channels.sqlite bots/support-bot/tickets.sqlite; do
    [[ -f "${TEAMTP_DIR}/${db}" ]] && files_to_backup+=("$db")
  done
  [[ -d "${TEAMTP_DIR}/tickets" ]] && files_to_backup+=("tickets")

  if [[ ${#files_to_backup[@]} -gt 0 ]]; then
    tar -czf "$f" -C "$TEAMTP_DIR" "${files_to_backup[@]}" 2>/dev/null || true
  fi

  for bot in teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl start "$bot" 2>/dev/null || true
  done

  if [[ -f "$f" ]]; then
    ok "Backup: $f"
    info "Size: $(du -h "$f" | cut -f1)"
  else
    err "Backup failed — nothing to archive."
    exit 1
  fi

  find "${TEAMTP_DIR}/backups" -name "teamtp-*.tar.gz" -mtime +30 -delete 2>/dev/null || true
  info "Old backups pruned (30-day retention)."
  echo ""
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: update
# ══════════════════════════════════════════════════════════════════

cmd_update() {
  load_env
  echo ""
  echo -e "  ${BOLD}TimyabSpeak Update${NC}"
  echo ""

  info "Creating pre-update backup..."
  "$0" backup || warn "Pre-update backup skipped, continuing."
  echo ""

  if [[ -d "${TEAMTP_DIR}/.git" ]]; then
    info "Pulling latest code..."
    if (cd "$TEAMTP_DIR" && git pull 2>&1); then
      ok "Code updated."
    else
      warn "git pull failed. Continuing with existing code."
    fi
  else
    info "Not a git repository — skipping code pull."
  fi

  echo ""
  info "Updating npm packages..."
  local npm_dirs=(panel bots/level-bot bots/temp-channel-bot bots/support-bot)
  for d in "${npm_dirs[@]}"; do
    if [[ -f "${TEAMTP_DIR}/${d}/package.json" ]]; then
      printf "  %-30s" "${d}..."
      if (cd "${TEAMTP_DIR}/${d}" && npm ci --silent 2>/dev/null) || (cd "${TEAMTP_DIR}/${d}" && npm install --silent 2>/dev/null); then
        echo -e " ${GREEN}${OK}${NC}"
      else
        echo -e " ${YELLOW}${WN}${NC}"
      fi
    fi
  done

  # Update CLI from source
  if [[ -f "${TEAMTP_DIR}/scripts/teamtp.sh" ]]; then
    cp "${TEAMTP_DIR}/scripts/teamtp.sh" /usr/local/bin/teamtp
    chmod +x /usr/local/bin/teamtp
    ok "CLI updated."
  fi

  echo ""
  info "Restarting services..."
  systemctl daemon-reload
  for s in teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl restart "$s" 2>/dev/null || true
  done
  ok "Services restarted."
  echo ""
  ok "Update complete."
  echo ""
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: health
# ══════════════════════════════════════════════════════════════════

cmd_health() {
  if systemctl is-active teamspeak6 >/dev/null 2>&1; then
    echo "OK"; exit 0
  else
    echo "DOWN"; exit 1
  fi
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: logs
# ══════════════════════════════════════════════════════════════════

cmd_logs() {
  local svc="${1:-teamspeak6}"
  local lines="${2:-50}"

  local valid_svcs=(teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot)
  local found=false
  for v in "${valid_svcs[@]}"; do
    [[ "$svc" == "$v" ]] && found=true && break
  done

  if ! $found; then
    warn "Unknown service '${svc}'. Known: ${valid_svcs[*]}"
  fi

  journalctl -u "$svc" --no-pager -n "$lines"
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: wipe
# ══════════════════════════════════════════════════════════════════

cmd_wipe() {
  echo ""
  echo -e "  ${RED}${BOLD}WARNING: This will PERMANENTLY DELETE everything.${NC}"
  echo -e "  ${RED}All databases, configurations, and files will be lost.${NC}"
  echo ""
  local ans
  printf "  Type DELETE to confirm: " >/dev/tty
  read -r ans </dev/tty 2>/dev/null || true
  if [[ "$ans" != "DELETE" ]]; then
    echo ""
    echo "  Aborted. Nothing was changed."
    exit 0
  fi

  echo ""
  info "Stopping services..."
  local svcs=(teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot)
  for s in "${svcs[@]}"; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
  done

  info "Removing unit files..."
  rm -f /etc/systemd/system/teamspeak6.service /etc/systemd/system/teamtp-*.service
  systemctl daemon-reload 2>/dev/null || true

  info "Removing nginx config..."
  rm -f /etc/nginx/sites-available/teamtp /etc/nginx/sites-available/teamtp-ssl
  rm -f /etc/nginx/sites-enabled/teamtp /etc/nginx/sites-enabled/teamtp-ssl
  if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || true
  fi

  info "Removing files..."
  rm -rf "$TEAMTP_DIR" /usr/local/bin/teamtp
  rm -f /var/log/teamtp-install.log /etc/logrotate.d/teamtp
  rm -rf /var/log/teamtp

  echo ""
  ok "Wipe complete. All traces removed."
  echo -e "  ${DIM}Run install.sh for a fresh installation.${NC}"
  echo ""
}

# ══════════════════════════════════════════════════════════════════
# COMMAND: help
# ══════════════════════════════════════════════════════════════════

cmd_help() {
  echo ""
  echo -e "  ${BOLD}TimyabSpeak CLI${NC}  ${DIM}v${CLI_VERSION}${NC}"
  echo ""
  echo -e "  ${BOLD}Usage:${NC} teamtp <command> [args]"
  echo ""
  echo -e "  ${BOLD}Commands:${NC}"
  printf "  %-32s %s\n" "status"       "Show all services status"
  printf "  %-32s %s\n" "restart"      "Restart all services"
  printf "  %-32s %s\n" "bot <n> <a>"  "Control bot (level|temp|support) (on|off|restart|status)"
  printf "  %-32s %s\n" "panel"        "Show web panel access URLs"
  printf "  %-32s %s\n" "ssl"          "Renew Let's Encrypt certificates"
  printf "  %-32s %s\n" "backup"       "Create backup (30-day retention)"
  printf "  %-32s %s\n" "update"       "Pre-backup → git pull → npm ci → restart"
  printf "  %-32s %s\n" "health"       "Health check (exit 0 = OK, 1 = DOWN)"
  printf "  %-32s %s\n" "logs [s] [n]" "View logs (default: teamspeak6, 50 lines)"
  printf "  %-32s %s\n" "wipe"         "DELETE everything permanently"
  printf "  %-32s %s\n" "help"         "Show this help"
  echo ""
  echo -e "  ${DIM}Config: ${TEAMTP_DIR}/.env${NC}"
  echo ""
}

# ══════════════════════════════════════════════════════════════════
# MAIN DISPATCH
# ══════════════════════════════════════════════════════════════════

main() {
  local cmd="${1:-help}"

  case "$cmd" in
    status)
      cmd_status
      ;;
    restart)
      cmd_restart
      ;;
    bot)
      cmd_bot "${2:-}" "${3:-}"
      ;;
    panel)
      cmd_panel
      ;;
    ssl)
      cmd_ssl
      ;;
    backup)
      cmd_backup
      ;;
    update)
      cmd_update
      ;;
    health)
      cmd_health
      ;;
    logs)
      cmd_logs "${2:-teamspeak6}" "${3:-50}"
      ;;
    wipe)
      cmd_wipe
      ;;
    help|--help|-h)
      cmd_help
      ;;
    *)
      err "Unknown command: ${cmd}"
      echo ""
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
