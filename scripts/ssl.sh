#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-}"
ACTION="${2:-status}"

case "$ACTION" in
  renew)
    [[ -z "$DOMAIN" ]] && { echo "Usage: $0 <domain> renew"; exit 1; }
    certbot renew --domain "$DOMAIN" --non-interactive
    systemctl reload nginx
    echo "SSL renewed for $DOMAIN"
    ;;
  status)
    certbot certificates 2>/dev/null || echo "No certbot certificates found"
    ;;
  *)
    echo "Usage: $0 [domain] {renew|status}"
    exit 1
    ;;
esac
