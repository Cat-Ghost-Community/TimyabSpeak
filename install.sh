#!/usr/bin/env bash
set -euo pipefail

INSTALL_VERSION="1.3.0"
INSTALL_LOG="/var/log/teamtp-install.log"
TEAMTP_DIR="/opt/teamtp"
MARKER="${TEAMTP_DIR}/.installed"

TS6_URL="${TS6_URL:-https://github.com/teamspeak/teamspeak6-server/releases/download/v6.0.0-beta11/tsserver_6.0.0-beta11_linux_x86_64.tar.gz}"
TS6_BIN="tsserver"
TEAMTP_REPO="${TEAMTP_REPO:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[..]${NC} $*"; }

# ───── PORT FIND ─────
find_port() {
  local base=$1 max=$2 proto=$3
  for off in $(seq 0 $max); do
    local p=$((base + off))
    if [[ "$proto" == "udp" ]]; then
      ss -uln 2>/dev/null | grep -q ":$p " || { echo "$p"; return 0; }
    else
      ss -tln 2>/dev/null | grep -q ":$p " || { echo "$p"; return 0; }
    fi
  done
  echo "$base"
}

# ───── STEP 1: PRE-FLIGHT ─────
preflight() {
  [[ $EUID -eq 0 ]] || fail "Run as root: sudo bash install.sh"
  echo "──────────────────────────────────────"
  echo " TimyabSpeak v${INSTALL_VERSION} — TeamSpeak 6 Installer"
  echo "──────────────────────────────────────"
  grep -qi "ubuntu 22.04\|ubuntu 24.04\|debian 12" /etc/os-release 2>/dev/null && \
    ok "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')" || \
    warn "Recommended: Ubuntu 22.04+ / Debian 12+"
  info "Arch: $(uname -m)"
  local mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}') || mem=0
  [[ $mem -ge 512 ]] && ok "RAM: ${mem}MB" || warn "RAM: ${mem}MB (512MB min)"
  local free=$(df / --output=avail 2>/dev/null | tail -1) || free=0
  [[ $free -ge 2097152 ]] || fail "Need 2GB+ free (have $((free/1024))MB)"
  [[ -f "$MARKER" ]] && warn "Existing install at ${TEAMTP_DIR}. Run 'teamtp update' to update."
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
  if [[ "${has_domain:-2}" == "1" ]]; then
    read -rp "  Domain name: " WIZARD_DOMAIN
    echo "  SSL:"
    echo "    1) Let's Encrypt (auto, recommended)"
    echo "    2) Self-signed certificate"
    echo "    3) No SSL"
    read -rp "    Choose [1]: " ssl
    case "${ssl:-1}" in
      2) WIZARD_SSL="self-signed" ;;
      3) WIZARD_SSL="none" ;;
      *) WIZARD_SSL="letsencrypt" ;;
    esac
  else
    WIZARD_DOMAIN=""
    echo "  SSL:"
    echo "    1) Self-signed certificate"
    echo "    2) No SSL"
    read -rp "    Choose [1]: " ssl
    case "${ssl:-1}" in
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
  read -rp "Max slots [64]: " tmp
  WIZARD_SLOTS="${tmp:-64}"
  read -rp "Welcome message [Welcome!]: " tmp
  WIZARD_WELCOME="${tmp:-Welcome!}"
  ok "Wizard complete"
}

# ───── STEP 3: SYSTEM DEPS ─────
install_deps() {
  info "Installing system packages..."
  apt-get update -qq || warn "apt update failed"
  apt-get install -y -qq curl wget nginx openssl ufw fail2ban logrotate \
    unattended-upgrades 2>&1 | tail -1 || warn "Some packages failed"
  if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 20 ]]; then
    info "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs 2>&1 | tail -1
  fi
  ok "Node.js $(node -v)"
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
      cd "$TEAMTP_DIR" && git pull 2>/dev/null || warn "git pull failed"
    else
      rm -rf "$TEAMTP_DIR"
      git clone "$TEAMTP_REPO" "$TEAMTP_DIR" 2>&1 || fail "git clone failed"
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
    [[ -d "${src}/${subdir}" ]] && { mkdir -p "${TEAMTP_DIR}/${subdir}"; cp -r "${src}/${subdir}/." "${TEAMTP_DIR}/${subdir}/"; }
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
  # Write package.json files and install
  for pair in "bots/level-bot||better-sqlite3" "bots/temp-channel-bot||better-sqlite3" "bots/support-bot||better-sqlite3" "panel||express,socket.io,jsonwebtoken,bcrypt,helmet,better-sqlite3"; do
    local dir="${TEAMTP_DIR}/${pair%%||*}"
    local deps="${pair##*||}"
    mkdir -p "$dir"
    if [[ ! -f "${dir}/package.json" ]]; then
      local json='{"name":"teamtp-'$(basename "$dir")'","version":"1.0.0","private":true,"main":"index.js","dependencies":{'
      local first=true; local IFS=','
      for dep in $deps; do
        $first && first=false || json+=','
        json+="\"${dep%%@*}\":\"${dep#*@}\""
      done
      json+='}}'
      echo "$json" > "${dir}/package.json"
    fi
    (cd "$dir" && npm install --silent 2>&1 | tail -1) || warn "npm install failed in ${dir}"
  done
  ok "npm dependencies installed"
}

# ───── STEP 7: SECRETS + PORTS ─────
generate_secrets() {
  info "Generating secrets..."
  SECRET_QUERY_PASS=$(openssl rand -hex 16)
  SECRET_API_KEY=$(openssl rand -hex 32)
  SECRET_JWT=$(openssl rand -hex 32)
  SECRET_REFRESH=$(openssl rand -hex 32)

  PANEL_BCRYPT_HASH=$(echo "$WIZARD_ADMIN_PASS" | python3 -c "
import sys, bcrypt
print(bcrypt.hashpw(sys.stdin.read().strip().encode(), bcrypt.gensalt(rounds=12)).decode())
" 2>/dev/null) || PANEL_BCRYPT_HASH=$(openssl passwd -6 "$WIZARD_ADMIN_PASS" 2>/dev/null || echo "$WIZARD_ADMIN_PASS")

  info "Scanning ports..."
  PORT_VOICE=$(find_port 9987 20 udp)
  PORT_FILE=$(find_port 30033 10 tcp)
  PORT_SSH_QUERY=$(find_port 10022 10 tcp)
  PORT_HTTP_QUERY=$(find_port 10080 10 tcp)
  PORT_PANEL=$(find_port 3000 10 tcp)
  ok "Ports: Voice=${PORT_VOICE} Panel=${PORT_PANEL}"

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
PORT_VOICE=${PORT_VOICE}
PORT_FILE=${PORT_FILE}
PORT_SSH_QUERY=${PORT_SSH_QUERY}
PORT_HTTP_QUERY=${PORT_HTTP_QUERY}
PORT_PANEL=${PORT_PANEL}
EOF
  chmod 600 "${TEAMTP_DIR}/.env"
  chown teamtp:teamtp "${TEAMTP_DIR}/.env"
  ok "Secrets generated"
}

# ───── STEP 8: TS6 SERVER ─────
install_ts6() {
  local dir="${TEAMTP_DIR}/server/teamspeak6"
  mkdir -p "$dir"
  if [[ ! -f "${dir}/${TS6_BIN}" ]]; then
    info "Downloading TS6..."
    local tmp=$(mktemp)
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp" "$TS6_URL" || fail "Download failed"
    tar -xzf "$tmp" -C "$dir" --strip-components=1 || fail "Extract failed"
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
  voice-ip: ["0.0.0.0","::"]
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
  cat > /etc/systemd/system/teamspeak6.service <<UNIT
[Unit]
Description=TeamSpeak 6 Server
After=network.target
[Service]
Type=simple
User=tsserver
Group=tsserver
WorkingDirectory=${TEAMTP_DIR}/server/teamspeak6
ExecStart=${TEAMTP_DIR}/server/teamspeak6/${TS6_BIN} --config-file ${TEAMTP_DIR}/server/teamspeak6/tsserver.yaml
ExecStop=/bin/kill -SIGTERM \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT

  for pair in "level||bots/level-bot" "temp||bots/temp-channel-bot" "support||bots/support-bot" "panel||panel"; do
    local name="${pair%%||*}"
    local dir="${pair##*||}"
    local exec_path="${TEAMTP_DIR}/${dir}"
    [[ "$name" == "panel" ]] && exec_path="${TEAMTP_DIR}/${dir}/server.js" || exec_path="${TEAMTP_DIR}/${dir}/index.js"
    cat > "/etc/systemd/system/teamtp-${name}.service" <<UNIT
[Unit]
Description=TeamTP ${name^}
After=teamspeak6.service
[Service]
Type=simple
User=teamtp
Group=teamtp
WorkingDirectory=${TEAMTP_DIR}/${dir}
ExecStart=/usr/bin/node ${exec_path}
EnvironmentFile=${TEAMTP_DIR}/.env
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
  done
  systemctl daemon-reload
  systemctl enable teamspeak6
  systemctl start teamspeak6 || warn "TS6 start failed"
  ok "TS6 started"

  sleep 5
  local n=0
  while ! ss -tln 2>/dev/null | grep -q ":${PORT_HTTP_QUERY} "; do
    n=$((n+1)); [[ $n -gt 10 ]] && { warn "TS6 not responding. Check: journalctl -u teamspeak6"; break; }
    sleep 2
  done

  PRIVILEGE_KEY=$(journalctl -u teamspeak6 --no-pager -n 100 2>/dev/null | grep -oP "token=\K\S+" | head -1 || true)
  if [[ -n "$PRIVILEGE_KEY" ]]; then
    echo "TS6_PRIVILEGE_KEY=${PRIVILEGE_KEY}" >> "${TEAMTP_DIR}/.env"
    ok "Privilege key captured"
  else
    warn "Could not capture privilege key. Run: journalctl -u teamspeak6 | grep token"
  fi

  for svc in teamtp-level teamtp-temp teamtp-support teamtp-panel; do
    systemctl enable "$svc" 2>/dev/null || true
    systemctl start "$svc" 2>/dev/null || warn "$svc start failed"
    sleep 1
  done
  ok "All services started"
}

# ───── STEP 10: CLI ─────
install_cli() {
  cat > /usr/local/bin/teamtp <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
D="/opt/teamtp"; E="${D}/.env"
load_env() { [[ -f "$E" ]] && { set -a; source "$E"; set +a; } 2>/dev/null || true; }
case "${1:-}" in
  status)
    load_env
    for s in teamspeak6 teamtp-panel teamtp-level teamtp-temp teamtp-support; do
      local a=$(systemctl is-active "$s" 2>/dev/null || echo "inactive")
      printf "  %-25s %s\n" "$s" "$a"
    done
    echo "  Version: $(grep TEAMTP_VERSION "$E" 2>/dev/null | cut -d= -f2 || echo '?')"
    ;;
  restart)
    for s in teamspeak6 teamtp-panel teamtp-level teamtp-temp teamtp-support; do
      systemctl restart "$s" 2>/dev/null || true
    done; echo "Restarted" ;;
  bot)
    local b="$2" a="$3"
    case "$a" in
      on|off|restart) systemctl "$a" "teamtp-${b}" 2>/dev/null || echo "Bot not found" ;;
      status) local s=$(systemctl is-active "teamtp-${b}" 2>/dev/null || echo "inactive"); echo "${b}: $s" ;;
      *) echo "Usage: teamtp bot <level|temp|support> <on|off|restart|status>" ;;
    esac ;;
  backup)
    local f="${D}/backups/teamtp-$(date +%Y%m%d-%H%M%S).tar.gz"
    mkdir -p "${D}/backups"
    tar -czf "$f" -C "$D" .env config/ 2>/dev/null || true
    for db in bots/level-bot/data.sqlite bots/temp-channel-bot/temp-channels.sqlite bots/support-bot/tickets.sqlite; do
      [[ -f "${D}/${db}" ]] && tar -rf "$f" -C "$D" "$db" 2>/dev/null || true
    done
    echo "Backup: $f ($(du -h "$f" | cut -f1))"
    find "${D}/backups" -name "teamtp-*.tar.gz" -mtime +30 -delete 2>/dev/null || true ;;
  update)
    echo "Updating..."
    [[ -d "${D}/.git" ]] && (cd "$D" && git pull 2>&1) || echo "Not a git repo, skipping pull"
    for d in panel bots/level-bot bots/temp-channel-bot bots/support-bot; do
      [[ -f "${D}/${d}/package.json" ]] && (cd "${D}/${d}" && npm ci --silent 2>/dev/null || npm install --silent 2>/dev/null) || true
    done
    systemctl daemon-reload
    for s in teamtp-panel teamtp-level teamtp-temp teamtp-support; do systemctl restart "$s" 2>/dev/null || true; done
    echo "Update complete" ;;
  wipe)
    echo "⚠️  DELETE everything?"
    read -rp 'Type "DELETE": ' c; [[ "$c" != "DELETE" ]] && { echo "Aborted."; exit 1; }
    for s in teamspeak6 teamtp-panel teamtp-level teamtp-temp teamtp-support; do systemctl stop "$s" 2>/dev/null || true; done
    rm -f /etc/systemd/system/teamspeak6.service /etc/systemd/system/teamtp-*.service
    systemctl daemon-reload
    rm -f /etc/nginx/sites-available/teamtp* /etc/nginx/sites-enabled/teamtp*
    nginx -t 2>/dev/null && systemctl reload nginx || true
    rm -rf "$D" /usr/local/bin/teamtp /var/log/teamtp*
    echo "Wipe complete" ;;
  health)
    systemctl is-active teamspeak6 >/dev/null 2>&1 && echo "OK" && exit 0 || { echo "DOWN"; exit 1; } ;;
  logs)
    journalctl -u "${2:-teamspeak6}" --no-pager -n "${3:-50}" ;;
  *) echo "Usage: teamtp status|restart|bot <l|t|s> <a>|backup|update|wipe|health|logs" ;;
esac
CLI
  chmod +x /usr/local/bin/teamtp
  ok "CLI installed"
}

# ───── STEP 11: NGINX + SSL ─────
setup_nginx() {
  [[ -z "${WIZARD_DOMAIN:-}" ]] && { ok "No domain, skipping nginx"; return; }
  local domain="$WIZARD_DOMAIN"
  cat > /etc/nginx/sites-available/teamtp <<NGX
server {
    listen 80;
    server_name ${domain} panel.${domain};
    location / {
        proxy_pass http://127.0.0.1:${PORT_PANEL};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location /socket.io/ {
        proxy_pass http://127.0.0.1:${PORT_PANEL};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGX
  ln -sf /etc/nginx/sites-available/teamtp /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default

  if [[ "${WIZARD_SSL:-}" == "letsencrypt" ]]; then
    apt-get install -y -qq certbot python3-certbot-nginx 2>&1 | tail -1 || true
    certbot --nginx -d "$domain" -d "panel.${domain}" --non-interactive --agree-tos --email "admin@${domain}" 2>&1 | tail -1 || warn "Let's Encrypt failed"
    ok "LE SSL for ${domain}"
  elif [[ "${WIZARD_SSL:-}" == "self-signed" ]]; then
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/nginx/ssl/teamtp.key -out /etc/nginx/ssl/teamtp.crt -subj "/CN=${domain}" 2>/dev/null
    cat > /etc/nginx/sites-available/teamtp-ssl <<NGX
server {
    listen 443 ssl http2;
    server_name ${domain} panel.${domain};
    ssl_certificate /etc/nginx/ssl/teamtp.crt;
    ssl_certificate_key /etc/nginx/ssl/teamtp.key;
    location / { proxy_pass http://127.0.0.1:${PORT_PANEL}; proxy_set_header Host \$host; }
}
NGX
    ln -sf /etc/nginx/sites-available/teamtp-ssl /etc/nginx/sites-enabled/
    ok "Self-signed SSL for ${domain}"
  fi
  nginx -t 2>/dev/null && systemctl reload nginx || warn "nginx config test failed"
  ok "Nginx configured"
}

# ───── STEP 12: FIREWALL ─────
setup_firewall() {
  info "Configuring firewall..."
  ufw --force reset 2>/dev/null || true
  ufw default deny incoming 2>/dev/null || true
  ufw allow "${PORT_VOICE}/udp" 2>/dev/null || true
  ufw allow 80/tcp 2>/dev/null || true
  ufw allow 443/tcp 2>/dev/null || true
  ufw allow ssh 2>/dev/null || true
  ufw --force enable 2>/dev/null || warn "UFW not available"
  ok "Firewall: voice/80/443/ssh"

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
  echo "$WIZARD_WELCOME" > "${TEAMTP_DIR}/config/welcome.txt"
  chown teamtp:teamtp "${TEAMTP_DIR}/config/welcome.txt"
}

# ───── SUMMARY ─────
print_summary() {
  local ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"
  echo ""
  echo "══════════════════════════════════════"
  echo "  Installation Complete!"
  echo ""
  echo "  Connect: ${ip}:${PORT_VOICE}"
  [[ -n "${WIZARD_DOMAIN:-}" ]] && echo "  Panel:   https://panel.${WIZARD_DOMAIN}"
  echo "  Panel:   http://localhost:${PORT_PANEL}"
  echo "  Admin:   ${WIZARD_ADMIN_USER}"
  echo "  Key:     ${PRIVILEGE_KEY:0:24}..."
  echo ""
  warn "SAVE THE PRIVILEGE KEY ABOVE — only shown once!"
  echo ""
  echo "  Commands: teamtp status|restart|bot|backup|update|wipe"
  echo "  Log:      ${INSTALL_LOG}"
  echo "══════════════════════════════════════"
}

# ───── WIPE ─────
wipe() {
  exec </dev/tty 2>/dev/null || true
  echo ""; echo "⚠️  WIPE: deletes ALL files, DBs, config"
  read -rp 'Type "DELETE" to confirm: ' c
  [[ "$c" != "DELETE" ]] && { echo "Aborted."; exit 1; }
  for s in teamspeak6 teamtp-panel teamtp-level teamtp-temp teamtp-support; do
    systemctl stop "$s" 2>/dev/null || true; systemctl disable "$s" 2>/dev/null || true
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
    generate_secrets
    install_npm
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
