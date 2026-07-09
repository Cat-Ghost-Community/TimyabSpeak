#!/usr/bin/env bash
# TimyabSpeak — TeamSpeak 6 one-command installer
# Version: 1.4.0
set -euo pipefail

INSTALL_VERSION="1.4.0"
INSTALL_LOG="/var/log/teamtp-install.log"
TEAMTP_DIR="/opt/teamtp"
MARKER="${TEAMTP_DIR}/.installed"

TS6_URL="${TS6_URL:-https://github.com/teamspeak/teamspeak6-server/releases/download/v6.0.0-beta11/tsserver_6.0.0-beta11_linux_x86_64.tar.gz}"
TS6_BIN="tsserver"
TEAMTP_REPO="${TEAMTP_REPO:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[..]${NC} $*"; }

# Run a command and log its output. Does NOT exit on failure — caller checks $?.
run_log() {
  local label="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${label}: $*" >> "$INSTALL_LOG"
  "$@" >> "$INSTALL_LOG" 2>&1
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${label}: exit $ec" >> "$INSTALL_LOG"
  fi
  return $ec
}

# ───── PORT FIND ─────
# Print first free port in [base, base+max]. Return 1 if none found.
find_port() {
  command -v ss &>/dev/null || fail "ss command not found (install iproute2)"
  local base=$1 max=$2 proto=$3
  for off in $(seq 0 "$max"); do
    local p=$((base + off))
    if [[ "$proto" == "udp" ]]; then
      if ! ss -uln 2>/dev/null | grep -q ":$p "; then
        echo "$p"
        return 0
      fi
    else
      if ! ss -tln 2>/dev/null | grep -q ":$p "; then
        echo "$p"
        return 0
      fi
    fi
  done
  return 1
}

# ───── STEP 1: PRE-FLIGHT ─────
preflight() {
  [[ $EUID -eq 0 ]] || fail "Run as root: sudo bash install.sh"

  echo "──────────────────────────────────────"
  echo " TimyabSpeak v${INSTALL_VERSION} — TeamSpeak 6 Installer"
  echo "──────────────────────────────────────"

  if grep -Eqi "ubuntu (22|24)\.04|debian 12" /etc/os-release 2>/dev/null; then
    ok "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
  else
    warn "Recommended: Ubuntu 22.04+ / Debian 12+"
  fi

  info "Arch: $(uname -m)"

  local mem
  mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}') || mem=0
  [[ ${mem:-0} -ge 512 ]] && ok "RAM: ${mem}MB" || warn "RAM: ${mem}MB (512MB min)"

  local free
  free=$(df / --output=avail 2>/dev/null | tail -1) || free=0
  [[ ${free:-0} -ge 2097152 ]] || fail "Need 2GB+ free on / (have $((free/1024))MB)"

  if [[ -f "$MARKER" ]]; then
    warn "Existing install at ${TEAMTP_DIR}. Run 'teamtp update' to update or 'teamtp wipe' to reinstall."
  fi
}

# ───── STEP 2: WIZARD ─────
wizard() {
  exec </dev/tty 2>/dev/null || true
  echo ""
  echo "========== Setup Wizard =========="
  echo "Accept [defaults] with Enter | Ctrl+C to cancel"
  echo ""

  # Domain or IP?
  echo "Do you have a domain name pointing to this server?"
  echo "  1) Yes — I have a domain (e.g. myserver.com)"
  echo "  2) No — use IP address only"
  read -rp "  Choose [2]: " has_domain
  has_domain=${has_domain:-2}
  has_domain=${has_domain,,}
  case "$has_domain" in
    1|y|yes|true) HAS_DOMAIN=1 ;;
    *) HAS_DOMAIN=0 ;;
  esac

  if [[ "$HAS_DOMAIN" -eq 1 ]]; then
    while true; do
      read -rp "  Domain name: " WIZARD_DOMAIN
      WIZARD_DOMAIN="${WIZARD_DOMAIN// /}"
      [[ -n "$WIZARD_DOMAIN" ]] && break
      echo "  Domain cannot be empty."
    done
    echo "  SSL:"
    echo "    1) Let's Encrypt (auto, recommended)"
    echo "    2) Self-signed certificate"
    echo "    3) No SSL"
    read -rp "    Choose [1]: " ssl
    ssl=${ssl:-1}
    case "$ssl" in
      2) WIZARD_SSL="self-signed" ;;
      3) WIZARD_SSL="none" ;;
      *) WIZARD_SSL="letsencrypt" ;;
    esac
  else
    WIZARD_DOMAIN=""
    echo "  SSL:"
    echo "    1) Self-signed certificate [default]"
    echo "    2) No SSL"
    read -rp "    Choose [1]: " ssl
    ssl=${ssl:-1}
    case "$ssl" in
      2) WIZARD_SSL="none" ;;
      *) WIZARD_SSL="self-signed" ;;
    esac
  fi

  read -rp "Server name [My Gaming Community]: " tmp
  WIZARD_SERVER_NAME="${tmp:-My Gaming Community}"

  read -rp "Admin username [admin]: " tmp
  WIZARD_ADMIN_USER="${tmp:-admin}"

  while true; do
    read -rsp "Admin password (min 8 chars): " tmp; echo
    [[ ${#tmp} -ge 8 ]] && break
    echo "  Too short."
  done
  WIZARD_ADMIN_PASS="$tmp"

  while true; do
    read -rp "Max slots [64]: " tmp
    WIZARD_SLOTS="${tmp:-64}"
    if [[ "$WIZARD_SLOTS" =~ ^[0-9]+$ ]] && [[ "$WIZARD_SLOTS" -ge 1 ]]; then
      break
    fi
    echo "  Please enter a positive number."
  done

  read -rp "Welcome message [Welcome!]: " tmp
  WIZARD_WELCOME="${tmp:-Welcome!}"

  ok "Wizard complete"
}

# ───── STEP 3: SYSTEM DEPS ─────
install_deps() {
  info "Installing system packages..."

  if ! run_log "apt-update" apt-get update -qq; then
    warn "apt update failed"
  fi

  local pkgs=(
    curl wget nginx openssl ufw fail2ban logrotate
    iproute2 procps unattended-upgrades
    build-essential python3 libsqlite3-dev
  )
  if ! run_log "apt-install" apt-get install -y -qq "${pkgs[@]}"; then
    warn "Some packages failed to install"
  fi

  if ! command -v node &>/dev/null || [[ ! "$(node -v | sed 's/^v//; s/\..*//')" =~ ^[0-9]+$ ]] || [[ "$(node -v | sed 's/^v//; s/\..*//')" -lt 20 ]]; then
    info "Installing Node.js 20..."
    if run_log "nodesource-setup" curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; then
      if ! run_log "nodejs-install" apt-get install -y -qq nodejs; then
        warn "Node.js install failed"
      fi
    else
      warn "NodeSource setup failed"
    fi
  fi

  if command -v node &>/dev/null; then
    ok "Node.js $(node -v)"
  else
    fail "Node.js is required but not installed"
  fi
}

# ───── STEP 4: USERS ─────
create_users() {
  info "Creating system users..."
  id -u tsserver &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin tsserver
  id -u teamtp &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin teamtp
  mkdir -p "$TEAMTP_DIR"
  chown -R teamtp:teamtp "$TEAMTP_DIR"
  ok "Users: tsserver, teamtp"
}

# ───── STEP 5: DEPLOY FILES ─────
deploy_files() {
  if [[ -n "$TEAMTP_REPO" ]]; then
    info "Cloning ${TEAMTP_REPO}..."
    if [[ -d "${TEAMTP_DIR}/.git" ]]; then
      cd "$TEAMTP_DIR" && run_log "git-pull" git pull || warn "git pull failed"
    else
      rm -rf "$TEAMTP_DIR"
      if ! run_log "git-clone" git clone "$TEAMTP_REPO" "$TEAMTP_DIR"; then
        fail "git clone failed. For private repos, include a PAT in the URL or set up an SSH deploy key."
      fi
    fi
    chown -R teamtp:teamtp "$TEAMTP_DIR"
    ok "Git repo deployed"
    return
  fi

  local src="${SRC_DIR:-$PWD}"
  [[ ! -d "$src" ]] && src="$PWD"
  info "Copying from ${src}..."
  mkdir -p "$TEAMTP_DIR"

  for subdir in config shared scripts bots/level-bot bots/temp-channel-bot bots/support-bot panel panel/public systemd; do
    if [[ -d "${src}/${subdir}" ]]; then
      mkdir -p "${TEAMTP_DIR}/${subdir}"
      cp -r "${src}/${subdir}/." "${TEAMTP_DIR}/${subdir}/"
    fi
  done

  [[ -f "${src}/.env.example" ]] && cp "${src}/.env.example" "${TEAMTP_DIR}/.env.example"
  [[ -f "${src}/install.sh" ]] && cp "${src}/install.sh" "${TEAMTP_DIR}/install.sh"

  chown -R teamtp:teamtp "$TEAMTP_DIR"
  find "$TEAMTP_DIR" -type f -name "*.sh" -exec chmod +x {} \;
  ok "Files deployed"
}

# ───── STEP 6: NPM INSTALL ─────
install_npm() {
  info "Installing npm dependencies..."

  local dirs=("bots/level-bot" "bots/temp-channel-bot" "bots/support-bot" "panel")
  for rel in "${dirs[@]}"; do
    local dir="${TEAMTP_DIR}/${rel}"
    mkdir -p "$dir"

    if [[ ! -f "${dir}/package.json" ]]; then
      local deps
      case "$rel" in
        panel) deps='express socket.io jsonwebtoken bcrypt helmet better-sqlite3' ;;
        *) deps='better-sqlite3' ;;
      esac
      {
        echo '{'
        echo "  \"name\": \"teamtp-$(basename "$dir")\","
        echo '  "version": "1.0.0",'
        echo '  "private": true,'
        echo '  "main": "index.js",'
        echo '  "dependencies": {'
        local first=true
        for dep in $deps; do
          $first && first=false || echo ','
          echo -n "    \"$dep\": \"*\""
        done
        echo ''
        echo '  }'
        echo '}'
      } > "${dir}/package.json"
    fi

    if ! (cd "$dir" && run_log "npm-install-${rel//\//-}" npm install --silent); then
      fail "npm install failed in ${rel}"
    fi
  done

  chown -R teamtp:teamtp "$TEAMTP_DIR"
  ok "npm dependencies installed"
}

# ───── STEP 7: SECRETS + PORTS ─────
generate_secrets() {
  info "Generating secrets..."

  SECRET_QUERY_PASS=$(openssl rand -hex 16)
  SECRET_API_KEY=$(openssl rand -hex 32)
  SECRET_JWT=$(openssl rand -hex 32)
  SECRET_REFRESH=$(openssl rand -hex 32)

  # bcrypt hash using the already-installed panel dependency
  local panel_dir="${TEAMTP_DIR}/panel"
  if [[ -d "${panel_dir}/node_modules/bcrypt" ]]; then
    PANEL_BCRYPT_HASH=$(node -e "
const bcrypt = require('bcrypt');
console.log(bcrypt.hashSync(process.argv[1], 12));
" "$WIZARD_ADMIN_PASS")
  else
    fail "bcrypt module not installed in panel. Cannot create admin password hash."
  fi

  info "Scanning ports..."
  PORT_VOICE=$(find_port 9987 20 udp) || fail "No free voice port found"
  PORT_FILE=$(find_port 30033 10 tcp) || fail "No free filetransfer port found"
  PORT_SSH_QUERY=$(find_port 10022 10 tcp) || fail "No free SSH query port found"
  PORT_HTTP_QUERY=$(find_port 10080 10 tcp) || fail "No free HTTP query port found"
  PORT_PANEL=$(find_port 3000 10 tcp) || fail "No free panel port found"

  ok "Ports: Voice=${PORT_VOICE} File=${PORT_FILE} Query=${PORT_HTTP_QUERY} Panel=${PORT_PANEL}"

  {
    printf 'TS6_BASE_URL=http://127.0.0.1:%s\n' "$PORT_HTTP_QUERY"
    printf 'TS6_API_KEY=%s\n' "$SECRET_API_KEY"
    printf 'TS6_QUERY_HOST=127.0.0.1\n'
    printf 'TS6_QUERY_PORT=%s\n' "$PORT_SSH_QUERY"
    printf 'TS6_QUERY_PASSWORD=%s\n' "$SECRET_QUERY_PASS"
    printf 'PANEL_PORT=%s\n' "$PORT_PANEL"
    printf 'PANEL_BIND=127.0.0.1\n'
    printf 'PANEL_JWT_SECRET=%s\n' "$SECRET_JWT"
    printf 'PANEL_REFRESH_SECRET=%s\n' "$SECRET_REFRESH"
    printf 'PANEL_ADMIN_USER=%s\n' "$WIZARD_ADMIN_USER"
    printf 'PANEL_ADMIN_HASH=%s\n' "$PANEL_BCRYPT_HASH"
    printf 'WIZARD_DOMAIN=%s\n' "${WIZARD_DOMAIN:-}"
    printf 'WIZARD_SSL=%s\n' "${WIZARD_SSL:-none}"
    printf 'WIZARD_SERVER_NAME=%s\n' "$WIZARD_SERVER_NAME"
    printf 'WIZARD_SLOTS=%s\n' "$WIZARD_SLOTS"
    printf 'TEAMTP_VERSION=%s\n' "$INSTALL_VERSION"
    printf 'PORT_VOICE=%s\n' "$PORT_VOICE"
    printf 'PORT_FILE=%s\n' "$PORT_FILE"
    printf 'PORT_SSH_QUERY=%s\n' "$PORT_SSH_QUERY"
    printf 'PORT_HTTP_QUERY=%s\n' "$PORT_HTTP_QUERY"
    printf 'PORT_PANEL=%s\n' "$PORT_PANEL"
  } > "${TEAMTP_DIR}/.env"

  chmod 600 "${TEAMTP_DIR}/.env"
  chown teamtp:teamtp "${TEAMTP_DIR}/.env"
  ok "Secrets generated"
}

# ───── STEP 8: TS6 SERVER ─────
install_ts6() {
  local dir="${TEAMTP_DIR}/server/teamspeak6"
  mkdir -p "$dir"
  mkdir -p "${dir}/sql" "${dir}/sql/create_sqlite"

  if [[ ! -f "${dir}/${TS6_BIN}" ]]; then
    info "Downloading TS6..."
    local tmp
    tmp=$(mktemp)
    if ! run_log "ts6-download" curl -fsSL --retry 3 --retry-delay 5 -o "$tmp" "$TS6_URL"; then
      rm -f "$tmp"
      fail "TS6 download failed"
    fi
    if ! run_log "ts6-extract" tar -xzf "$tmp" -C "$dir" --strip-components=1; then
      rm -f "$tmp"
      fail "TS6 extract failed"
    fi
    rm -f "$tmp"
    chmod +x "${dir}/${TS6_BIN}"
    ok "TS6 downloaded"
  else
    ok "TS6 binary exists"
  fi

  chown -R tsserver:tsserver "$dir"

  cat > "${dir}/tsserver.yaml" <<YAML
server:
  license-path: .
  accept-license: accept
  default-voice-port: ${PORT_VOICE}
  voice-ip: ["0.0.0.0"]
  filetransfer-port: ${PORT_FILE}
  filetransfer-ip: "0.0.0.0"
  query:
    ssh:
      enable: 1
      port: ${PORT_SSH_QUERY}
      ip: "127.0.0.1"
    http:
      enable: 1
      port: ${PORT_HTTP_QUERY}
      ip: "127.0.0.1"
    admin-password: "${SECRET_QUERY_PASS}"
  database:
    plugin: sqlite3
    sql-path: ${dir}/sql/
    sql-create-path: ${dir}/sql/create_sqlite/
YAML

  chown tsserver:tsserver "${dir}/tsserver.yaml"
  ok "TS6 config written"
}

# ───── STEP 9: SYSTEMD ─────
setup_systemd() {
  info "Setting up services..."

  cat > /etc/systemd/system/teamspeak6.service <<'UNIT'
[Unit]
Description=TeamSpeak 6 Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=tsserver
Group=tsserver
WorkingDirectory=/opt/teamtp/server/teamspeak6
ExecStart=/opt/teamtp/server/teamspeak6/tsserver --config-file /opt/teamtp/server/teamspeak6/tsserver.yaml
ExecStop=/bin/kill -SIGTERM $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=4096
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

  # Bot services
  local name dir
  for pair in "level|bots/level-bot" "temp|bots/temp-channel-bot" "support|bots/support-bot"; do
    name="${pair%%|*}"
    dir="${pair##*|}"
    cat > "/etc/systemd/system/teamtp-${name}-bot.service" <<UNIT
[Unit]
Description=TeamTP ${name^} Bot
After=teamspeak6.service
Wants=teamspeak6.service

[Service]
Type=simple
User=teamtp
Group=teamtp
WorkingDirectory=${TEAMTP_DIR}/${dir}
ExecStart=/usr/bin/node ${TEAMTP_DIR}/${dir}/index.js
EnvironmentFile=${TEAMTP_DIR}/.env
Restart=on-failure
RestartSec=10
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
UNIT
  done

  # Panel service
  cat > /etc/systemd/system/teamtp-panel.service <<'UNIT'
[Unit]
Description=TeamTP Web Panel
After=teamspeak6.service
Wants=teamspeak6.service

[Service]
Type=simple
User=teamtp
Group=teamtp
WorkingDirectory=/opt/teamtp/panel
ExecStart=/usr/bin/node /opt/teamtp/panel/server.js
EnvironmentFile=/opt/teamtp/.env
Restart=on-failure
RestartSec=5
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable teamspeak6

  if ! run_log "ts6-start" systemctl start teamspeak6; then
    warn "TS6 start failed"
  else
    ok "TS6 started"
  fi

  # Wait for TS6 HTTP query to respond
  local n=0
  while ! ss -tln 2>/dev/null | grep -q ":${PORT_HTTP_QUERY} "; do
    n=$((n+1))
    if [[ $n -gt 30 ]]; then
      warn "TS6 not responding after 60s. Check: journalctl -u teamspeak6"
      break
    fi
    sleep 2
  done

  PRIVILEGE_KEY=""
  if ss -tln 2>/dev/null | grep -q ":${PORT_HTTP_QUERY} "; then
    PRIVILEGE_KEY=$(journalctl -u teamspeak6 --no-pager -n 100 2>/dev/null | grep -oP "token=\K\S+" | head -1 || true)
    if [[ -n "$PRIVILEGE_KEY" ]]; then
      printf 'TS6_PRIVILEGE_KEY=%s\n' "$PRIVILEGE_KEY" >> "${TEAMTP_DIR}/.env"
      ok "Privilege key captured"
    else
      warn "Could not capture privilege key. Run: journalctl -u teamspeak6 | grep token"
    fi
  fi

  for svc in teamtp-level-bot teamtp-temp-bot teamtp-support-bot teamtp-panel; do
    systemctl enable "$svc" 2>/dev/null || true
    if ! run_log "start-${svc}" systemctl start "$svc"; then
      warn "$svc start failed"
    fi
    sleep 1
  done

  ok "All services started"
}

# ───── STEP 10: CLI ─────
install_cli() {
  cat > /usr/local/bin/teamtp <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
D="/opt/teamtp"
E="${D}/.env"

load_env() {
  if [[ -f "$E" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$E" 2>/dev/null || true
    set +a
  fi
}

usage() {
  echo "Usage:"
  echo "  teamtp status                        Show all services"
  echo "  teamtp restart                       Restart all services"
  echo "  teamtp bot <level|temp|support> <on|off|restart|status>"
  echo "  teamtp panel                         Show panel access URLs"
  echo "  teamtp ssl                           Renew SSL certificates"
  echo "  teamtp backup                        Create backup"
  echo "  teamtp update                        Backup + pull + npm ci + restart"
  echo "  teamtp health                        Exit 0 if TS6 is up"
  echo "  teamtp logs [svc] [lines]            journalctl (default: teamspeak6, 50)"
  echo "  teamtp wipe                          DELETE everything"
  echo "  teamtp help                          Show this help"
}

case "${1:-help}" in
  status)
    load_env
    for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
      local state
      state=$(systemctl is-active "$s" 2>/dev/null || echo "inactive")
      printf "  %-25s %s\n" "$s" "$state"
    done
    echo "  Version: $(grep TEAMTP_VERSION "$E" 2>/dev/null | cut -d= -f2 || echo '?')"
    ;;

  restart)
    for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
      systemctl restart "$s" 2>/dev/null || true
    done
    echo "Restarted"
    ;;

  bot)
    if [[ -z "${2:-}" || -z "${3:-}" ]]; then
      usage; exit 1
    fi
    local b="$2" a="$3"
    case "$b" in
      level|temp|support) ;;
      *) echo "Unknown bot: $b"; usage; exit 1 ;;
    esac
    case "$a" in
      on) systemctl start "teamtp-${b}-bot" 2>/dev/null || { echo "Bot not found"; exit 1; } ;;
      off) systemctl stop "teamtp-${b}-bot" 2>/dev/null || { echo "Bot not found"; exit 1; } ;;
      restart) systemctl restart "teamtp-${b}-bot" 2>/dev/null || { echo "Bot not found"; exit 1; } ;;
      status)
        local state
        state=$(systemctl is-active "teamtp-${b}-bot" 2>/dev/null || echo "inactive")
        echo "${b}: ${state}"
        ;;
      *) usage; exit 1 ;;
    esac
    ;;

  panel)
    load_env
    local ip proto="http"
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"
    [[ "${WIZARD_SSL:-}" =~ ^(letsencrypt|self-signed)$ ]] && proto="https"
    echo "Panel access:"
    echo "  Direct (localhost): http://localhost:${PORT_PANEL:-3000}"
    echo "  Web:                ${proto}://${ip}"
    if [[ -n "${WIZARD_DOMAIN:-}" ]]; then
      echo "  Web:                ${proto}://panel.${WIZARD_DOMAIN}"
    fi
    ;;

  ssl)
    if command -v certbot &>/dev/null; then
      certbot renew --non-interactive 2>&1 || echo "SSL renewal failed"
      systemctl reload nginx 2>/dev/null || true
      echo "SSL renewal complete"
    else
      echo "certbot not installed"
      exit 1
    fi
    ;;

  backup)
    local stamp f
    stamp=$(date +%Y%m%d-%H%M%S)
    f="${D}/backups/teamtp-${stamp}.tar.gz"
    mkdir -p "${D}/backups"

    # Stop bots for consistent DB dumps
    for bot in teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
      systemctl stop "$bot" 2>/dev/null || true
    done

    # Build file list
    local files=()
    for item in .env config shared scripts; do
      [[ -e "${D}/${item}" ]] && files+=("$item")
    done
    for db in bots/level-bot/data.sqlite bots/temp-channel-bot/temp-channels.sqlite bots/support-bot/tickets.sqlite; do
      [[ -f "${D}/${db}" ]] && files+=("$db")
    done
    for ticket in tickets/*.log; do
      [[ -f "$ticket" ]] && files+=("${ticket#${D}/}")
    done

    if [[ ${#files[@]} -gt 0 ]]; then
      tar -czf "$f" -C "$D" "${files[@]}" 2>/dev/null || true
    fi

    # Restart bots
    for bot in teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
      systemctl start "$bot" 2>/dev/null || true
    done

    if [[ -f "$f" ]]; then
      echo "Backup: $f ($(du -h "$f" | cut -f1))"
    else
      echo "Backup failed"
      exit 1
    fi

    find "${D}/backups" -name "teamtp-*.tar.gz" -mtime +30 -delete 2>/dev/null || true
    ;;

  update)
    echo "Updating..."
    echo "[Update] Creating pre-update backup..."
    "$0" backup || echo "Pre-update backup failed, continuing"
    if [[ -d "${D}/.git" ]]; then
      (cd "$D" && git pull 2>&1) || echo "Git pull failed, continuing"
    else
      echo "Not a git repo, skipping pull"
    fi
    for d in panel bots/level-bot bots/temp-channel-bot bots/support-bot; do
      if [[ -f "${D}/${d}/package.json" ]]; then
        (cd "${D}/${d}" && npm ci --silent 2>/dev/null) || (cd "${D}/${d}" && npm install --silent 2>/dev/null) || true
      fi
    done
    systemctl daemon-reload
    for s in teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
      systemctl restart "$s" 2>/dev/null || true
    done
    echo "Update complete"
    ;;

  wipe)
    echo "WARNING: DELETE everything?"
    read -rp 'Type "DELETE" to confirm: ' c
    [[ "$c" != "DELETE" ]] && { echo "Aborted."; exit 1; }
    for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
      systemctl stop "$s" 2>/dev/null || true
      systemctl disable "$s" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/teamspeak6.service /etc/systemd/system/teamtp-*.service
    systemctl daemon-reload
    rm -f /etc/nginx/sites-available/teamtp* /etc/nginx/sites-enabled/teamtp*
    nginx -t 2>/dev/null && systemctl reload nginx || true
    rm -rf "$D" /usr/local/bin/teamtp /var/log/teamtp* /etc/logrotate.d/teamtp
    echo "Wipe complete"
    ;;

  health)
    if systemctl is-active teamspeak6 >/dev/null 2>&1; then
      echo "OK"; exit 0
    else
      echo "DOWN"; exit 1
    fi
    ;;

  logs)
    journalctl -u "${2:-teamspeak6}" --no-pager -n "${3:-50}"
    ;;

  help|--help|-h)
    usage
    ;;

  *)
    usage; exit 1
    ;;
esac
CLI
  chmod +x /usr/local/bin/teamtp
  ok "CLI installed"
}

# ───── STEP 11: NGINX + SSL ─────
setup_nginx() {
  info "Configuring nginx..."

  local domain="${WIZARD_DOMAIN:-}"
  local server_names
  if [[ -n "$domain" ]]; then
    server_names="${domain} panel.${domain}"
  else
    server_names="_"
  fi

  # Base HTTP server (required for Let's Encrypt; harmless otherwise)
  cat > /etc/nginx/sites-available/teamtp <<NGX
server {
    listen 80;
    server_name ${server_names};

    location / {
        proxy_pass http://127.0.0.1:${PORT_PANEL};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:${PORT_PANEL};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
    }
}
NGX

  ln -sf /etc/nginx/sites-available/teamtp /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default

  case "${WIZARD_SSL:-}" in
    letsencrypt)
      if [[ -z "$domain" ]]; then
        warn "Let's Encrypt requires a domain name"
      else
        if ! run_log "certbot-install" apt-get install -y -qq certbot python3-certbot-nginx; then
          warn "Certbot install failed"
        fi
        if ! run_log "certbot-run" certbot --nginx -d "$domain" -d "panel.${domain}" --non-interactive --agree-tos --email "admin@${domain}"; then
          warn "Let's Encrypt failed"
        else
          ok "LE SSL for ${domain}"
        fi
      fi
      ;;

    self-signed)
      mkdir -p /etc/nginx/ssl
      local cn="${domain:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
      [[ -z "$cn" ]] && cn="teamtp"
      if run_log "selfsigned-cert" openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
          -keyout /etc/nginx/ssl/teamtp.key -out /etc/nginx/ssl/teamtp.crt -subj "/CN=${cn}"; then
        cat > /etc/nginx/sites-available/teamtp-ssl <<NGX
server {
    listen 443 ssl http2;
    server_name ${server_names};
    ssl_certificate /etc/nginx/ssl/teamtp.crt;
    ssl_certificate_key /etc/nginx/ssl/teamtp.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:${PORT_PANEL};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:${PORT_PANEL};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
    }
}
NGX
        ln -sf /etc/nginx/sites-available/teamtp-ssl /etc/nginx/sites-enabled/
        ok "Self-signed SSL for ${cn}"
      else
        warn "Self-signed certificate generation failed"
      fi
      ;;

    *)
      ok "No SSL selected"
      ;;
  esac

  if run_log "nginx-test" nginx -t; then
    run_log "nginx-reload" systemctl reload nginx || warn "nginx reload failed"
    ok "Nginx configured"
  else
    warn "nginx config test failed"
  fi
}

# ───── STEP 12: FIREWALL ─────
setup_firewall() {
  info "Configuring firewall..."

  if ! command -v ufw &>/dev/null; then
    warn "UFW not installed, skipping firewall"
    return
  fi

  # Do not reset existing rules — just ensure required ports are open.
  ufw default deny incoming 2>/dev/null || true
  ufw default allow outgoing 2>/dev/null || true

  ufw allow "${PORT_VOICE}/udp" 2>/dev/null || true
  ufw allow "${PORT_FILE}/tcp" 2>/dev/null || true
  ufw allow 80/tcp 2>/dev/null || true
  ufw allow 443/tcp 2>/dev/null || true
  ufw allow ssh 2>/dev/null || true

  if ! ufw --force enable 2>/dev/null; then
    warn "UFW enable failed"
  fi

  ok "Firewall: voice/ft/80/443/ssh"

  if command -v fail2ban &>/dev/null; then
    cat > /etc/fail2ban/jail.local <<'F2B'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
F2B
    systemctl restart fail2ban 2>/dev/null || true
    ok "fail2ban configured"
  fi
}

# ───── STEP 13: LOGROTATE ─────
setup_logrotate() {
  mkdir -p /var/log/teamtp
  cat > /etc/logrotate.d/teamtp <<'LOG'
/var/log/teamtp/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 teamtp teamtp
}
LOG
  ok "Logrotate configured"
}

# ───── STEP 14: WELCOME ─────
save_welcome() {
  printf '%s\n' "$WIZARD_WELCOME" > "${TEAMTP_DIR}/config/welcome.txt"
  chown teamtp:teamtp "${TEAMTP_DIR}/config/welcome.txt"
}

# ───── SUMMARY ─────
print_summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"

  echo ""
  echo "══════════════════════════════════════"
  echo "  Installation Complete!"
  echo ""
  echo "  Connect: ${ip}:${PORT_VOICE}"

  echo "  Panel:   http://localhost:${PORT_PANEL}"
  if [[ -n "${WIZARD_DOMAIN:-}" ]]; then
    case "${WIZARD_SSL:-}" in
      letsencrypt|self-signed) echo "  Panel:   https://panel.${WIZARD_DOMAIN}" ;;
      *) echo "  Panel:   http://panel.${WIZARD_DOMAIN}" ;;
    esac
  else
    case "${WIZARD_SSL:-}" in
      letsencrypt|self-signed) echo "  Panel:   https://${ip} (accept self-signed cert warning)" ;;
      *) echo "  Panel:   http://${ip}" ;;
    esac
  fi

  echo "  Admin:   ${WIZARD_ADMIN_USER}"
  if [[ -n "${PRIVILEGE_KEY:-}" ]]; then
    echo "  Key:     ${PRIVILEGE_KEY:0:24}..."
  else
    echo "  Key:     (not captured — check journalctl -u teamspeak6)"
  fi
  echo ""
  warn "SAVE THE PRIVILEGE KEY ABOVE — only shown once!"
  echo ""
  echo "  Commands: teamtp status|restart|bot|panel|backup|update|wipe"
  echo "  Log:      ${INSTALL_LOG}"
  echo "══════════════════════════════════════"
}

# ───── WIPE ─────
wipe() {
  exec </dev/tty 2>/dev/null || true
  echo ""
  echo "WARNING: WIPE deletes ALL files, DBs, config"
  read -rp 'Type "DELETE" to confirm: ' c
  [[ "$c" != "DELETE" ]] && { echo "Aborted."; exit 1; }

  for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
  done

  rm -f /etc/systemd/system/teamspeak6.service /etc/systemd/system/teamtp-*.service
  systemctl daemon-reload
  rm -f /etc/nginx/sites-available/teamtp* /etc/nginx/sites-enabled/teamtp*
  nginx -t 2>/dev/null && systemctl reload nginx || true
  rm -rf "$TEAMTP_DIR" /usr/local/bin/teamtp "$INSTALL_LOG" /var/log/teamtp /etc/logrotate.d/teamtp
  echo "Wipe complete. Re-run install.sh for fresh install."
}

# ───── MAIN ─────
touch "$INSTALL_LOG" 2>/dev/null || true
exec 2>>"$INSTALL_LOG"

case "${1:-}" in
  --wipe|wipe) wipe ;;
  *)
    preflight
    wizard
    install_deps
    create_users
    deploy_files
    install_npm
    generate_secrets
    install_ts6
    setup_systemd
    install_cli
    save_welcome
    setup_nginx
    setup_firewall
    setup_logrotate
    print_summary
    touch "$MARKER"
    ok "Installation complete at ${TEAMTP_DIR}"
    ;;
esac
