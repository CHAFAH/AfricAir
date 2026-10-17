#!/usr/bin/env bash
# report.sh — analyse AfricAir JSON access log
# Usage: scripts/ops/report.sh [logfile]
# Requires: jq, awk, sort, uniq
set -Eeuo pipefail

LOGFILE=${1:-/var/log/nginx/africair.access.json}

if [[ ! -f "$LOGFILE" ]]; then
  echo "ERROR: log file not found: $LOGFILE" >&2
  exit 1
fi

# Filter only valid JSON lines using awk
json_lines() { awk '/^\{/' "$LOGFILE"; }

one_hour_ago=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M' 2>/dev/null || date -u -v-1H '+%Y-%m-%dT%H:%M')

echo "=== Top 10 client IPs ==="
json_lines | jq -r '.ip' | sort | uniq -c | sort -rn | head -10

echo ""
echo "=== Request counts by status class ==="
json_lines | jq -r '.status' | awk '{print int($1/100)"xx"}' | sort | uniq -c | sort -rn

echo ""
echo "=== Top 10 most requested paths ==="
json_lines | jq -r '.uri' | sort | uniq -c | sort -rn | head -10

echo ""
echo "=== Requests per minute (last hour) ==="
json_lines | jq -r '.time' | awk -v cutoff="$one_hour_ago" '
  length($0) >= 16 && substr($0,1,16) >= cutoff { print substr($0,1,16) }
' | sort | uniq -c | awk '{print $2, $1}'
