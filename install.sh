#!/usr/bin/env bash
set -euo pipefail

INSTALL_VERSION="1.2.0"
INSTALL_LOG="/var/log/teamtp-install.log"
TEAMTP_DIR="/opt/teamtp"

# Configurable
TS6_DOWNLOAD_URL="${TS6_URL:-https://github.com/teamspeak/teamspeak6-server/releases/download/v6.0.0-beta11/tsserver_6.0.0-beta11_linux_x86_64.tar.gz}"
TS6_BINARY_NAME="tsserver"
TEAMTP_REPO="${TEAMTP_REPO:-}"

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[..]${NC} $*"; }

# ──────────────────────────────────────────────
#  STEP 1: Pre-flight
# ──────────────────────────────────────────────
preflight() {
  [[ $EUID -eq 0 ]] || fail "Run as root: sudo bash install.sh"

  echo "──────────────────────────────────────"
  echo " TimyabSpeak v${INSTALL_VERSION} — TeamSpeak 6 Installer"
  echo "──────────────────────────────────────"

  # Check OS
  if grep -qi "ubuntu 22.04\|ubuntu 24.04\|debian 12" /etc/os-release 2>/dev/null; then
    ok "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
  else
    warn "Recommended: Ubuntu 22.04+ / Debian 12+"
  fi

  # Check arch
  local arch
  arch=$(uname -m)
  info "Arch: ${arch}"

  # Check RAM
  local mem
  mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}') || mem=0
  if [[ $mem -lt 512 ]]; then
    warn "RAM: ${mem}MB (512MB min recommended)"
  else
    ok "RAM: ${mem}MB"
  fi

  # Check disk
  local free
  free=$(df / --output=avail 2>/dev/null | tail -1) || free=0
  if [[ $free -lt 2097152 ]]; then
    fail "Need 2GB+ free disk space (have $((free/1024))MB)"
  fi

  # Check existing install
  if [[ -f "${TEAMTP_DIR}/.installed" ]]; then
    warn "Existing install found at ${TEAMTP_DIR}"
    warn "Run 'teamtp update' to update, or backup and remove first"
  fi
}

# ──────────────────────────────────────────────
#  STEP 2: Wizard
# ──────────────────────────────────────────────
wizard() {
  # Get terminal for input (works with curl | bash)
  exec </dev/tty 2>/dev/null || true

  echo ""
  echo "========== Setup Wizard =========="
  echo "Press Enter to accept [defaults]"
  echo "Press Ctrl+C to cancel"
  echo ""

  read -rp "Domain name (blank for IP): " WIZARD_DOMAIN

  if [[ -z "$WIZARD_DOMAIN" ]]; then
    echo "  SSL options:"
    echo "    1) No SSL"
    echo "    2) Self-signed cert"
    read -rp "  Choose [1]: " ssl_choice
    case "${ssl_choice:-1}" in
      2) WIZARD_SSL="self-signed" ;;
      *) WIZARD_SSL="none" ;;
    esac
  else
    echo "  SSL options:"
    echo "    1) Let's Encrypt (auto)"
    echo "    2) Self-signed"
    echo "    3) No SSL"
    read -rp "  Choose [1]: " ssl_choice
    case "${ssl_choice:-1}" in
      2) WIZARD_SSL="self-signed" ;;
      3) WIZARD_SSL="none" ;;
      *) WIZARD_SSL="letsencrypt" ;;
    esac
  fi

  read -rp "Server name [My Gaming Community]: " tmp
  WIZARD_SERVER_NAME="${tmp:-My Gaming Community}"

  read -rp "Admin username [admin]: " tmp
  WIZARD_ADMIN_USER="${tmp:-admin}"

  while true; do
    read -rsp "Admin password (min 8 chars): " tmp; echo
    [[ ${#tmp} -ge 8 ]] && break
    echo "Too short."
  done
  WIZARD_ADMIN_PASS="$tmp"

  read -rp "Max slots [64]: " tmp
  WIZARD_SLOTS="${tmp:-64}"

  read -rp "Welcome message [Welcome!]: " tmp
  WIZARD_WELCOME="${tmp:-Welcome!}"

  ok "Wizard complete"
}

# ──────────────────────────────────────────────
#  STEP 3: Install system deps
# ──────────────────────────────────────────────
install_deps() {
  info "Installing system packages..."
  apt-get update -qq || warn "apt update had issues"
  apt-get install -y -qq curl wget nginx openssl ufw fail2ban logrotate python3-bcrypt \
    unattended-upgrades 2>&1 | tail -1 || warn "Some packages failed"

  # Node.js 20+
  if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 20 ]]; then
    info "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs 2>&1 | tail -1
  fi
  ok "Node.js $(node -v)"
  ok "npm $(npm -v)"
}

# ──────────────────────────────────────────────
#  STEP 4: Create users
# ──────────────────────────────────────────────
create_users() {
  info "Creating system users..."
  id -u tsserver &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin tsserver
  id -u teamtp &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin teamtp
  mkdir -p "$TEAMTP_DIR"
  chown -R teamtp:teamtp "$TEAMTP_DIR"
  ok "Users: tsserver, teamtp"
}

# ──────────────────────────────────────────────
#  STEP 5: Deploy files
# ──────────────────────────────────────────────
deploy_files() {
  local src="${SRC_DIR:-$PWD}"

  # If TEAMTP_REPO is set, clone from git
  if [[ -n "$TEAMTP_REPO" ]]; then
    info "Cloning from ${TEAMTP_REPO}..."
    if [[ -d "${TEAMTP_DIR}/.git" ]]; then
      cd "$TEAMTP_DIR" && git pull 2>/dev/null || warn "git pull failed"
    else
      rm -rf "$TEAMTP_DIR"
      git clone "$TEAMTP_REPO" "$TEAMTP_DIR" 2>&1 || fail "git clone failed"
    fi
    chown -R teamtp:teamtp "$TEAMTP_DIR"
    ok "Git repo deployed"
    return
  fi

  # Otherwise copy local files
  if [[ ! -d "$src" ]]; then
    src="$PWD"
  fi
  info "Copying from ${src}..."
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
  ok "Files deployed"
}

# ──────────────────────────────────────────────
#  STEP 6: Generate secrets
# ──────────────────────────────────────────────
generate_secrets() {
  info "Generating secrets..."
  SECRET_QUERY_PASS=$(openssl rand -hex 16)
  SECRET_API_KEY=$(openssl rand -hex 32)
  SECRET_JWT=$(openssl rand -hex 32)
  SECRET_REFRESH=$(openssl rand -hex 32)

  # Bcrypt hash via python3 (password via stdin for safety)
  PANEL_BCRYPT_HASH=$(echo "$WIZARD_ADMIN_PASS" | python3 -c "
import sys, bcrypt
pw = sys.stdin.read().strip()
h = bcrypt.hashpw(pw.encode(), bcrypt.gensalt(rounds=12))
print(h.decode())
" 2>/dev/null) || PANEL_BCRYPT_HASH=$(openssl passwd -6 "$WIZARD_ADMIN_PASS" 2>/dev/null || echo "$WIZARD_ADMIN_PASS")

  # Scan for free ports
  info "Scanning ports..."
  local p
  for p in 9987; do ss -uln | grep -q ":${p} " || break; done
  PORT_VOICE=$p
  for p in 30033; do ss -tln | grep -q ":${p} " || break; done
  PORT_FILE=$p
  for p in 10022; do ss -tln | grep -q ":${p} " || break; done
  PORT_SSH_QUERY=$p
  for p in 10080; do ss -tln | grep -q ":${p} " || break; done
  PORT_HTTP_QUERY=$p
  for p in 3000; do ss -tln | grep -q ":${p} " || break; done
  PORT_PANEL=$p

  ok "Ports: Voice=${PORT_VOICE:-9987} Panel=${PORT_PANEL:-3000}"

  # Write .env
  cat > "${TEAMTP_DIR}/.env" <<EOF
TS6_BASE_URL=http://127.0.0.1:${PORT_HTTP_QUERY:-10080}
TS6_API_KEY=${SECRET_API_KEY}
TS6_QUERY_HOST=127.0.0.1
TS6_QUERY_PORT=${PORT_SSH_QUERY:-10022}
TS6_QUERY_PASSWORD=${SECRET_QUERY_PASS}
PANEL_PORT=${PORT_PANEL:-3000}
PANEL_BIND=127.0.0.1
PANEL_JWT_SECRET=${SECRET_JWT}
PANEL_REFRESH_SECRET=${SECRET_REFRESH}
PANEL_ADMIN_USER=${WIZARD_ADMIN_USER}
PANEL_ADMIN_HASH=${PANEL_BCRYPT_HASH}
TEAMTP_VERSION=${INSTALL_VERSION}
EOF
  chmod 600 "${TEAMTP_DIR}/.env"
  chown teamtp:teamtp "${TEAMTP_DIR}/.env"
  ok "Secrets generated"
}

# ──────────────────────────────────────────────
#  STEP 7: Install TS6 server
# ──────────────────────────────────────────────
install_ts6() {
  local dir="${TEAMTP_DIR}/server/teamspeak6"
  mkdir -p "$dir"

  if [[ -f "${dir}/${TS6_BINARY_NAME}" ]]; then
    ok "TS6 binary exists"
  else
    info "Downloading TS6 server..."
    local tmp
    tmp=$(mktemp)
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp" "$TS6_DOWNLOAD_URL" || fail "Download failed"
    tar -xzf "$tmp" -C "$dir" --strip-components=1 || fail "Extract failed"
    rm -f "$tmp"
    chmod +x "${dir}/${TS6_BINARY_NAME}"
    ok "TS6 downloaded"
  fi

  chown -R tsserver:tsserver "$dir"

  cat > "${dir}/tsserver.yaml" <<YAML
server:
  license-path: .
  accept-license: accept
  default-voice-port: ${PORT_VOICE:-9987}
  voice-ip: ["0.0.0.0", "::"]
  filetransfer-port: ${PORT_FILE:-30033}
  filetransfer-ip: "0.0.0.0"
  query:
    ssh:
      enable: 1
      port: ${PORT_SSH_QUERY:-10022}
      ip: "127.0.0.1"
    http:
      enable: 1
      port: ${PORT_HTTP_QUERY:-10080}
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

# ──────────────────────────────────────────────
#  STEP 8: Systemd services
# ──────────────────────────────────────────────
setup_systemd() {
  info "Setting up systemd services..."

  # TS6
  cat > /etc/systemd/system/teamspeak6.service <<UNIT
[Unit]
Description=TeamSpeak 6 Server
After=network.target

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

[Install]
WantedBy=multi-user.target
UNIT

  # Bots + panel
  for pair in "level||bots/level-bot" "temp||bots/temp-channel-bot" "support||bots/support-bot" "panel||panel"; do
    local name="${pair%%||*}"
    local dir="${pair##*||}"

    cat > "/etc/systemd/system/teamtp-${name}.service" <<UNIT
[Unit]
Description=TeamTP ${name^}
After=teamspeak6.service

[Service]
Type=simple
User=teamtp
Group=teamtp
    WorkingDirectory=${TEAMTP_DIR}/${dir}
ExecStart=/usr/bin/node ${TEAMTP_DIR}/${dir}/$( [[ "$name" == "panel" ]] && echo "server.js" || echo "index.js" )
EnvironmentFile=${TEAMTP_DIR}/.env
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  done

  systemctl daemon-reload

  # Start TS6
  systemctl enable teamspeak6
  systemctl start teamspeak6 || warn "TS6 start failed"
  ok "TS6 service started"

  # Wait for TS6 to be ready
  sleep 5
  local tries=0
  while ! ss -tln | grep -q ":${PORT_HTTP_QUERY:-10080} " 2>/dev/null; do
    tries=$((tries+1))
    [[ $tries -gt 10 ]] && { warn "TS6 not responding. Check: journalctl -u teamspeak6"; break; }
    sleep 2
  done

  # Capture privilege key
  PRIVILEGE_KEY=$(journalctl -u teamspeak6 --no-pager -n 100 2>/dev/null | grep -oP "token=\K\S+" | head -1 || true)
  if [[ -n "$PRIVILEGE_KEY" ]]; then
    echo "TS6_PRIVILEGE_KEY=${PRIVILEGE_KEY}" >> "${TEAMTP_DIR}/.env"
    ok "Privilege key captured"
  else
    warn "Could not capture privilege key. Check: journalctl -u teamspeak6 | grep token"
  fi

  # Start bots + panel
  for svc in teamtp-level teamtp-temp teamtp-support teamtp-panel; do
    systemctl enable "${svc}" 2>/dev/null || true
    systemctl start "${svc}" 2>/dev/null || warn "${svc} start failed"
    sleep 1
  done
  ok "All services started"
}

# ──────────────────────────────────────────────
#  STEP 9: Nginx + SSL
# ──────────────────────────────────────────────
setup_nginx() {
  [[ -z "${WIZARD_DOMAIN:-}" ]] && { ok "No domain, skipping nginx"; return; }

  local domain="$WIZARD_DOMAIN"
  cat > /etc/nginx/sites-available/teamtp <<NGX
server {
    listen 80;
    server_name ${domain} panel.${domain};
    location / { proxy_pass http://127.0.0.1:${PORT_PANEL:-3000}; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
    location /socket.io/ { proxy_pass http://127.0.0.1:${PORT_PANEL:-3000}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; }
}
NGX
  ln -sf /etc/nginx/sites-available/teamtp /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default

  if [[ "${WIZARD_SSL:-}" == "letsencrypt" ]]; then
    apt-get install -y -qq certbot python3-certbot-nginx 2>&1 | tail -1 || true
    certbot --nginx -d "$domain" -d "panel.${domain}" --non-interactive --agree-tos --email "admin@${domain}" 2>&1 | tail -1 || warn "Let's Encrypt failed"
    ok "SSL: Let's Encrypt for ${domain}"
  elif [[ "${WIZARD_SSL:-}" == "self-signed" ]]; then
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/teamtp.key \
      -out /etc/nginx/ssl/teamtp.crt \
      -subj "/CN=${domain}" 2>/dev/null

    cat > /etc/nginx/sites-available/teamtp-ssl <<NGX
server {
    listen 443 ssl;
    server_name ${domain} panel.${domain};
    ssl_certificate /etc/nginx/ssl/teamtp.crt;
    ssl_certificate_key /etc/nginx/ssl/teamtp.key;
    location / { proxy_pass http://127.0.0.1:${PORT_PANEL:-3000}; proxy_set_header Host \$host; }
}
NGX
    ln -sf /etc/nginx/sites-available/teamtp-ssl /etc/nginx/sites-enabled/
    ok "SSL: Self-signed for ${domain}"
  fi

  nginx -t 2>/dev/null && systemctl reload nginx || warn "nginx config failed"
  ok "Nginx configured"
}

# ──────────────────────────────────────────────
#  STEP 10: Firewall
# ──────────────────────────────────────────────
setup_firewall() {
  info "Configuring firewall..."
  ufw --force reset 2>/dev/null || true
  ufw default deny incoming 2>/dev/null
  ufw allow "${PORT_VOICE:-9987}/udp" 2>/dev/null || true
  ufw allow 80/tcp 2>/dev/null || true
  ufw allow 443/tcp 2>/dev/null || true
  ufw allow ssh 2>/dev/null || true
  ufw --force enable 2>/dev/null || warn "UFW not available"
  ok "Firewall configured"

  # fail2ban
  if command -v fail2ban &>/dev/null; then
    cat > /etc/fail2ban/jail.local <<F2B
[DEFAULT]
bantime = 3600; findtime = 600; maxretry = 5
[sshd]
enabled = true
F2B
    systemctl restart fail2ban 2>/dev/null || true
  fi
}

# ──────────────────────────────────────────────
#  STEP 11: Logrotate
# ──────────────────────────────────────────────
setup_logrotate() {
  mkdir -p /var/log/teamtp
  cat > /etc/logrotate.d/teamtp <<LOGROTATE
/var/log/teamtp/*.log { weekly; rotate 4; compress; missingok; notifempty; create 0640 teamtp teamtp; }
LOGROTATE
  ok "Logrotate configured"
}

# ──────────────────────────────────────────────
#  FINAL: Print summary
# ──────────────────────────────────────────────
print_summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"
  echo ""
  echo "══════════════════════════════════════"
  echo "  Installation Complete!"
  echo ""
  echo "  Connect: ${ip}:${PORT_VOICE:-9987}"
  echo "  Panel:   http://localhost:${PORT_PANEL:-3000}"
  [[ -n "${WIZARD_DOMAIN:-}" ]] && echo "  Panel:   https://panel.${WIZARD_DOMAIN}"
  echo "  Admin:   ${WIZARD_ADMIN_USER}"
  echo "  Key:     ${PRIVILEGE_KEY:0:24}..."
  echo ""
  echo "  teamtp status    — Check status"
  echo "  teamtp restart   — Restart all"
  echo "  teamtp update    — Update"
  echo "  teamtp backup    — Backup"
  echo ""
  echo "  Config: ${TEAMTP_DIR}/.env"
  echo "  Log:    ${INSTALL_LOG}"
  echo "══════════════════════════════════════"
  echo ""
  warn "SAVE THE PRIVILEGE KEY ABOVE!"
}

# ──────────────────────────────────────────────
#  SETUP LOGGING
# ──────────────────────────────────────────────
# Simple append logging (no process substitution which can hang)
touch "$INSTALL_LOG" 2>/dev/null || true
exec 2>>"$INSTALL_LOG"

# ──────────────────────────────────────────────
#  INSTALL
# ──────────────────────────────────────────────
install() {
  preflight
  wizard

  install_deps
  create_users
  deploy_files
  generate_secrets
  install_ts6
  setup_systemd
  install_cli
  setup_nginx
  setup_firewall
  setup_logrotate
  print_summary

  touch "${TEAMTP_DIR}/.installed"
  ok "Installation complete"
}

# ──────────────────────────────────────────────
#  WIPE
# ──────────────────────────────────────────────
wipe() {
  echo ""
  echo "⚠️  WIPE: This deletes EVERYTHING"
  read -rp 'Type "DELETE" to confirm: ' c
  [[ "$c" != "DELETE" ]] && { echo "Aborted."; exit 1; }

  for s in teamspeak6 teamtp-panel teamtp-level teamtp-temp teamtp-support; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/teamspeak6.service /etc/systemd/system/teamtp-*.service
  systemctl daemon-reload

  rm -f /etc/nginx/sites-available/teamtp /etc/nginx/sites-enabled/teamtp
  rm -f /etc/nginx/sites-available/teamtp-ssl /etc/nginx/sites-enabled/teamtp-ssl
  nginx -t 2>/dev/null && systemctl reload nginx || true

  rm -rf "$TEAMTP_DIR"
  rm -f /usr/local/bin/teamtp
  rm -f "$INSTALL_LOG"
  rm -rf /var/log/teamtp
  rm -f /etc/logrotate.d/teamtp

  echo "Wipe complete. Re-run install.sh to start fresh."
}

# ──────────────────────────────────────────────
#  CLI (installed to /usr/local/bin/teamtp)
# ──────────────────────────────────────────────
install_cli() {
  cat > /usr/local/bin/teamtp <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
D="/opt/teamtp"; E="${D}/.env"
load() { [[ -f "$E" ]] && { set -a; source "$E"; set +a; }; }
status() { for s in teamspeak6 teamtp-panel teamtp-level teamtp-temp teamtp-support; do local a=$(systemctl is-active "$s" 2>/dev/null || echo "inactive"); printf "  %-25s %s\n" "$s" "$a"; done; }
case "${1:-}" in
  status) load; status ;;
  restart) for s in teamspeak6 teamtp-panel teamtp-level teamtp-temp teamtp-support; do systemctl restart "$s" 2>/dev/null || true; done; echo "Restarted" ;;
  bot) local b="$2" a="$3"; case "$a" in on|off|restart) systemctl "${a}" "teamtp-${b}" 2>/dev/null || true ;; status) systemctl is-active "teamtp-${b}" 2>/dev/null ;; esac ;;
  backup) local f="${D}/backups/teamtp-$(date +%Y%m%d-%H%M%S).tar.gz"; mkdir -p "${D}/backups"; tar -czf "$f" -C "$D" .env config/ 2>/dev/null || true; echo "Backup: $f" ;;
  update) "${D}/scripts/update.sh" ;;
  wipe) "$0" "${@:2}" ;;
  health) systemctl is-active teamspeak6 >/dev/null 2>&1 && echo "OK" && exit 0 || echo "DOWN" && exit 1 ;;
  logs) journalctl -u "${2:-teamspeak6}" --no-pager -n "${3:-50}" ;;
  help|*) echo "Usage: teamtp status|restart|bot|backup|update|wipe|health|logs" ;;
esac
CLI
  chmod +x /usr/local/bin/teamtp
  ok "CLI installed"
}

# ──────────────────────────────────────────────
#  MAIN
# ──────────────────────────────────────────────
case "${1:-}" in
  --wipe|wipe) wipe ;;
  *) install ;;
esac
