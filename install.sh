#!/usr/bin/env bash
# TimyabSpeak — TeamSpeak 6 One-Command Installer
# Version: 2.0.0
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

DEBUG="${DEBUG:-false}"
RESUME="${RESUME:-false}"
INSTALL_VERSION="2.0.0"
INSTALL_LOG="/var/log/teamtp-install.log"
TEAMTP_DIR="/opt/teamtp"
MARKER="${TEAMTP_DIR}/.installed"
TS6_URL="${TS6_URL:-https://github.com/teamspeak/teamspeak6-server/releases/download/v6.0.0-beta11/teamspeak6-server-linux-amd64.tar.xz}"
TEAMTP_REPO="${TEAMTP_REPO:-}"
SRC_DIR="${SRC_DIR:-$PWD}"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

# ─── Phase tracking ───
PHASE_TOTAL=14
_CURRENT_PHASE=0
_last_cmd=""
_last_ln=""

# ─── Colors ───
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
  BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ─── Unicode symbols ───
if [[ "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" =~ \.UTF[-]?8 ]]; then
  CHK='✓'; CRS='✗'; WRN='⚠'; INF='ℹ'; DOT='•'; ARW='→'
else
  CHK='+'; CRS='x'; WRN='!'; INF='i'; DOT='*'; ARW='>'
fi

# ─── Spinner frames ───
if [[ "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" =~ \.UTF[-]?8 ]]; then
  SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  SPIN_FRAMES=('|' '/' '-' '\')
fi

# ─── Utility functions ───
_log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$INSTALL_LOG"; }
ok()    { echo -e "  ${GREEN}${CHK}${NC} $*"; _log "[OK] $*"; }
warn()  { echo -e "  ${YELLOW}${WRN}${NC} $*"; _log "[WARN] $*"; }
info()  { echo -e "  ${CYAN}${INF}${NC} $*"; _log "[INFO] $*"; }
fail()  {
  local msg="$*"
  printf "\n  ${RED}%s %s${NC}\n" "${CRS}" "$msg" >/dev/tty 2>/dev/null
  printf "  ${DIM}%s Full log: %s${NC}\n" "${ARW}" "$INSTALL_LOG" >/dev/tty 2>/dev/null
  _log "[FAIL] $msg"
  cleanup_on_failure
  exit 1
}
step() {
  local n="$1" total="$2" label="$3"
  echo ""
  printf "${BOLD}${CYAN}▸${NC} ${BOLD}[%s/%s]${NC} %s\n" "$n" "$total" "$label"
  _log "── Phase ${n}: ${label} ──"
}

# ─── Spinner ───
_spin() {
  local msg="$1" pid="$2" start_time="$SECONDS" i=0 len
  len=${#SPIN_FRAMES[@]}
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s %s (%ds)" "${SPIN_FRAMES[i]}" "$msg" $((SECONDS - start_time))
    i=$(( (i + 1) % len ))
    sleep 0.1
  done
  printf "\r\033[K"
}

_run_spin() {
  local msg="$1" tmp ec start_time cmd_pid
  shift
  start_time="$SECONDS"
  tmp="$(mktemp)"
  [[ "$DRY_RUN" == "true" ]] && { info "(dry-run) $msg: $*"; rm -f "$tmp"; return 0; }
  _log "RUN: $*"
  "$@" > "$tmp" 2>&1 &
  cmd_pid=$!
  _spin "$msg" "$cmd_pid"
  wait "$cmd_pid"
  ec=$?
  cat "$tmp" >> "$INSTALL_LOG" 2>/dev/null
  if [[ $ec -eq 0 ]]; then
    printf "  ${GREEN}%s${NC} %s (%ds)\n" "${CHK}" "$msg" $((SECONDS - start_time))
    rm -f "$tmp"
    return 0
  fi
  printf "  ${RED}%s${NC} %s (failed after %ds)\n" "${CRS}" "$msg" $((SECONDS - start_time))
  if [[ -s "$tmp" ]]; then
    tail -5 "$tmp" | while IFS= read -r line; do printf "    ${DIM}%s${NC}\n" "$line"; done
  fi
  rm -f "$tmp"
  return $ec
}

# ─── Dry-run aware command execution ───
_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "(dry-run) $*"
    return 0
  fi
  _log "CMD: $*"
  "$@"
}

# ─── Phase helpers ───
_phase_enter() { _CURRENT_PHASE="$1"; }
_phase_done()  { touch "${TEAMTP_DIR}/.phase-${_CURRENT_PHASE}" 2>/dev/null || true; }
_phase_skip()  { [[ -f "${TEAMTP_DIR}/.phase-${1}" ]]; }

# ─── Cleanup on failure ───
cleanup_on_failure() {
  _log "Cleanup: phase ${_CURRENT_PHASE} failed"
  case "${_CURRENT_PHASE}" in
    1|2) ;;  # preflight/wizard: nothing to clean
    3) ;;    # deps: leave packages installed
    4) userdel tsserver 2>/dev/null || true; userdel teamtp 2>/dev/null || true ;;
    5|6) rm -rf "$TEAMTP_DIR" ;;
    7) rm -f "${TEAMTP_DIR}/.env" ;;
    8) rm -rf "${TEAMTP_DIR}/server/teamspeak6" ;;
    9)
      for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
      done
      rm -f /etc/systemd/system/teamspeak6.service /etc/systemd/system/teamtp-*.service
      systemctl daemon-reload 2>/dev/null || true
      ;;
    10) rm -f /usr/local/bin/teamtp ;;
    11)
      rm -f /etc/nginx/sites-available/teamtp /etc/nginx/sites-available/teamtp-ssl
      rm -f /etc/nginx/sites-enabled/teamtp /etc/nginx/sites-enabled/teamtp-ssl
      nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
      ;;
    12|13|14) ;; # firewall/logrotate/summary: nothing to clean
    *)
      for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
      done
      rm -f /etc/systemd/system/teamspeak6.service /etc/systemd/system/teamtp-*.service
      systemctl daemon-reload 2>/dev/null || true
      rm -f /etc/nginx/sites-available/teamtp /etc/nginx/sites-available/teamtp-ssl
      rm -f /etc/nginx/sites-enabled/teamtp /etc/nginx/sites-enabled/teamtp-ssl
      rm -rf "$TEAMTP_DIR" /usr/local/bin/teamtp
      userdel tsserver 2>/dev/null || true; userdel teamtp 2>/dev/null || true
      ;;
  esac
  for p in $(seq "${_CURRENT_PHASE}" "$PHASE_TOTAL" 2>/dev/null); do
    rm -f "${TEAMTP_DIR}/.phase-${p}" 2>/dev/null || true
  done
  echo ""
  warn "Phase ${_CURRENT_PHASE} failed. Fix the issue above and re-run with --resume to skip completed phases."
}

# ─── Traps ───
trap '_last_cmd=$BASH_COMMAND; _last_ln=$LINENO' DEBUG

trap '
  ec=$?
  if [[ $ec -ne 0 && $ec -ne 130 && $ec -ne 143 ]]; then
    printf "\n  ${RED}%s Fatal at line %s (exit %s): %s${NC}\n" "${CRS}" "$_last_ln" "$ec" "$_last_cmd" >/dev/tty 2>/dev/null
    printf "  ${DIM}%s Log: %s${NC}\n" "${ARW}" "$INSTALL_LOG" >/dev/tty 2>/dev/null
    printf "  ${DIM}%s Re-run with DEBUG=true for full trace.${NC}\n" "${ARW}" >/dev/tty 2>/dev/null
  fi
' EXIT

# ─── Signal handlers ───
_on_signal() {
  echo ""
  warn "Installation interrupted (signal $1)."
  if [[ "$RESUME" == "true" ]]; then
    info "Phase markers preserved. Re-run with --resume to continue."
  fi
  exit $(( 128 + $1 ))
}

trap '_on_signal INT' INT
trap '_on_signal TERM' TERM

# ══════════════════════════════════════════════════════════════════
# PHASE 0: Argument Parsing & Header
# ══════════════════════════════════════════════════════════════════

show_header() {
  echo ""
  echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "  ${BOLD}${GREEN}║${NC}                                              ${BOLD}${GREEN}║${NC}"
  echo -e "  ${BOLD}${GREEN}║${NC}   ${BOLD}TimyabSpeak — TeamSpeak 6 Installer${NC}       ${BOLD}${GREEN}║${NC}"
  echo -e "  ${BOLD}${GREEN}║${NC}   ${DIM}Version ${INSTALL_VERSION}${NC}                              ${BOLD}${GREEN}║${NC}"
  echo -e "  ${BOLD}${GREEN}║${NC}                                              ${BOLD}${GREEN}║${NC}"
  echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
}

show_help() {
  show_header
  echo "Usage: sudo bash install.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --dry-run          Preview installation without making changes"
  echo "  --non-interactive  Skip wizard, use environment variables"
  echo "  --force            Overwrite existing installation"
  echo "  --resume           Skip already-completed phases (retry after failure)"
  echo "  --debug            Full execution trace (set -x) plus terminal stderr"
  echo "  --wipe             Remove all traces of a previous installation"
  echo "  --help             Show this help"
  echo "  --version          Show version"
  echo ""
  echo "Environment variables (for --non-interactive):"
  echo "  TEAMTP_DOMAIN         Domain name (empty for IP-only)"
  echo "  TEAMTP_SSL            letsencrypt | self-signed | none"
  echo "  TEAMTP_SERVER_NAME    Server display name"
  echo "  TEAMTP_ADMIN_USER     Admin username"
  echo "  TEAMTP_ADMIN_PASS     Admin password (min 8 chars)"
  echo "  TEAMTP_SLOTS          Max client slots"
  echo "  TEAMTP_WELCOME        Welcome message"
  echo "  TS6_URL               Custom TS6 download URL"
  echo "  TEAMTP_REPO           Custom git repo for deployment"
  echo ""
  echo "Examples:"
  echo "  sudo bash install.sh"
  echo "  sudo bash install.sh --dry-run"
  echo "  TEAMTP_DOMAIN=myserver.com TEAMTP_ADMIN_PASS=secret sudo -E bash install.sh --non-interactive"
  echo "  TS6_URL=https://mirror.example.com/ts6.tar.gz sudo -E bash install.sh"
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN="true" ;;
      --force) FORCE="true" ;;
      --non-interactive) NON_INTERACTIVE="true" ;;
      --resume) RESUME="true" ;;
      --debug) DEBUG="true" ;;
      --wipe|wipe) do_wipe; exit 0 ;;
      --help|-h|help) show_help; exit 0 ;;
      --version|-v) echo "TimyabSpeak Installer v${INSTALL_VERSION}"; exit 0 ;;
      *) fail "Unknown option: $arg. Use --help for usage." ;;
    esac
  done
}

# ══════════════════════════════════════════════════════════════════
# PHASE 1: Pre-flight Checks
# ══════════════════════════════════════════════════════════════════

preflight() {
  step 1 $PHASE_TOTAL "Pre-flight checks"

  # Root
  [[ $EUID -eq 0 ]] || fail "Run as root: sudo bash install.sh"

  # OS detection
  local os_name os_version os_id
  if [[ -f /etc/os-release ]]; then
    os_name=$(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo "Unknown")
    os_id=$(grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null | tr -d '"' || echo "")
    os_version=$(grep -oP 'VERSION_ID="?\K[0-9]+' /etc/os-release 2>/dev/null || echo "0")
  else
    os_name="Unknown"; os_id="unknown"; os_version="0"
  fi
  if [[ "$os_id" =~ ^(ubuntu|debian)$ ]] && [[ "$os_version" -ge 22 || ( "$os_id" == "debian" && "$os_version" -ge 12 ) ]]; then
    ok "OS: ${os_name}"
  else
    warn "OS: ${os_name} — recommended: Ubuntu 22.04+ / Debian 12+"
  fi

  # Architecture
  local arch
  arch=$(uname -m 2>/dev/null || echo "unknown")
  if [[ "$arch" == "x86_64" ]]; then
    ok "Architecture: x86_64"
  elif [[ "$arch" == "aarch64" ]]; then
    ok "Architecture: ARM64"
    warn "ARM64 may need libatomic1. Install manually if TS6 fails to start."
  else
    fail "Unsupported architecture: ${arch}. Only x86_64 and aarch64 are supported."
  fi

  # glibc version
  local glibc_ver
  glibc_ver=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $NF}' || true)
  if [[ -n "$glibc_ver" && "$glibc_ver" != "0" ]]; then
    if awk "BEGIN{exit !($glibc_ver >= 2.32)}"; then
      ok "glibc: ${glibc_ver} (>= 2.32 required)"
    else
      fail "glibc ${glibc_ver} is too old. TeamSpeak 6 requires glibc >= 2.32. Upgrade to Ubuntu 22.04+ / Debian 12+."
    fi
  else
    warn "Could not determine glibc version. TeamSpeak 6 requires glibc >= 2.32."
  fi

  # RAM
  local mem
  if [[ -f /proc/meminfo ]]; then
    mem=$(awk '/^MemTotal:/{printf "%d", int($2/1024)}' /proc/meminfo 2>/dev/null) || mem=0
  else
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}') || mem=0
  fi
  if [[ ${mem:-0} -ge 512 ]]; then
    ok "RAM: ${mem}MB"
  else
    fail "RAM: ${mem}MB (512MB minimum required)"
  fi

  # Disk space
  local disk_free
  disk_free=$(df /opt --output=avail 2>/dev/null | awk 'NR==2{print $1}' || true)
  [[ -z "$disk_free" || "$disk_free" == "0" ]] && disk_free=$(df / --output=avail 2>/dev/null | awk 'NR==2{print $1}' || true)
  [[ -z "$disk_free" ]] && disk_free=0
  if [[ ${disk_free:-0} -ge 2097152 ]]; then
    ok "Disk: $((disk_free/1024/1024))GB free on /opt"
  else
    fail "Disk: $((disk_free/1024))MB free — need at least 2GB on /opt"
  fi

  # Existing installation
  if [[ -f "$MARKER" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      warn "Existing installation found at ${TEAMTP_DIR} (--force: will overwrite)"
    else
      fail "Existing installation found at ${TEAMTP_DIR}. Use --force to overwrite, or 'teamtp wipe' to remove first."
    fi
  fi

  # Writable
  if [[ ! -w "/opt" ]] && [[ "$DRY_RUN" != "true" ]]; then
    fail "Cannot write to /opt. Check permissions."
  fi
}

# ══════════════════════════════════════════════════════════════════
# PHASE 2: Wizard
# ══════════════════════════════════════════════════════════════════

wizard() {
  step 2 $PHASE_TOTAL "Server configuration"

  # Check if all env vars are provided for non-interactive mode
  local env_mode=false
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    env_mode=true
    info "Non-interactive mode — loading from environment"
  elif [[ -n "${TEAMTP_DOMAIN:-}" || -n "${TEAMTP_ADMIN_USER:-}" || -n "${TEAMTP_SLOTS:-}" ]]; then
    # At least one env var is set — check if all required are set
    if [[ -n "${TEAMTP_ADMIN_PASS:-}" && -n "${TEAMTP_SLOTS:-}" && -n "${TEAMTP_SERVER_NAME:-}" ]]; then
      env_mode=true
      info "Configuration detected in environment — skipping wizard"
    fi
  fi

  if $env_mode; then
    WIZARD_DOMAIN="${TEAMTP_DOMAIN:-}"
    WIZARD_SSL="${TEAMTP_SSL:-none}"
    WIZARD_SERVER_NAME="${TEAMTP_SERVER_NAME:-My Community}"
    WIZARD_ADMIN_USER="${TEAMTP_ADMIN_USER:-admin}"
    WIZARD_ADMIN_PASS="${TEAMTP_ADMIN_PASS:-teamtp123}"
    WIZARD_SLOTS="${TEAMTP_SLOTS:-64}"
    WIZARD_WELCOME="${TEAMTP_WELCOME:-Welcome!}"
  else
    exec </dev/tty || true
    echo ""
    printf "  ${BOLD}Server Configuration${NC}\n"
    printf "  ${DIM}Press Enter to accept [defaults], Ctrl+C to cancel${NC}\n"
    echo ""

    # Domain
    local ans
    printf "  Domain name (leave empty for IP-only): " >/dev/tty
    read -r ans </dev/tty || true
    WIZARD_DOMAIN="${ans// /}"

    # SSL
    if [[ -n "$WIZARD_DOMAIN" ]]; then
      printf "  ${ARW} %s\n" "$WIZARD_DOMAIN"
      if _yn "  Enable Let's Encrypt SSL?"; then
        WIZARD_SSL="letsencrypt"
      elif _yn "  Use self-signed certificate?"; then
        WIZARD_SSL="self-signed"
      else
        WIZARD_SSL="none"
      fi
    else
      WIZARD_DOMAIN=""
      printf "  ${ARW} Using IP address\n"
      if _yn "  Enable self-signed HTTPS?"; then
        WIZARD_SSL="self-signed"
      else
        WIZARD_SSL="none"
      fi
    fi
    echo ""

    # Server name
    printf "  Server name [My Community]: " >/dev/tty
    read -r ans </dev/tty || true
    WIZARD_SERVER_NAME="${ans:-My Community}"

    # Admin user
    printf "  Admin username [admin]: " >/dev/tty
    read -r ans </dev/tty || true
    WIZARD_ADMIN_USER="${ans:-admin}"

    # Admin password
    while true; do
      printf "  Admin password (min 8 chars): " >/dev/tty
      read -rs ans </dev/tty || { ans=""; break; }; printf "\n" >/dev/tty
      if [[ ${#ans} -ge 8 ]]; then
        WIZARD_ADMIN_PASS="$ans"
        break
      fi
      printf "  ${YELLOW}%s${NC} Too short, minimum 8 characters.\n" "${WRN}"
    done
    [[ -z "$WIZARD_ADMIN_PASS" ]] && WIZARD_ADMIN_PASS="teamtp123"

    # Slots
    while true; do
      printf "  Max slots [64]: " >/dev/tty
      read -r ans </dev/tty || { ans="64"; break; }
      WIZARD_SLOTS="${ans:-64}"
      if [[ "$WIZARD_SLOTS" =~ ^[0-9]+$ ]] && [[ "$WIZARD_SLOTS" -ge 1 ]]; then
        break
      fi
      printf "  ${YELLOW}%s${NC} Enter a number (1 or higher).\n" "${WRN}"
    done

    # Welcome
    printf "  Welcome message [Welcome!]: " >/dev/tty
    read -r ans </dev/tty || true
    WIZARD_WELCOME="${ans:-Welcome!}"

    echo ""
    ok "Configuration complete"
  fi

  # Validate
  if [[ -n "$WIZARD_DOMAIN" ]] && [[ ! "$WIZARD_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
    warn "Domain '${WIZARD_DOMAIN}' does not look like a valid domain name"
  fi
  if [[ ${#WIZARD_ADMIN_PASS} -lt 8 ]]; then
    fail "Admin password must be at least 8 characters"
  fi
  if [[ ! "$WIZARD_SLOTS" =~ ^[0-9]+$ ]] || [[ "$WIZARD_SLOTS" -lt 1 ]]; then
    fail "Slots must be a positive number"
  fi
}

_yn() {
  local prompt="$1" ans
  printf "%s [Y/n]: " "$prompt" >/dev/tty
  read -r ans </dev/tty 2>/dev/null || true
  ans="${ans,,}"
  [[ -z "$ans" || "$ans" == y* || "$ans" == yes ]]
}

# ══════════════════════════════════════════════════════════════════
# PHASE 3: System Dependencies
# ══════════════════════════════════════════════════════════════════

install_deps() {
  step 3 $PHASE_TOTAL "System dependencies"

  # apt update
  _run_spin "Updating package lists" apt-get update -qq || warn "apt update failed, continuing"

  # System packages
  local pkgs=(curl wget nginx openssl ufw fail2ban logrotate iproute2 procps build-essential python3 libsqlite3-dev)
  _run_spin "Installing system packages" apt-get install -y -qq "${pkgs[@]}" || warn "Some packages failed, continuing"

  # Node.js 20
  local node_ok=false
  if command -v node &>/dev/null; then
    local node_ver
    node_ver=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
    if [[ "$node_ver" =~ ^[0-9]+$ ]] && [[ "$node_ver" -ge 20 ]]; then
      ok "Node.js $(node -v) (already installed)"
      node_ok=true
    fi
  fi

  if ! $node_ok; then
    _run_spin "Installing Node.js 20.x" curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || true
    if _run_spin "Installing Node.js 20.x" apt-get install -y -qq nodejs; then
      ok "Node.js $(node -v)"
      node_ok=true
    fi
  fi

  $node_ok || fail "Node.js >= 20 is required but could not be installed"
}

# ══════════════════════════════════════════════════════════════════
# PHASE 4: System Users
# ══════════════════════════════════════════════════════════════════

create_users() {
  step 4 $PHASE_TOTAL "System users"

  if [[ "$DRY_RUN" != "true" ]]; then
    id -u tsserver &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin tsserver
    id -u teamtp &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin teamtp
  fi
  ok "Users: tsserver, teamtp"
}

# ══════════════════════════════════════════════════════════════════
# PHASE 5: Deploy Files
# ══════════════════════════════════════════════════════════════════

deploy_files() {
  step 5 $PHASE_TOTAL "Deploying files"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "(dry-run) Would deploy to ${TEAMTP_DIR}"
    return 0
  fi

  local repo="${TEAMTP_REPO:-https://github.com/Cat-Ghost-Community/TimyabSpeak.git}"
  local src="${SRC_DIR}"
  local has_local_source=false

  # Check if we have local source files (e.g. running from a cloned repo)
  if [[ -d "$src" ]] && { [[ -f "${src}/install.sh" ]] || [[ -f "${src}/panel/server.js" ]]; }; then
    has_local_source=true
  elif [[ -d "$PWD" ]] && { [[ -f "${PWD}/install.sh" ]] || [[ -f "${PWD}/panel/server.js" ]]; }; then
    src="$PWD"
    has_local_source=true
  fi

  if $has_local_source; then
    # ── Local copy ──
    info "Copying from ${src}..."

    mkdir -p "$TEAMTP_DIR"

    local subdirs=(
      "config" "shared" "scripts"
      "bots/level-bot" "bots/temp-channel-bot" "bots/support-bot"
      "panel" "panel/public" "systemd"
    )
    for subd in "${subdirs[@]}"; do
      if [[ -d "${src}/${subd}" ]]; then
        mkdir -p "${TEAMTP_DIR}/${subd}"
        cp -r "${src}/${subd}/." "${TEAMTP_DIR}/${subd}/" 2>/dev/null || true
      fi
    done

    for f in .env.example install.sh; do
      [[ -f "${src}/${f}" ]] && cp "${src}/${f}" "${TEAMTP_DIR}/${f}"
    done

    find "$TEAMTP_DIR" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  else
    # ── No local source: clone from repo (handles curl | bash pipe install) ──
    info "No local files found — cloning from repository..."
    if [[ -d "${TEAMTP_DIR}/.git" ]]; then
      info "Pulling latest..."
      (cd "$TEAMTP_DIR" && git pull) >> "$INSTALL_LOG" 2>&1 || warn "git pull failed"
    else
      rm -rf "$TEAMTP_DIR"
      git clone --depth 1 --single-branch "$repo" "$TEAMTP_DIR" >> "$INSTALL_LOG" 2>&1 || {
        warn "git clone failed. For private repos, set TEAMTP_REPO with a PAT or deploy key."
        fail "Cannot deploy files. Try: TEAMTP_REPO=https://<token>@github.com/User/Repo.git sudo -E bash install.sh"
      }
    fi
  fi

  chown -R teamtp:teamtp "$TEAMTP_DIR" 2>/dev/null || true

  # Verify key files exist
  if [[ ! -f "${TEAMTP_DIR}/panel/server.js" ]]; then
    fail "Deployment verification failed: panel/server.js not found in ${TEAMTP_DIR}"
  fi
  if [[ ! -f "${TEAMTP_DIR}/shared/ts6-rest.js" ]]; then
    fail "Deployment verification failed: shared/ts6-rest.js not found in ${TEAMTP_DIR}"
  fi

  ok "Files deployed to ${TEAMTP_DIR}"
}

# ══════════════════════════════════════════════════════════════════
# PHASE 6: NPM Dependencies
# ══════════════════════════════════════════════════════════════════

install_npm() {
  step 6 $PHASE_TOTAL "npm dependencies"

  local dirs=(
    "bots/level-bot|better-sqlite3"
    "bots/temp-channel-bot|better-sqlite3"
    "bots/support-bot|better-sqlite3"
    "panel|express socket.io jsonwebtoken bcrypt helmet better-sqlite3"
  )

  for entry in "${dirs[@]}"; do
    local dir="${entry%%|*}"
    local deps="${entry#*|}"
    local full="${TEAMTP_DIR}/${dir}"

    mkdir -p "$full"

    if [[ ! -f "${full}/package.json" ]]; then
      _write_package_json "$full" "$(basename "$full")" "$deps"
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
      (cd "$full" && npm install --silent) >> "$INSTALL_LOG" 2>&1 || {
        warn "npm install failed in ${dir}, retrying..."
        (cd "$full" && npm install) >> "$INSTALL_LOG" 2>&1 || fail "npm install failed in ${dir}"
      }
    fi
  done

  if [[ "$DRY_RUN" != "true" ]]; then
    chown -R teamtp:teamtp "$TEAMTP_DIR" 2>/dev/null || true
  fi

  ok "npm dependencies installed"
}

_write_package_json() {
  local dir="$1" name="$2"
  shift 2
  local pkgs=("$@")
  local json='{
  "name": "'"teamtp-${name}"'",
  "version": "1.0.0",
  "private": true,
  "main": "index.js",
  "dependencies": {'
  local first=true
  for pkg in ${pkgs[*]}; do
    if $first; then
      first=false
      json+=$'\n'"    \"${pkg}\": \"*\""
    else
      json+=$',\n'"    \"${pkg}\": \"*\""
    fi
  done
  json+=$'\n'"  }"$'\n'"}"
  printf '%s\n' "$json" > "${dir}/package.json"
}

# ══════════════════════════════════════════════════════════════════
# PHASE 7: Generate Secrets & Ports
# ══════════════════════════════════════════════════════════════════

generate_secrets() {
  step 7 $PHASE_TOTAL "Generating secrets"

  SECRET_QUERY_PASS=$(openssl rand -hex 16)
  SECRET_API_KEY=$(openssl rand -hex 32)
  SECRET_JWT=$(openssl rand -hex 32)
  SECRET_REFRESH=$(openssl rand -hex 32)

  # bcrypt hash (bcrypt is now available from the npm install phase)
  local panel_dir="${TEAMTP_DIR}/panel"
  PANEL_BCRYPT_HASH=$(node -e "
try {
  const bcrypt = require('${panel_dir}/node_modules/bcrypt');
  console.log(bcrypt.hashSync(process.argv[1], 12));
} catch(e) {
  const bcrypt = require('bcrypt');
  console.log(bcrypt.hashSync(process.argv[1], 12));
}
" "$WIZARD_ADMIN_PASS") || fail "Failed to hash admin password. Is bcrypt installed in ${panel_dir}?"

  # Port scanning (exact match using ss)
  PORT_VOICE=$(find_port 9987 20 udp)   || fail "No free UDP voice port in range 9987-10007"
  PORT_FILE=$(find_port 30033 10 tcp)   || fail "No free file transfer port in range 30033-30043"
  PORT_SSH_QUERY=$(find_port 10022 10 tcp)  || fail "No free SSH query port in range 10022-10032"
  PORT_HTTP_QUERY=$(find_port 10080 10 tcp) || fail "No free HTTP query port in range 10080-10090"
  PORT_PANEL=$(find_port 3000 10 tcp)    || fail "No free panel port in range 3000-3010"

  ok "Ports: Voice=${PORT_VOICE} File=${PORT_FILE} Query=${PORT_HTTP_QUERY} Panel=${PORT_PANEL}"

  if [[ "$DRY_RUN" != "true" ]]; then
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
  fi

  ok "Secrets written to ${TEAMTP_DIR}/.env"
}

find_port() {
  local base=$1 max=$2 proto=$3 p
  if ! command -v ss &>/dev/null; then
    return 1
  fi
  for off in $(seq 0 "$max"); do
    p=$((base + off))
    if [[ "$proto" == "udp" ]]; then
      if [[ -z "$(ss -Huln sport = ":${p}" 2>/dev/null)" ]]; then
        echo "$p"; return 0
      fi
    else
      if [[ -z "$(ss -Htln sport = ":${p}" 2>/dev/null)" ]]; then
        echo "$p"; return 0
      fi
    fi
  done
  return 1
}

# ══════════════════════════════════════════════════════════════════
# PHASE 8: TeamSpeak 6 Server
# ══════════════════════════════════════════════════════════════════

install_ts6() {
  step 8 $PHASE_TOTAL "TeamSpeak 6 server"

  local ts_dir="${TEAMTP_DIR}/server/teamspeak6"
  local ts_bin="tsserver"

  if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$ts_dir"

    if [[ ! -f "${ts_dir}/${ts_bin}" ]]; then
      local tmp extract_dir
      tmp="$(mktemp)"
      extract_dir="$(mktemp -d)"

      _run_spin "Downloading TeamSpeak 6 server" curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 5 -o "$tmp" "$TS6_URL" || {
        rm -rf "$tmp" "$extract_dir"
        fail "Download failed (404 or network). TS6 beta URL may have changed. Override: TS6_URL=<url> sudo -E bash install.sh"
      }
      [[ -s "$tmp" ]] || { rm -rf "$tmp" "$extract_dir"; fail "Downloaded file is empty. The TS6 URL may be invalid."; }

      # Extract to temp dir to inspect structure
      if ! tar -xaf "$tmp" -C "$extract_dir" 2>/dev/null; then
        rm -rf "$tmp" "$extract_dir"
        fail "Archive extraction failed. Archive may be corrupted or in unexpected format."
      fi
      rm -f "$tmp"

      # Log structure for debugging
      echo "[TS6 archive contents]" >> "$INSTALL_LOG"
      find "$extract_dir" -type f 2>/dev/null | head -30 >> "$INSTALL_LOG" || true
      echo "" >> "$INSTALL_LOG"

      # Flatten: if single top-level dir, move its contents up; else copy directly
      local top_count content_dir="$extract_dir"
      top_count=$(find "$extract_dir" -maxdepth 1 -mindepth 1 | wc -l)
      if [[ "$top_count" -eq 1 ]] && [[ -d "$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d -print -quit 2>/dev/null)" ]]; then
        content_dir="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d -print -quit)"
      fi

      # Move everything into ts_dir
      shopt -s nullglob dotglob
      mv "$content_dir"/* "$ts_dir"/ 2>/dev/null || true
      shopt -u nullglob dotglob

      rm -rf "$extract_dir"

      # Find the server binary
      local found
      found=$(find "$ts_dir" -maxdepth 3 -type f -executable \( -name "tsserver" -o -name "teamspeak6-server" -o -name "teamspeak*server" \) -print -quit 2>/dev/null)
      [[ -z "$found" ]] && found=$(find "$ts_dir" -maxdepth 3 -type f \( -name "tsserver" -o -name "teamspeak6-server" -o -name "teamspeak*server" \) -print -quit 2>/dev/null)
      if [[ -n "$found" ]]; then
        chmod +x "$found"
        [[ "$(basename "$found")" != "$ts_bin" ]] && ln -sf "$(basename "$found")" "${ts_dir}/${ts_bin}"
        ok "TS6 binary: $(basename "$found")"
      elif [[ -f "${ts_dir}/${ts_bin}" ]]; then
        chmod +x "${ts_dir}/${ts_bin}"
      else
        fail "TS6 server binary not found after extraction. See log for archive contents."
      fi
    fi

    # Create required subdirectories (after extraction to avoid mv conflicts)
    mkdir -p "${ts_dir}/sql" "${ts_dir}/sql/create_sqlite"

    # Write config
    cat > "${ts_dir}/tsserver.yaml" <<YAML
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
    sql-path: ${ts_dir}/sql/
    sql-create-path: ${ts_dir}/sql/create_sqlite/
YAML

    chown -R tsserver:tsserver "$ts_dir" 2>/dev/null || true
  fi

  ok "TeamSpeak 6 server configured"
}

# ══════════════════════════════════════════════════════════════════
# PHASE 9: Systemd Services
# ══════════════════════════════════════════════════════════════════

setup_systemd() {
  step 9 $PHASE_TOTAL "Systemd services"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "(dry-run) Would install and start systemd services"
    return 0
  fi

  # Install unit files from systemd/ directory
  local systemd_src="${SRC_DIR}/systemd"
  [[ ! -d "$systemd_src" ]] && systemd_src="${TEAMTP_DIR}/systemd"

  if [[ -d "$systemd_src" ]]; then
    for unit_file in "$systemd_src"/*.service; do
      [[ -f "$unit_file" ]] || continue
      local unit_name
      unit_name="$(basename "$unit_file")"
      if grep -q "/opt/teamtp" "$unit_file" 2>/dev/null && [[ "$TEAMTP_DIR" != "/opt/teamtp" ]]; then
        sed "s|/opt/teamtp|${TEAMTP_DIR}|g" "$unit_file" > "/etc/systemd/system/${unit_name}"
      else
        cp "$unit_file" "/etc/systemd/system/${unit_name}"
      fi
    done
  else
    # Fallback: generate units inline
    _write_systemd_units_inline
  fi

  systemctl daemon-reload 2>/dev/null || true
  _cmd systemctl enable teamspeak6 || warn "Failed to enable teamspeak6"

  # Start TS6
  _run_spin "Starting TeamSpeak 6" systemctl start teamspeak6 || warn "TS6 failed to start"

  # Wait for TS6 HTTP query port
  local waited=0 max_wait=60
  while [[ -z "$(ss -Htln sport = ":${PORT_HTTP_QUERY}" 2>/dev/null)" ]]; do
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge $max_wait ]]; then
      warn "TS6 did not start within ${max_wait}s. Check: journalctl -u teamspeak6"
      break
    fi
  done

  if [[ -n "$(ss -Htln sport = ":${PORT_HTTP_QUERY}" 2>/dev/null)" ]]; then
    ok "TeamSpeak 6 is running"
    # Capture privilege key
    PRIVILEGE_KEY=$(journalctl -u teamspeak6 --no-pager -n 150 2>/dev/null | grep -oP "token=\K\S+" | head -1 || true)
    if [[ -n "$PRIVILEGE_KEY" ]]; then
      printf 'TS6_PRIVILEGE_KEY=%s\n' "$PRIVILEGE_KEY" >> "${TEAMTP_DIR}/.env"
      ok "Privilege key captured"
    else
      warn "Could not capture privilege key. Run: journalctl -u teamspeak6 | grep token"
    fi
  fi

  # Enable and start bots + panel
  local svcs=(teamtp-level-bot teamtp-temp-bot teamtp-support-bot teamtp-panel)
  for svc in "${svcs[@]}"; do
    _cmd systemctl enable "$svc" 2>/dev/null || true
    _cmd systemctl start "$svc" 2>/dev/null || true
    sleep 1
  done

  ok "All services started"
}

_write_systemd_units_inline() {
  # TS6 service
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
ExecStart=${TEAMTP_DIR}/server/teamspeak6/tsserver --config-file ${TEAMTP_DIR}/server/teamspeak6/tsserver.yaml
ExecStop=/bin/kill -SIGTERM \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=4096
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

  # Bot services
  local bots=(level:level-bot temp:temp-channel-bot support:support-bot)
  for pair in "${bots[@]}"; do
    local name="${pair%%:*}" dir="${pair#*:}"
    cat > "/etc/systemd/system/teamtp-${name}-bot.service" <<UNIT
[Unit]
Description=TeamTP ${name^} Bot
After=teamspeak6.service
Wants=teamspeak6.service

[Service]
Type=simple
User=teamtp
Group=teamtp
WorkingDirectory=${TEAMTP_DIR}/bots/${dir}
ExecStart=/usr/bin/node ${TEAMTP_DIR}/bots/${dir}/index.js
EnvironmentFile=${TEAMTP_DIR}/.env
Restart=on-failure
RestartSec=10
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
UNIT
  done

  # Panel service
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
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
UNIT
}

# ══════════════════════════════════════════════════════════════════
# PHASE 10: CLI
# ══════════════════════════════════════════════════════════════════

install_cli() {
  step 10 $PHASE_TOTAL "CLI tool"

  if [[ "$DRY_RUN" != "true" ]]; then
    local cli_src="${SRC_DIR}/scripts/teamtp.sh"
    [[ ! -f "$cli_src" ]] && cli_src="${TEAMTP_DIR}/scripts/teamtp.sh"

    if [[ -f "$cli_src" ]]; then
      cp "$cli_src" /usr/local/bin/teamtp
    else
      _write_cli_inline
    fi
    chmod +x /usr/local/bin/teamtp
  fi

  ok "CLI installed: /usr/local/bin/teamtp"
}

_write_cli_inline() {
  cat > /usr/local/bin/teamtp <<'CLIEOF'
#!/usr/bin/env bash
set -euo pipefail

TEAMTP_DIR="/opt/teamtp"
ENV_FILE="${TEAMTP_DIR}/.env"

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE" 2>/dev/null || true
    set +a
  fi
}

cmd_status() {
  load_env
  printf "%-28s %s\n" "SERVICE" "STATUS"
  printf "%-28s %s\n" "──────────────────────────" "────────"
  for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    local state
    state=$(systemctl is-active "$s" 2>/dev/null || echo "inactive")
    printf "  %-26s %s\n" "$s" "$state"
  done
  local ver
  ver=$(grep TEAMTP_VERSION "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
  echo ""
  printf "  Version: %s\n" "$ver"
}

cmd_restart() {
  for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl restart "$s" 2>/dev/null || true
  done
  echo "All services restarted."
}

cmd_bot() {
  local bot="$1" action="$2"
  case "$bot" in
    level|temp|support) ;;
    *) echo "Unknown bot: ${bot}. Use: level, temp, or support."; exit 1 ;;
  esac
  local svc="teamtp-${bot}-bot"
  case "$action" in
    on|start)   systemctl start "$svc" 2>/dev/null && echo "${bot}: started"   || { echo "Failed to start ${svc}"; exit 1; } ;;
    off|stop)   systemctl stop "$svc" 2>/dev/null  && echo "${bot}: stopped"   || { echo "Failed to stop ${svc}"; exit 1; } ;;
    restart)    systemctl restart "$svc" 2>/dev/null && echo "${bot}: restarted" || { echo "Failed to restart ${svc}"; exit 1; } ;;
    status)
      local state
      state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
      printf "%s: %s\n" "$bot" "$state"
      ;;
    *) echo "Action: on|off|restart|status"; exit 1 ;;
  esac
}

cmd_panel() {
  load_env
  local ip proto="http"
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"
  [[ "${WIZARD_SSL:-}" =~ ^(letsencrypt|self-signed)$ ]] && proto="https"
  echo "Panel access:"
  echo "  Local:     http://localhost:${PORT_PANEL:-3000}"
  echo "  External:  ${proto}://${ip}"
  if [[ -n "${WIZARD_DOMAIN:-}" ]]; then
    echo "  Domain:    ${proto}://panel.${WIZARD_DOMAIN}"
  fi
}

cmd_ssl() {
  if command -v certbot &>/dev/null; then
    certbot renew --non-interactive 2>&1 || { echo "SSL renewal failed"; exit 1; }
    systemctl reload nginx 2>/dev/null || true
    echo "SSL renewal complete."
  else
    echo "certbot is not installed."
    exit 1
  fi
}

cmd_backup() {
  load_env
  local stamp f
  stamp=$(date +%Y%m%d-%H%M%S)
  f="${TEAMTP_DIR}/backups/teamtp-${stamp}.tar.gz"
  mkdir -p "${TEAMTP_DIR}/backups"
  echo "Creating backup..."

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
    echo "Backup: $f ($(du -h "$f" | cut -f1))"
  else
    echo "Backup failed."
    exit 1
  fi

  find "${TEAMTP_DIR}/backups" -name "teamtp-*.tar.gz" -mtime +30 -delete 2>/dev/null || true
}

cmd_update() {
  load_env
  echo "=== TimyabSpeak Update ==="
  echo "Creating pre-update backup..."
  "$0" backup || echo "Pre-update backup skipped."
  echo ""

  if [[ -d "${TEAMTP_DIR}/.git" ]]; then
    echo "Pulling latest code..."
    (cd "$TEAMTP_DIR" && git pull 2>&1) || echo "git pull failed."
  else
    echo "Not a git repository — skipping pull."
  fi

  echo "Updating npm packages..."
  for d in panel bots/level-bot bots/temp-channel-bot bots/support-bot; do
    if [[ -f "${TEAMTP_DIR}/${d}/package.json" ]]; then
      (cd "${TEAMTP_DIR}/${d}" && npm ci --silent 2>/dev/null) || (cd "${TEAMTP_DIR}/${d}" && npm install --silent 2>/dev/null) || true
    fi
  done

  # Update CLI if source exists
  if [[ -f "${TEAMTP_DIR}/scripts/teamtp.sh" ]]; then
    cp "${TEAMTP_DIR}/scripts/teamtp.sh" /usr/local/bin/teamtp
    chmod +x /usr/local/bin/teamtp
    echo "CLI updated."
  fi

  systemctl daemon-reload 2>/dev/null || true
  for s in teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl restart "$s" 2>/dev/null || true
  done
  echo "Update complete."
}

cmd_health() {
  if systemctl is-active teamspeak6 >/dev/null 2>&1; then
    echo "OK"; exit 0
  else
    echo "DOWN"; exit 1
  fi
}

cmd_logs() {
  journalctl -u "${2:-teamspeak6}" --no-pager -n "${3:-50}"
}

cmd_wipe() {
  echo ""
  echo "  WARNING: This will DELETE everything — databases, config, services, files."
  echo ""
  local ans
  read -rp '  Type DELETE to confirm: ' ans 2>/dev/null || true
  if [[ "$ans" != "DELETE" ]]; then
    echo "  Aborted."
    exit 0
  fi

  echo "  Stopping services..."
  for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
  done

  rm -f /etc/systemd/system/teamspeak6.service /etc/systemd/system/teamtp-*.service
  systemctl daemon-reload 2>/dev/null || true
  rm -f /etc/nginx/sites-available/teamtp /etc/nginx/sites-available/teamtp-ssl
  rm -f /etc/nginx/sites-enabled/teamtp /etc/nginx/sites-enabled/teamtp-ssl
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
  rm -rf "$TEAMTP_DIR" /usr/local/bin/teamtp
  rm -f /var/log/teamtp-install.log /etc/logrotate.d/teamtp
  rm -rf /var/log/teamtp

  echo ""
  echo "  Wipe complete. All traces removed."
  echo "  Re-run install.sh for a fresh installation."
}

cmd_help() {
  echo "Usage: teamtp <command> [args]"
  echo ""
  echo "Commands:"
  echo "  status                  Show all services status"
  echo "  restart                 Restart all services"
  echo "  bot <name> <action>     Control bots (level|temp|support) (on|off|restart|status)"
  echo "  panel                   Show panel access URLs"
  echo "  ssl                     Renew SSL certificates"
  echo "  backup                  Create backup (30-day retention)"
  echo "  update                  Pre-backup → git pull → npm ci → restart all"
  echo "  health                  Exit 0 if TS6 is running"
  echo "  logs [svc] [lines]      View service logs (default: teamspeak6, 50 lines)"
  echo "  wipe                    DELETE everything (requires confirmation)"
  echo "  help                    Show this help"
}

case "${1:-help}" in
  status)  cmd_status ;;
  restart) cmd_restart ;;
  bot)     if [[ $# -lt 3 ]]; then echo "Usage: teamtp bot <level|temp|support> <on|off|restart|status>"; exit 1; fi
           cmd_bot "$2" "$3" ;;
  panel)   cmd_panel ;;
  ssl)     cmd_ssl ;;
  backup)  cmd_backup ;;
  update)  cmd_update ;;
  health)  cmd_health ;;
  logs)    cmd_logs "$@" ;;
  wipe)    cmd_wipe ;;
  help|--help|-h) cmd_help ;;
  *) echo "Unknown command: ${1:-}. Use 'teamtp help' for usage."; exit 1 ;;
esac
CLIEOF
}

# ══════════════════════════════════════════════════════════════════
# PHASE 11: Nginx & SSL
# ══════════════════════════════════════════════════════════════════

setup_nginx() {
  step 11 $PHASE_TOTAL "Nginx & SSL"

  local domain="${WIZARD_DOMAIN:-}"
  local server_names
  if [[ -n "$domain" ]]; then
    server_names="${domain} panel.${domain}"
  else
    server_names="_"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "(dry-run) Would configure nginx with server_names: ${server_names}"
    info "(dry-run) SSL mode: ${WIZARD_SSL:-none}"
    return 0
  fi

  # HTTP server block
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

  ln -sf /etc/nginx/sites-available/teamtp /etc/nginx/sites-enabled/teamtp
  rm -f /etc/nginx/sites-enabled/default

  case "${WIZARD_SSL:-}" in
    letsencrypt)
      if [[ -z "$domain" ]]; then
        warn "Let's Encrypt requires a domain name — skipping"
      else
        _run_spin "Installing certbot" apt-get install -y -qq certbot python3-certbot-nginx 2>/dev/null || warn "certbot install failed"
        if certbot --nginx -d "$domain" -d "panel.${domain}" --non-interactive --agree-tos --email "admin@${domain}" --redirect 2>/dev/null; then
          ok "Let's Encrypt SSL configured for ${domain}"
        else
          warn "Let's Encrypt failed. Check that DNS points to this server."
          warn "HTTP-only mode active."
        fi
      fi
      ;;

    self-signed)
      mkdir -p /etc/nginx/ssl
      local cn="${domain:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
      [[ -z "$cn" ]] && cn="teamtp-server"
      if openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
          -keyout /etc/nginx/ssl/teamtp.key \
          -out /etc/nginx/ssl/teamtp.crt \
          -subj "/CN=${cn}" 2>/dev/null; then
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
        ln -sf /etc/nginx/sites-available/teamtp-ssl /etc/nginx/sites-enabled/teamtp-ssl
        ok "Self-signed SSL configured for ${cn}"
      else
        warn "Self-signed certificate generation failed"
      fi
      ;;

    *)
      ok "No SSL — HTTP only"
      ;;
  esac

  if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || warn "nginx reload failed"
    ok "Nginx configured and running"
  else
    warn "nginx configuration test failed"
  fi
}

# ══════════════════════════════════════════════════════════════════
# PHASE 12: Firewall & fail2ban
# ══════════════════════════════════════════════════════════════════

setup_firewall() {
  step 12 $PHASE_TOTAL "Firewall & security"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "(dry-run) Would configure UFW and fail2ban"
    return 0
  fi

  if command -v ufw &>/dev/null; then
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    ufw allow "${PORT_VOICE}/udp" 2>/dev/null || true
    ufw allow "${PORT_FILE}/tcp" 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw allow ssh 2>/dev/null || true
    ufw --force enable 2>/dev/null || warn "UFW enable failed"
    ok "Firewall: voice/filetransfer/80/443/ssh allowed"
  else
    warn "UFW not found — skipping firewall"
  fi

  if command -v fail2ban-server &>/dev/null || command -v fail2ban-client &>/dev/null; then
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

# ══════════════════════════════════════════════════════════════════
# PHASE 13: Finishing touches
# ══════════════════════════════════════════════════════════════════

finish_setup() {
  step 13 $PHASE_TOTAL "Finishing up"

  if [[ "$DRY_RUN" != "true" ]]; then
    # Logrotate
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

    # Welcome message
    mkdir -p "${TEAMTP_DIR}/config"
    printf '%s\n' "$WIZARD_WELCOME" > "${TEAMTP_DIR}/config/welcome.txt"
    chown teamtp:teamtp "${TEAMTP_DIR}/config/welcome.txt"

    # Marker
    touch "$MARKER"
  fi

  ok "Logrotate, welcome message, marker written"
}

# ══════════════════════════════════════════════════════════════════
# PHASE 14: Summary
# ══════════════════════════════════════════════════════════════════

print_summary() {
  step 14 $PHASE_TOTAL "Installation complete"

  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"

  local proto="http"
  [[ "${WIZARD_SSL:-}" =~ ^(letsencrypt|self-signed)$ ]] && proto="https"

  local panel_url_domain=""
  if [[ -n "${WIZARD_DOMAIN:-}" ]]; then
    panel_url_domain="${proto}://panel.${WIZARD_DOMAIN}"
  fi

  echo ""
  echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${BOLD}${GREEN}║${NC}                                                          ${BOLD}${GREEN}║${NC}"
  echo -e "  ${BOLD}${GREEN}║${NC}  ${BOLD}Installation Complete!${NC}                                  ${BOLD}${GREEN}║${NC}"
  echo -e "  ${BOLD}${GREEN}║${NC}                                                          ${BOLD}${GREEN}║${NC}"
  printf "  ${BOLD}${GREEN}║${NC}  %-18s ${BOLD}%-35s${NC} ${BOLD}${GREEN}║${NC}\n" "Voice Server" "${ip}:${PORT_VOICE}"
  if [[ -n "$panel_url_domain" ]]; then
    printf "  ${BOLD}${GREEN}║${NC}  %-18s ${BOLD}%-35s${NC} ${BOLD}${GREEN}║${NC}\n" "Panel" "$panel_url_domain"
  fi
  printf "  ${BOLD}${GREEN}║${NC}  %-18s ${BOLD}%-35s${NC} ${BOLD}${GREEN}║${NC}\n" "Panel (local)" "http://localhost:${PORT_PANEL}"
  printf "  ${BOLD}${GREEN}║${NC}  %-18s %-35s ${BOLD}${GREEN}║${NC}\n" "Admin User" "$WIZARD_ADMIN_USER"
  echo -e "  ${BOLD}${GREEN}║${NC}                                                          ${BOLD}${GREEN}║${NC}"
  echo -e "  ${BOLD}${GREEN}║${NC}  ${DIM}Commands${NC}                                                ${BOLD}${GREEN}║${NC}"
  printf "  ${BOLD}${GREEN}║${NC}    ${DIM}%-50s${NC} ${BOLD}${GREEN}║${NC}\n" "teamtp status    — Show all services"
  printf "  ${BOLD}${GREEN}║${NC}    ${DIM}%-50s${NC} ${BOLD}${GREEN}║${NC}\n" "teamtp restart   — Restart everything"
  printf "  ${BOLD}${GREEN}║${NC}    ${DIM}%-50s${NC} ${BOLD}${GREEN}║${NC}\n" "teamtp backup    — Create backup"
  printf "  ${BOLD}${GREEN}║${NC}    ${DIM}%-50s${NC} ${BOLD}${GREEN}║${NC}\n" "teamtp update    — Update to latest"
  printf "  ${BOLD}${GREEN}║${NC}    ${DIM}%-50s${NC} ${BOLD}${GREEN}║${NC}\n" "teamtp logs      — View service logs"
  printf "  ${BOLD}${GREEN}║${NC}    ${DIM}%-50s${NC} ${BOLD}${GREEN}║${NC}\n" "teamtp help      — Full command list"
  echo -e "  ${BOLD}${GREEN}║${NC}                                                          ${BOLD}${GREEN}║${NC}"
  printf "  ${BOLD}${GREEN}║${NC}  %-18s %-35s ${BOLD}${GREEN}║${NC}\n" "Log" "$INSTALL_LOG"
  printf "  ${BOLD}${GREEN}║${NC}  %-18s %-35s ${BOLD}${GREEN}║${NC}\n" "Config" "${TEAMTP_DIR}/.env"
  echo -e "  ${BOLD}${GREEN}║${NC}                                                          ${BOLD}${GREEN}║${NC}"
  echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if [[ -n "${PRIVILEGE_KEY:-}" ]]; then
    echo -e "  ${YELLOW}${WRN} Privilege Key:${NC} ${BOLD}${PRIVILEGE_KEY}${NC}"
    echo -e "  ${YELLOW}${WRN} Save this key — it is shown only once!${NC}"
    echo -e "  ${DIM}  Also stored in: ${TEAMTP_DIR}/.env${NC}"
    echo ""
  else
    echo -e "  ${YELLOW}${WRN} Privilege key not automatically captured.${NC}"
    echo -e "  ${DIM}  Run: journalctl -u teamspeak6 | grep token${NC}"
    echo ""
  fi

  echo -e "  ${GREEN}${CHK}${NC} Enjoy your TeamSpeak 6 server!"
  echo ""
}

# ══════════════════════════════════════════════════════════════════
# Wipe operation
# ══════════════════════════════════════════════════════════════════

do_wipe() {
  exec </dev/tty || true
  echo ""
  echo -e "  ${RED}${BOLD}WARNING: This will DELETE everything.${NC}"
  echo ""
  local ans
  printf "  Type DELETE to confirm: " >/dev/tty
  read -r ans </dev/tty 2>/dev/null || true
  if [[ "$ans" != "DELETE" ]]; then
    echo "  Aborted."
    return
  fi

  for s in teamspeak6 teamtp-panel teamtp-level-bot teamtp-temp-bot teamtp-support-bot; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/teamspeak6.service /etc/systemd/system/teamtp-*.service
  systemctl daemon-reload 2>/dev/null || true
  rm -f /etc/nginx/sites-available/teamtp /etc/nginx/sites-available/teamtp-ssl
  rm -f /etc/nginx/sites-enabled/teamtp /etc/nginx/sites-enabled/teamtp-ssl
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
  rm -rf "$TEAMTP_DIR" /usr/local/bin/teamtp
  rm -f "$INSTALL_LOG" /etc/logrotate.d/teamtp
  rm -rf /var/log/teamtp

  echo ""
  echo -e "  ${GREEN}${CHK}${NC} Wipe complete. All traces removed."
  echo "  Re-run install.sh for a fresh installation."
}

# ══════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════

main() {
  parse_args "$@"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo -e "  ${YELLOW}${INF} DRY RUN MODE — no changes will be made${NC}"
  fi

  mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true
  touch "$INSTALL_LOG" 2>/dev/null || true
  if [[ "$DEBUG" == "true" ]]; then
    set -x
    export PS4='+ ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
  else
    exec 2>>"$INSTALL_LOG"
  fi

  show_header

  _run_phase() {
    local n="$1"; shift
    if [[ "$RESUME" == "true" ]] && _phase_skip "$n"; then
      info "Phase ${n} already completed, skipping"; return 0
    fi
    _phase_enter "$n"
    "$@"
    _phase_done
  }

  # Clean any stale phase markers from a previous interrupted run
  [[ "$RESUME" != "true" ]] && rm -f "${TEAMTP_DIR}"/.phase-* 2>/dev/null || true

  _run_phase 1  preflight
  _run_phase 2  wizard
  _run_phase 3  install_deps
  _run_phase 4  create_users
  _run_phase 5  deploy_files
  _run_phase 6  install_npm
  _run_phase 7  generate_secrets
  _run_phase 8  install_ts6
  _run_phase 9  setup_systemd
  _run_phase 10 install_cli
  _run_phase 11 setup_nginx
  _run_phase 12 setup_firewall
  _run_phase 13 finish_setup
  _run_phase 14 print_summary

  _log "Installation complete. Version: ${INSTALL_VERSION}"
}

main "$@"
