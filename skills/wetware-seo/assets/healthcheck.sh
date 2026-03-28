#!/usr/bin/env bash
# SEO Pipeline: Daily health check
# Hermes runs this daily at 05:00 CT
# Checks HTTP status + SSL expiry for all client domains
# Writes alerts to knowledge/memory/seo-alerts.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ALERTS_FILE="$VAULT_DIR/knowledge/memory/seo-alerts.md"
CLIENTS_FILE="$SCRIPT_DIR/clients.json"
TODAY=$(date +%Y-%m-%d)
NOW=$(date +%H:%M)

# Check dependencies
for cmd in curl jq openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found" >&2
    exit 1
  fi
done

CLIENT_COUNT=$(jq '.clients | length' "$CLIENTS_FILE")

# Collect alerts
ALERTS=()
ALL_OK=true

for i in $(seq 0 $((CLIENT_COUNT - 1))); do
  NAME=$(jq -r ".clients[$i].name" "$CLIENTS_FILE")
  DOMAIN=$(jq -r ".clients[$i].domain" "$CLIENTS_FILE")

  # HTTP status
  HTTP_CODE=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN/" 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "000" ]; then
    ALERTS+=("CRITICAL: $NAME ($DOMAIN) is UNREACHABLE")
    ALL_OK=false
  elif [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "301" && "$HTTP_CODE" != "302" && "$HTTP_CODE" != "307" && "$HTTP_CODE" != "308" ]]; then
    ALERTS+=("WARNING: $NAME ($DOMAIN) returned HTTP $HTTP_CODE")
    ALL_OK=false
  fi

  # SSL expiry
  SSL_EXPIRY_RAW=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "")

  if [ -n "$SSL_EXPIRY_RAW" ]; then
    SSL_EPOCH=$(date -j -f "%b %d %T %Y %Z" "$SSL_EXPIRY_RAW" "+%s" 2>/dev/null || date -d "$SSL_EXPIRY_RAW" "+%s" 2>/dev/null || echo "0")
    NOW_EPOCH=$(date "+%s")
    DAYS_LEFT=$(( (SSL_EPOCH - NOW_EPOCH) / 86400 ))

    if [ "$DAYS_LEFT" -lt 0 ]; then
      ALERTS+=("CRITICAL: $NAME ($DOMAIN) SSL certificate EXPIRED")
      ALL_OK=false
    elif [ "$DAYS_LEFT" -lt 14 ]; then
      ALERTS+=("WARNING: $NAME ($DOMAIN) SSL expires in $DAYS_LEFT days ($SSL_EXPIRY_RAW)")
      ALL_OK=false
    fi
  else
    ALERTS+=("WARNING: $NAME ($DOMAIN) SSL check failed; could not read certificate")
    ALL_OK=false
  fi
done

# Write alerts file
cat > "$ALERTS_FILE" <<HEADER
---
type: seo-alerts
updated: $TODAY $NOW
---

# SEO Alerts

**Last check:** $TODAY $NOW

HEADER

if [ "$ALL_OK" = true ]; then
  echo "All $CLIENT_COUNT client domains are healthy. No alerts." >> "$ALERTS_FILE"
else
  echo "## Active Alerts" >> "$ALERTS_FILE"
  echo "" >> "$ALERTS_FILE"
  for alert in "${ALERTS[@]}"; do
    echo "- $alert" >> "$ALERTS_FILE"
  done
fi

echo "" >> "$ALERTS_FILE"
echo "## Domain Status" >> "$ALERTS_FILE"
echo "" >> "$ALERTS_FILE"
echo "| Domain | HTTP | SSL |" >> "$ALERTS_FILE"
echo "|--------|------|-----|" >> "$ALERTS_FILE"

for i in $(seq 0 $((CLIENT_COUNT - 1))); do
  NAME=$(jq -r ".clients[$i].name" "$CLIENTS_FILE")
  DOMAIN=$(jq -r ".clients[$i].domain" "$CLIENTS_FILE")

  HTTP_CODE=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN/" 2>/dev/null || echo "000")

  SSL_EXPIRY_RAW=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "UNKNOWN")

  echo "| $NAME ($DOMAIN) | $HTTP_CODE | $SSL_EXPIRY_RAW |" >> "$ALERTS_FILE"
done

# Print summary
if [ "$ALL_OK" = true ]; then
  echo "Health check: all $CLIENT_COUNT domains OK"
else
  echo "Health check: ${#ALERTS[@]} alert(s) found"
  for alert in "${ALERTS[@]}"; do
    echo "  $alert"
  done
fi
