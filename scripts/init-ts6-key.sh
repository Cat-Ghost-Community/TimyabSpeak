#!/usr/bin/env bash
# TimyabSpeak — Initialize TS6 API key via SSH query
set -euo pipefail

ENV_FILE="${1:-/opt/teamtp/.env}"
TS6_KEY=""
TS6_PASS=""
TS6_PORT="10022"

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE" 2>/dev/null || true; set +a
    TS6_PASS="${TS6_QUERY_PASSWORD:-}"
    TS6_PORT="${TS6_QUERY_PORT:-10022}"
    TS6_KEY="${TS6_API_KEY:-}"
  fi
}

load_env

# Already have a key that works — skip
if [[ -n "$TS6_KEY" ]] && curl -sf -o /dev/null -H "X-API-Key: $TS6_KEY" "http://127.0.0.1:${PORT_HTTP_QUERY:-10080}/clients" 2>/dev/null; then
  exit 0
fi

# Install sshpass if missing
if ! command -v sshpass &>/dev/null; then
  apt-get install -y -qq sshpass 2>/dev/null || true
fi

if ! command -v sshpass &>/dev/null; then
  echo "[init-ts6-key] sshpass not available, skipping API key generation"
  exit 0
fi

echo "[init-ts6-key] Creating API key..."
RAW=$(sshpass -p "$TS6_PASS" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=5 \
  -o LogLevel=ERROR \
  serveradmin@127.0.0.1 \
  -p "$TS6_PORT" \
  "apikeyadd scope=manage" 2>/dev/null || true)

if [[ -z "$RAW" ]]; then
  # Try with use command first (some TS versions require virtual server selection)
  RAW=$(sshpass -p "$TS6_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o LogLevel=ERROR \
    serveradmin@127.0.0.1 \
    -p "$TS6_PORT" \
    "use 1; apikeyadd scope=manage" 2>/dev/null || true)
fi

if [[ -n "$RAW" ]]; then
  NEW_KEY=$(echo "$RAW" | grep -oP 'token=\K\S+' | head -1 || true)
  if [[ -n "$NEW_KEY" ]]; then
    if grep -q "^TS6_API_KEY=" "$ENV_FILE" 2>/dev/null; then
      sed -i "s|^TS6_API_KEY=.*|TS6_API_KEY=${NEW_KEY}|" "$ENV_FILE"
    else
      echo "TS6_API_KEY=${NEW_KEY}" >> "$ENV_FILE"
    fi
    echo "[init-ts6-key] API key created and stored"
  else
    echo "[init-ts6-key] WARNING: Could not parse token from SSH response"
  fi
else
  echo "[init-ts6-key] WARNING: SSH query returned empty response"
fi
