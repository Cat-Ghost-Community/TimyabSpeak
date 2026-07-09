#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# TeamTP — TeamSpeak 6 One-Command Installer
# ═══════════════════════════════════════════════════════════

INSTALL_VERSION="1.1.0"
INSTALL_LOG="/var/log/teamtp-install.log"
TEAMTP_DIR="/opt/teamtp"
MARKER_FILE="${TEAMTP_DIR}/.installed"

# ─── CONFIGURABLE ──────────────────────────────────────────
# TS6 download URL — override with TS6_URL env var
TS6_DOWNLOAD_URL="${TS6_URL:-https://github.com/teamspeak/teamspeak6-server/releases/download/v6.0.0-beta11/tsserver_6.0.0-beta11_linux_x86_64.tar.gz}"
TS6_BINARY_NAME="tsserver"

# Private git repo via SSH — set TEAMTP_REPO env var
# Example: TEAMTP_REPO=git@github.com:yourname/TeamTP.git
# Must have SSH key deployed on server
TEAMTP_REPO="${TEAMTP_REPO:-}"

# ─── Color helpers ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $*" | tee -a "$INSTALL_LOG"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*" | tee -a "$INSTALL_LOG"; }
err()  { echo -e "${RED}[FAIL]${NC} $*" | tee -a "$INSTALL_LOG"; exit 1; }
info() { echo -e "${CYAN}[..]${NC} $*" | tee -a "$INSTALL_LOG"; }

# ─── Pre-flight ──────────────────────────────────────────────
check_root() { [[ $EUID -eq 0 ]] || err "Run as root: sudo bash install.sh"; }
check_os() {
  if grep -qi "ubuntu 22.04\|ubuntu 24.04\|debian 12" /etc/os-release 2>/dev/null; then
    log "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
  else
    warn "OS may have glibc < 2.32. TS6 needs glibc >= 2.32."
    warn "Supported: Ubuntu 22.04+, Debian 12+."
  fi
  [[ "$(uname -m)" == "x86_64" ]] || warn "Arch: $(uname -m) (x86_64 recommended, ARM64 needs libatomic1)"
}
check_disk() {
  local free=$(df /opt --output=avail 2>/dev/null | tail -1)
  [[ $free -ge 2097152 ]] || err "Need 2GB+ free in /opt (have $((free/1024))MB)"
  local mem=$(free -m | awk '/^Mem:/{print $2}')
  [[ $mem -ge 512 ]] || warn "RAM: ${mem}MB (512MB minimum recommended)"
}
check_dry_run() { [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1 || DRY_RUN=0; }
check_wipe_mode() {
  WIPE_MODE=0
  if [[ "${1:-}" == "--wipe" || "${2:-}" == "--wipe" ]]; then
    WIPE_MODE=1
    log "WIPE MODE: will remove all files and reinstall"
  fi
}
check_idempotent() {
  if [[ -f "$MARKER_FILE" ]]; then
    UPDATE_MODE=1
    info "Existing install detected (${MARKER_FILE})"
  else
    UPDATE_MODE=0
  fi
}

# ─── Wipe mode ────────────────────────────────────────────────
wipe_all() {
  echo ""
  echo "╔═══════════════════════════════════════════╗"
  echo "║     ⚠️  WIPE MODE — DESTRUCTIVE ACTION    ║"
  echo "║                                           ║"
  echo "║  This will DELETE everything:             ║"
  echo "║  - /opt/teamtp/ (all config, DBs, files)  ║"
  echo "║  - systemd services for TS6 + bots + panel║"
  echo "║  - nginx config for teamtp               ║"
  echo "║  - TeamSpeak 6 server binary + data       ║"
  echo "║                                           ║"
  echo "║  Backups will NOT be kept.                ║"
  echo "╚═══════════════════════════════════════════╝"
  echo ""
  read -rp 'Type "DELETE" to confirm: ' confirm
  [[ "$confirm" != "DELETE" ]] && { echo "Aborted."; exit 1; }

  info "Stopping all services..."
  for svc in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done

  info "Removing systemd units..."
  rm -f /etc/systemd/system/teamspeak6.service \
        /etc/systemd/system/teamtp-panel.service \
        /etc/systemd/system/teamtp-level-bot.service \
        /etc/systemd/system/teamtp-temp-bot.service \
        /etc/systemd/system/teamtp-support-bot.service
  systemctl daemon-reload

  info "Removing nginx config..."
  rm -f /etc/nginx/sites-available/teamtp /etc/nginx/sites-available/teamtp-ssl
  rm -f /etc/nginx/sites-enabled/teamtp /etc/nginx/sites-enabled/teamtp-ssl
  nginx -t 2>/dev/null && systemctl reload nginx || true

  info "Removing /opt/teamtp..."
  rm -rf "$TEAMTP_DIR"

  info "Removing log files..."
  rm -f "$INSTALL_LOG"
  rm -rf /var/log/teamtp/

  info "Removing teamtp CLI..."
  rm -f /usr/local/bin/teamtp

  info "Removing logrotate config..."
  rm -f /etc/logrotate.d/teamtp

  log "Wipe complete. System is clean. Re-run install.sh for fresh install."
  exit 0
}

# ─── Detect repo / determine source dir ───────────────────────
detect_repo() {
  SRC_DIR="${SRC_DIR:-}"
  USE_GIT=0

  # If TEAMTP_REPO is set, use git clone
  if [[ -n "$TEAMTP_REPO" ]]; then
    USE_GIT=1
    log "Using git repo: ${TEAMTP_REPO}"
    return
  fi

  # Detect if running from within a git repo
  local script_dir
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"
  elif [[ -n "${0:-}" && "$0" != "bash" ]]; then
    script_dir="$(cd "$(dirname "$0")" && pwd 2>/dev/null)"
  else
    script_dir="$PWD"
  fi

  if [[ -d "${script_dir}/.git" ]]; then
    local remote
    remote=$(cd "$script_dir" && git remote get-url origin 2>/dev/null || true)
    if echo "$remote" | grep -q "git@github.com:"; then
      TEAMTP_REPO="$remote"
      USE_GIT=1
      log "Detected private repo: ${remote}"
      return
    fi
  fi

  SRC_DIR="$script_dir"
  USE_GIT=0
  info "Source directory: ${SRC_DIR}"
}

# ─── Port scanner ──────────────────────────────────────────────
find_available_port() {
  local base=$1 max_offset=${2:-10} proto=${3:-tcp}
  for offset in $(seq 0 $max_offset); do
    local port=$((base + offset))
    if [[ "$proto" == "udp" ]]; then
      ss -uln 2>/dev/null | grep -q ":$port " || { echo "$port"; return 0; }
    else
      ss -tln 2>/dev/null | grep -q ":$port " || { echo "$port"; return 0; }
    fi
  done
  echo ""
}

scan_ports() {
  info "Scanning ports..."
  PORT_VOICE=$(find_available_port 9987 20 udp);        [[ -n "$PORT_VOICE" ]]   || PORT_VOICE=9987
  PORT_FILE=$(find_available_port 30033 10);             [[ -n "$PORT_FILE" ]]    || PORT_FILE=30033
  PORT_SSH_QUERY=$(find_available_port 10022 10);        [[ -n "$PORT_SSH_QUERY" ]] || PORT_SSH_QUERY=10022
  PORT_HTTP_QUERY=$(find_available_port 10080 10);       [[ -n "$PORT_HTTP_QUERY" ]] || PORT_HTTP_QUERY=10080
  PORT_PANEL=$(find_available_port 3000 10);             [[ -n "$PORT_PANEL" ]]   || PORT_PANEL=3000
  PORT_HTTP=$(find_available_port 80 5);                 [[ -n "$PORT_HTTP" ]]    || PORT_HTTP=80
  PORT_HTTPS=$(find_available_port 443 5);               [[ -n "$PORT_HTTPS" ]]   || PORT_HTTPS=443
  log "Ports: Voice=${PORT_VOICE} File=${PORT_FILE} Query(SSH)=${PORT_SSH_QUERY} Query(HTTP)=${PORT_HTTP_QUERY} Panel=${PORT_PANEL}"
}

# ─── OS deps ────────────────────────────────────────────────────
install_deps() {
  info "Installing system dependencies..."
  apt-get update -qq || warn "apt update failed"
  apt-get install -y -qq curl wget gnupg whiptail nginx certbot python3-certbot-nginx python3-bcrypt \
    ufw fail2ban logrotate unattended-upgrades openssl 2>&1 | tail -1 || warn "Some deps failed"

  if [[ "$(uname -m)" == "aarch64" ]]; then
    apt-get install -y -qq libatomic1 2>&1 | tail -1 || true
  fi

  if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 20 ]]; then
    info "Installing Node.js 20.x..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs 2>&1 | tail -1
  fi
  log "Node.js $(node -v), npm $(npm -v)"
}

# ─── System users ───────────────────────────────────────────────
create_users() {
  info "Creating system users..."
  id -u tsserver &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin tsserver
  id -u teamtp &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin teamtp
  mkdir -p "$TEAMTP_DIR"
  chown -R teamtp:teamtp "$TEAMTP_DIR"
  log "Users: tsserver, teamtp"
}

# ─── Deploy source files ────────────────────────────────────────
deploy_files() {
  if [[ $USE_GIT -eq 1 && -n "$TEAMTP_REPO" ]]; then
    info "Cloning from ${TEAMTP_REPO}..."
    if [[ -d "${TEAMTP_DIR}/.git" ]]; then
      cd "$TEAMTP_DIR" && git pull 2>/dev/null || warn "Git pull failed"
    else
      rm -rf "$TEAMTP_DIR"
      git clone "$TEAMTP_REPO" "$TEAMTP_DIR" 2>&1 || err "Git clone failed. Check SSH key and repo URL."
    fi
    chown -R teamtp:teamtp "$TEAMTP_DIR"
    log "Git repo deployed"
    return
  fi

  # Local copy fallback
  local src="${SRC_DIR:-$PWD}"
  info "Copying files from ${src}..."
  mkdir -p "$TEAMTP_DIR"

  for subdir in config shared scripts bots/level-bot bots/temp-channel-bot bots/support-bot panel panel/routes panel/services panel/public systemd; do
    if [[ -d "${src}/${subdir}" ]]; then
      mkdir -p "${TEAMTP_DIR}/${subdir}"
      cp -r "${src}/${subdir}/." "${TEAMTP_DIR}/${subdir}/"
    fi
  done

  [[ -f "${src}/.env.example" ]] && cp "${src}/.env.example" "${TEAMTP_DIR}/.env.example"
  [[ -f "${src}/install.sh" ]] && cp "${src}/install.sh" "${TEAMTP_DIR}/install.sh"

  chown -R teamtp:teamtp "$TEAMTP_DIR"
  find "$TEAMTP_DIR" -type f -name "*.sh" -exec chmod +x {} \;
  log "Files deployed"
}

# ─── Wizard input ────────────────────────────────────────────────
run_wizard() {
  if [[ $DRY_RUN -eq 1 ]]; then
    WIZARD_DOMAIN=""; WIZARD_SSL="none"
    WIZARD_SERVER_NAME="My Gaming Community"; WIZARD_ADMIN_USER="admin"
    WIZARD_ADMIN_PASS="admin123"; WIZARD_COMMUNITY="Gaming"
    WIZARD_WELCOME="Welcome!"; WIZARD_SLOTS=64
    return
  fi

  local use_whiptail=false
  command -v whiptail &>/dev/null && use_whiptail=true

  if ! $use_whiptail; then
    # Plain text wizard
    echo ""
    echo "=== TeamTP Setup Wizard ==="
    read -rp "Domain (blank for IP-based): " WIZARD_DOMAIN
    if [[ -z "$WIZARD_DOMAIN" ]]; then
      WIZARD_SSL="none"
    else
      read -rp "SSL (letsencrypt/self-signed/none) [none]: " ssl_choice
      WIZARD_SSL="${ssl_choice:-none}"
    fi
    read -rp "Server name [My Gaming Community]: " tmp
    WIZARD_SERVER_NAME="${tmp:-My Gaming Community}"
    read -rp "Admin username [admin]: " tmp; WIZARD_ADMIN_USER="${tmp:-admin}"
    while true; do
      read -rsp "Admin password (min 8 chars): " tmp; echo
      [[ ${#tmp} -ge 8 ]] && break
      echo "Too short. Need 8+ characters."
    done
    WIZARD_ADMIN_PASS="$tmp"
    read -rp "Community name [Gaming]: " tmp; WIZARD_COMMUNITY="${tmp:-Gaming}"
    read -rp "Max slots [64]: " tmp; WIZARD_SLOTS="${tmp:-64}"
    read -rp "Welcome message [Welcome!]: " tmp; WIZARD_WELCOME="${tmp:-Welcome!}"
  else
    # whiptail wizard
    WIZARD_DOMAIN=$(whiptail --inputbox "Domain name (blank = IP-based)" 8 60 "" 3>&1 1>&2 2>&3)
    if [[ -z "$WIZARD_DOMAIN" ]]; then
      WIZARD_SSL=$(whiptail --menu "SSL for IP?" 10 50 2 \
        "none" "No SSL" \
        "self-signed" "Self-signed cert" 3>&1 1>&2 2>&3)
    else
      WIZARD_SSL=$(whiptail --menu "SSL for ${WIZARD_DOMAIN}?" 10 50 2 \
        "letsencrypt" "Let's Encrypt (auto)" \
        "self-signed" "Self-signed" \
        "none" "No SSL" 3>&1 1>&2 2>&3)
    fi
    WIZARD_SERVER_NAME=$(whiptail --inputbox "Server name" 8 60 "My Gaming Community" 3>&1 1>&2 2>&3)
    WIZARD_ADMIN_USER=$(whiptail --inputbox "Admin username" 8 60 "admin" 3>&1 1>&2 2>&3)
    while true; do
      WIZARD_ADMIN_PASS=$(whiptail --passwordbox "Admin password (min 8 chars)" 8 60 3>&1 1>&2 2>&3)
      [[ ${#WIZARD_ADMIN_PASS} -ge 8 ]] && break
      whiptail --msgbox "Password too short. Need 8+ characters." 6 50
    done
    WIZARD_COMMUNITY=$(whiptail --inputbox "Community name" 8 60 "Gaming" 3>&1 1>&2 2>&3)
    WIZARD_WELCOME=$(whiptail --inputbox "Welcome message" 8 60 "Welcome to the community!" 3>&1 1>&2 2>&3)
    WIZARD_SLOTS=$(whiptail --inputbox "Max slots" 8 60 "64" 3>&1 1>&2 2>&3)
  fi
  log "Wizard: ${WIZARD_SERVER_NAME} (${WIZARD_DOMAIN:-IP})"
}

# ─── Generate secrets ────────────────────────────────────────────
generate_secrets() {
  info "Generating secrets..."
  SECRET_QUERY_PASS=$(openssl rand -hex 16)
  SECRET_API_KEY=$(openssl rand -hex 32)
  SECRET_JWT=$(openssl rand -hex 32)
  SECRET_REFRESH=$(openssl rand -hex 32)

  # Use python3 bcrypt to generate proper hash (panel uses bcrypt.compare)
  PANEL_BCRYPT_HASH=$(python3 -c "
import bcrypt
hash = bcrypt.hashpw(b'${WIZARD_ADMIN_PASS}', bcrypt.gensalt(rounds=12))
print(hash.decode())
" 2>/dev/null) || PANEL_BCRYPT_HASH=$(openssl passwd -6 "${WIZARD_ADMIN_PASS}" 2>/dev/null || echo "${WIZARD_ADMIN_PASS}")

  cat > "${TEAMTP_DIR}/.env" <<EOF
TS6_BASE_URL=http://127.0.0.1:${PORT_HTTP_QUERY}
TS6_API_KEY=${SECRET_API_KEY}
TS6_QUERY_HOST=127.0.0.1
TS6_QUERY_PORT=${PORT_SSH_QUERY}
TS6_QUERY_PASSWORD=${SECRET_QUERY_PASS}
PANEL_PORT=${PORT_PANEL}
PANEL_BIND=127.0.0.1
PANEL_JWT_SECRET=${SECRET_JWT}
PANEL_REFRESH_SECRET=${SECRET_REFRESH}
PANEL_ADMIN_USER=${WIZARD_ADMIN_USER}
PANEL_ADMIN_HASH=${PANEL_BCRYPT_HASH}
TEAMTP_VERSION=${INSTALL_VERSION}
INSTALL_DATE=$(date +%s)
EOF
  chmod 600 "${TEAMTP_DIR}/.env"
  chown teamtp:teamtp "${TEAMTP_DIR}/.env"
  log "Secrets generated (bcrypt panel hash)"
}

# ─── TS6 Server ─────────────────────────────────────────────────
install_ts6() {
  info "Downloading TS6 server..."
  local ts6_dir="${TEAMTP_DIR}/server/teamspeak6"
  mkdir -p "$ts6_dir"

  if [[ -f "${ts6_dir}/${TS6_BINARY_NAME}" ]]; then
    log "TS6 binary exists, skipping download"
  else
    local tmp_file
    tmp_file=$(mktemp)
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp_file" "$TS6_DOWNLOAD_URL" || err "Download failed. Check TS6_DOWNLOAD_URL"
    tar -xzf "$tmp_file" -C "$ts6_dir" --strip-components=1 || err "Extract failed"
    rm -f "$tmp_file"
    chmod +x "${ts6_dir}/${TS6_BINARY_NAME}"
    log "TS6 downloaded and extracted"
  fi

  chown -R tsserver:tsserver "$ts6_dir"

  cat > "${ts6_dir}/tsserver.yaml" <<YAML
server:
  license-path: .
  accept-license: accept
  default-voice-port: ${PORT_VOICE}
  voice-ip:
    - "0.0.0.0"
    - "::"
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
    sql-path: ${ts6_dir}/sql/
    sql-create-path: ${ts6_dir}/sql/create_sqlite/
YAML
  chown tsserver:tsserver "${ts6_dir}/tsserver.yaml"
  log "TS6 config written"
}

# ─── systemd: TS6 ────────────────────────────────────────────────
setup_systemd_ts6() {
  cat > /etc/systemd/system/teamspeak6.service <<UNIT
[Unit]
Description=TeamSpeak 6 Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=tsserver
Group=tsserver
WorkingDirectory=${TEAMTP_DIR}/server/teamspeak6
ExecStart=${TEAMTP_DIR}/server/teamspeak6/${TS6_BINARY_NAME} --config-file ${TEAMTP_DIR}/server/teamspeak6/tsserver.yaml
ExecStop=/bin/kill -SIGTERM \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=4096
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable teamspeak6
  systemctl start teamspeak6 || warn "TS6 start failed"
  log "TS6 systemd service started"

  sleep 3
  local healthy=false
  for i in 1 2 3 4 5; do
    if ss -tln | grep -q ":${PORT_HTTP_QUERY} "; then
      healthy=true; break
    fi
    sleep 2
  done
  $healthy || warn "TS6 health check: HTTP query not responding. Check: journalctl -u teamspeak6 -n 30"
}

# ─── Capture privilege key ──────────────────────────────────────
capture_privilege_key() {
  sleep 2
  PRIVILEGE_KEY=$(journalctl -u teamspeak6 --no-pager -n 100 2>/dev/null | grep -oP "token=\K\S+" | head -1 || true)
  if [[ -n "$PRIVILEGE_KEY" ]]; then
    log "Privilege key: ${PRIVILEGE_KEY:0:16}..."
    echo "TS6_PRIVILEGE_KEY=${PRIVILEGE_KEY}" >> "${TEAMTP_DIR}/.env"
  else
    warn "Could not auto-capture privilege key."
    warn "Check: journalctl -u teamspeak6 | grep token"
  fi
}

# ─── Apply welcome message ──────────────────────────────────────
apply_welcome() {
  # TS6 sets welcome via YAML config or REST API
  # Fallback: write to a file the panel/bot can read
  echo "${WIZARD_WELCOME}" > "${TEAMTP_DIR}/config/welcome.txt"
  chown teamtp:teamtp "${TEAMTP_DIR}/config/welcome.txt"
  log "Welcome message saved"
}

# ─── npm install bots ────────────────────────────────────────────
install_bot_deps() {
  info "Installing bot dependencies..."
  for bot_dir in level-bot temp-channel-bot support-bot; do
    local pkg="${TEAMTP_DIR}/bots/${bot_dir}/package.json"
    if [[ ! -f "$pkg" ]]; then
      cat > "$pkg" <<JSON
{
  "name": "teamtp-${bot_dir}",
  "version": "1.0.0",
  "private": true,
  "main": "index.js",
  "dependencies": { "better-sqlite3": "^11.0.0" }
}
JSON
    fi
    cd "${TEAMTP_DIR}/bots/${bot_dir}"
    npm install --silent 2>&1 | tail -1 || warn "npm install failed for ${bot_dir}"
  done
  log "Bot dependencies installed"
}

# ─── systemd: bots ───────────────────────────────────────────────
setup_systemd_bots() {
  for bot_name in level temp support; do
    local dir_name="${bot_name}-bot"
    [[ "$bot_name" == "temp" ]] && dir_name="temp-channel-bot"

    cat > "/etc/systemd/system/teamtp-${bot_name}-bot.service" <<UNIT
[Unit]
Description=TeamTP ${bot_name^} Bot
After=teamspeak6.service
Wants=teamspeak6.service

[Service]
Type=simple
User=teamtp
Group=teamtp
WorkingDirectory=${TEAMTP_DIR}/bots/${dir_name}
ExecStart=/usr/bin/node ${TEAMTP_DIR}/bots/${dir_name}/index.js
EnvironmentFile=${TEAMTP_DIR}/.env
Restart=on-failure
RestartSec=10
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
UNIT
  done
  systemctl daemon-reload
  for bot_name in level temp support; do
    systemctl enable "teamtp-${bot_name}-bot" 2>/dev/null || true
    systemctl start "teamtp-${bot_name}-bot" 2>/dev/null || warn "Bot ${bot_name} start failed"
    sleep 1
  done
  log "Bot services started"
}

# ─── Web panel ──────────────────────────────────────────────────
install_panel() {
  info "Installing web panel..."
  local pkg="${TEAMTP_DIR}/panel/package.json"
  if [[ ! -f "$pkg" ]]; then
    cat > "$pkg" <<JSON
{
  "name": "teamtp-panel",
  "version": "1.0.0",
  "private": true,
  "main": "server.js",
  "dependencies": {
    "express": "^4.21.0",
    "socket.io": "^4.7.0",
    "jsonwebtoken": "^9.0.0",
    "bcrypt": "^5.1.0",
    "helmet": "^7.0.0",
    "better-sqlite3": "^11.0.0"
  }
}
JSON
  fi

  cd "${TEAMTP_DIR}/panel"
  npm install --silent 2>&1 | tail -1 || warn "Panel npm install failed"

  cat > /etc/systemd/system/teamtp-panel.service <<UNIT
[Unit]
Description=TeamTP Web Panel
After=teamspeak6.service
Wants=teamspeak6.service

[Service]
Type=simple
User=teamtp
Group=teamtp
WorkingDirectory=${TEAMTP_DIR}/panel
ExecStart=/usr/bin/node ${TEAMTP_DIR}/panel/server.js
EnvironmentFile=${TEAMTP_DIR}/.env
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable teamtp-panel
  systemctl start teamtp-panel || warn "Panel start failed"
  log "Web panel installed"
}

# ─── teamtp CLI ──────────────────────────────────────────────────
install_cli() {
  cat > /usr/local/bin/teamtp <<'CLIEOF'
#!/usr/bin/env bash
set -euo pipefail

TEAMTP_DIR="/opt/teamtp"
ENV_FILE="${TEAMTP_DIR}/.env"
INSTALL_LOG="/var/log/teamtp-install.log"

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
  fi
}

cmd_status() {
  echo "═══ TeamTP Status ═══"
  for svc in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    local s
    s=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    printf "  %-30s %s\n" "$svc" "$s"
  done
  echo ""
  echo "  Installed: $([[ -f "${TEAMTP_DIR}/.installed" ]] && echo 'Yes' || echo 'No')"
  echo "  Version: $(grep TEAMTP_VERSION "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || echo 'unknown')"
}

cmd_restart() {
  systemctl restart teamspeak6 || true
  for svc in teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl restart "$svc" 2>/dev/null || true
  done
  echo "All services restarted"
}

cmd_panel() {
  local port="${1:-3000}"
  echo "Panel: http://localhost:${port}"
  systemctl status teamtp-panel --no-pager 2>/dev/null | head -5
}

cmd_bot() {
  local bot="$1" action="$2"
  if [[ -z "$bot" || -z "$action" ]]; then
    echo "Usage: teamtp bot <level|temp|support> <on|off|restart|status>"
    return 1
  fi
  case "$bot" in
    level|temp|support) ;;
    *) echo "Invalid bot. Use: level, temp, support"; return 1 ;;
  esac
  case "$action" in
    on) systemctl start "teamtp-${bot}-bot" && echo "${bot}-bot started" ;;
    off) systemctl stop "teamtp-${bot}-bot" && echo "${bot}-bot stopped" ;;
    restart) systemctl restart "teamtp-${bot}-bot" && echo "${bot}-bot restarted" ;;
    status)
      local s; s=$(systemctl is-active "teamtp-${bot}-bot" 2>/dev/null || echo "inactive")
      echo "${bot}-bot: $s" ;;
    *) echo "Invalid action. Use: on, off, restart, status"; return 1 ;;
  esac
}

cmd_ssl() {
  certbot renew 2>&1 | tail -5
  systemctl reload nginx 2>/dev/null || true
  echo "SSL renew complete"
}

cmd_backup() {
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local file="${TEAMTP_DIR}/backups/teamtp-${ts}.tar.gz"
  mkdir -p "${TEAMTP_DIR}/backups"
  tar -czf "$file" -C "$TEAMTP_DIR" .env config/ 2>/dev/null || true
  # Add SQLite files if they exist
  for db in bots/level-bot/data.sqlite bots/temp-channel-bot/temp-channels.sqlite bots/support-bot/tickets.sqlite; do
    [[ -f "${TEAMTP_DIR}/${db}" ]] && tar -rf "$file" -C "$TEAMTP_DIR" "$db" 2>/dev/null || true
  done
  echo "Backup: $file ($(du -h "$file" | cut -f1))"

  # Prune old backups (keep 30 days)
  find "${TEAMTP_DIR}/backups" -name "teamtp-*.tar.gz" -mtime +30 -delete 2>/dev/null || true
}

cmd_update() {
  echo "═══ TeamTP Update ═══"

  # Pre-update backup
  cmd_backup
  echo ""

  # Git pull if git repo
  if [[ -d "${TEAMTP_DIR}/.git" ]]; then
    cd "$TEAMTP_DIR"
    git pull 2>&1 || echo "Git pull failed, continuing with local files"
  fi

  # Update npm deps
  for d in panel bots/level-bot bots/temp-channel-bot bots/support-bot; do
    if [[ -f "${TEAMTP_DIR}/${d}/package.json" ]]; then
      echo "  npm ci: ${d}..."
      (cd "${TEAMTP_DIR}/${d}" && npm ci --silent 2>/dev/null) || (cd "${TEAMTP_DIR}/${d}" && npm install --silent 2>/dev/null) || true
    fi
  done

  systemctl daemon-reload
  for svc in teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot teamtp-panel; do
    systemctl restart "$svc" 2>/dev/null || true
    sleep 1
  done

  echo "Update complete. Restarted all services."
}

cmd_health() {
  systemctl is-active teamspeak6 >/dev/null 2>&1 || { echo "DOWN: teamspeak6"; exit 1; }
  for svc in teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl is-active "$svc" >/dev/null 2>&1 || { echo "WARN: $svc not running"; }
  done
  echo "OK"
  exit 0
}

cmd_logs() {
  local svc="${1:-teamspeak6}"
  local lines="${2:-50}"
  journalctl -u "$svc" --no-pager -n "$lines"
}

cmd_wipe() {
  echo ""
  echo "⚠️  WIPE MODE"
  echo "This will DELETE all TeamTP files, DBs, services, and config."
  echo "Backup recommended first: teamtp backup"
  echo ""
  read -rp 'Type "DELETE" to confirm: ' confirm
  [[ "$confirm" != "DELETE" ]] && { echo "Aborted."; exit 1; }

  for svc in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done

  rm -f /etc/systemd/system/teamspeak6.service \
        /etc/systemd/system/teamtp-panel.service \
        /etc/systemd/system/teamtp-level-bot.service \
        /etc/systemd/system/teamtp-temp-bot.service \
        /etc/systemd/system/teamtp-support-bot.service
  systemctl daemon-reload

  rm -f /etc/nginx/sites-available/teamtp /etc/nginx/sites-available/teamtp-ssl
  rm -f /etc/nginx/sites-enabled/teamtp /etc/nginx/sites-enabled/teamtp-ssl
  nginx -t 2>/dev/null && systemctl reload nginx || true

  rm -rf "$TEAMTP_DIR"
  rm -f /usr/local/bin/teamtp
  rm -f "$INSTALL_LOG"
  rm -rf /var/log/teamtp/
  rm -f /etc/logrotate.d/teamtp

  echo "Wipe complete. System clean."
}

case "${1:-help}" in
  status) load_env; cmd_status ;;
  restart) cmd_restart ;;
  panel) load_env; cmd_panel "${2:-}" ;;
  bot) cmd_bot "${2:-}" "${3:-}" ;;
  ssl) cmd_ssl ;;
  backup) cmd_backup ;;
  update) cmd_update ;;
  health) cmd_health ;;
  wipe) cmd_wipe ;;
  logs) cmd_logs "${2:-}" "${3:-}" ;;
  help|--help|-h)
    echo "Usage: teamtp <command> [args]"
    echo ""
    echo "  status              Server and bot status"
    echo "  restart             Restart all services"
    echo "  panel [port]        Show panel info"
    echo "  bot <l|t|s> <act>   Control bot (level|temp|support) (on|off|restart|status)"
    echo "  ssl                 Renew Let's Encrypt"
    echo "  backup              Create backup (keeps 30 days)"
    echo "  update              Pull git + npm update + restart all"
    echo "  health              Health check (exit 0/1)"
    echo "  wipe                DELETE everything (destructive)"
    echo "  logs [svc] [lines]  View journald logs"
    ;;
  *) cmd_status ;;
esac
CLIEOF
  chmod +x /usr/local/bin/teamtp
  log "teamtp CLI installed to /usr/local/bin/teamtp"
}

# ─── nginx vhost + SSL ──────────────────────────────────────────
setup_nginx() {
  if [[ -z "${WIZARD_DOMAIN:-}" ]]; then
    log "No domain. Panel at http://localhost:${PORT_PANEL}"
    return
  fi

  local domain="$WIZARD_DOMAIN"
  local public_ip
  public_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

  cat > "/etc/nginx/sites-available/teamtp" <<NGX
server {
    listen ${PORT_HTTP};
    server_name ${domain} panel.${domain};

    location / {
        proxy_pass http://127.0.0.1:${PORT_PANEL};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
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
    }
}
NGX
  ln -sf "/etc/nginx/sites-available/teamtp" "/etc/nginx/sites-enabled/"
  rm -f /etc/nginx/sites-enabled/default

  if [[ "${WIZARD_SSL:-}" == "letsencrypt" ]]; then
    certbot --nginx -d "$domain" -d "panel.${domain}" \
      --non-interactive --agree-tos --email "admin@${domain}" \
      2>&1 | tail -1 || warn "Let's Encrypt failed"
    log "SSL: Let's Encrypt for ${domain}"
  elif [[ "${WIZARD_SSL:-}" == "self-signed" ]]; then
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "/etc/nginx/ssl/teamtp.key" \
      -out "/etc/nginx/ssl/teamtp.crt" \
      -subj "/CN=${domain}" 2>/dev/null

    cat > "/etc/nginx/sites-available/teamtp-ssl" <<NGX
server {
    listen ${PORT_HTTPS} ssl http2;
    server_name ${domain} panel.${domain};
    ssl_certificate /etc/nginx/ssl/teamtp.crt;
    ssl_certificate_key /etc/nginx/ssl/teamtp.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:${PORT_PANEL};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location /socket.io/ {
        proxy_pass http://127.0.0.1:${PORT_PANEL};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGX
    ln -sf "/etc/nginx/sites-available/teamtp-ssl" "/etc/nginx/sites-enabled/"
  fi

  nginx -t 2>/dev/null && systemctl reload nginx || warn "Nginx config test failed"
  log "Nginx configured: ${domain} (IP: ${public_ip})"
}

# ─── Firewall ──────────────────────────────────────────────────
setup_firewall() {
  info "Configuring firewall..."
  ufw --force reset 2>/dev/null || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${PORT_VOICE}/udp" comment "TS6 Voice"
  ufw allow "${PORT_HTTP}/tcp" comment "HTTP"
  ufw allow "${PORT_HTTPS}/tcp" comment "HTTPS"
  ufw allow ssh comment "SSH"
  ufw --force enable 2>&1 | tail -1
  log "Firewall: ports ${PORT_VOICE}/udp, ${PORT_HTTP}/tcp, ${PORT_HTTPS}/tcp, ssh"

  if command -v fail2ban &>/dev/null; then
    cat > /etc/fail2ban/jail.local <<F2B
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true
F2B
    systemctl restart fail2ban 2>/dev/null || true
    log "fail2ban configured"
  fi
}

# ─── Logrotate ──────────────────────────────────────────────────
setup_logrotate() {
  mkdir -p /var/log/teamtp
  chown teamtp:teamtp /var/log/teamtp

  cat > /etc/logrotate.d/teamtp <<LOGROTATE
/var/log/teamtp/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 teamtp teamtp
}
LOGROTATE
  log "Logrotate: /var/log/teamtp/"
}

# ─── Summary ──────────────────────────────────────────────────
print_summary() {
  local public_ip
  public_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$public_ip" ]] && public_ip="<server-ip>"

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║           TeamTP Installation Complete!      ║"
  echo "╠══════════════════════════════════════════════╣"
  echo "║  Server: ${WIZARD_SERVER_NAME:0:40}"
  echo "║  Connect: ${public_ip}:${PORT_VOICE}"
  if [[ -n "${WIZARD_DOMAIN:-}" ]]; then
    echo "║  Panel: https://panel.${WIZARD_DOMAIN}"
  fi
  echo "║  Panel: http://localhost:${PORT_PANEL}"
  echo "║  Admin: ${WIZARD_ADMIN_USER}"
  echo "║  Key:   ${PRIVILEGE_KEY:0:24}..."
  echo "║"
  echo "║  teamtp commands:"
  echo "║    teamtp status     — status"
  echo "║    teamtp restart    — restart all"
  echo "║    teamtp bot l|t|s  — bot control"
  echo "║    teamtp update     — full update"
  echo "║    teamtp backup     — create backup"
  echo "║    teamtp wipe       — uninstall everything"
  echo "║"
  echo "║  Logs:    ${INSTALL_LOG}"
  echo "║  Config:  ${TEAMTP_DIR}/.env"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  warn "SAVE THE PRIVILEGE KEY — it is shown only once!"
}

# ═══════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════

main() {
  exec > >(tee -a "$INSTALL_LOG") 2>&1

  check_dry_run "${1:-}"
  check_wipe_mode "${@:-}"

  [[ $WIPE_MODE -eq 1 ]] && { wipe_all; return; }

  echo "──────────────────────────────────────────"
  echo " TeamTP v${INSTALL_VERSION} — $(date)"
  echo "──────────────────────────────────────────"

  check_root
  check_os
  check_disk
  check_idempotent
  detect_repo
  scan_ports

  run_wizard
  [[ $DRY_RUN -eq 1 ]] && { info "Dry-run complete"; return 0; }

  install_deps
  create_users
  deploy_files
  generate_secrets
  install_ts6
  setup_systemd_ts6
  capture_privilege_key
  apply_welcome

  install_bot_deps
  setup_systemd_bots
  install_panel
  install_cli

  setup_nginx
  setup_firewall
  setup_logrotate
  print_summary

  touch "$MARKER_FILE"
  log "Installation complete"
}

main "$@"
