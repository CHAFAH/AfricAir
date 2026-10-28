#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ops/report.sh [logfile]

Summarises the nginx JSON access log (default /var/log/nginx/africair.access.json) using only
jq, awk, sort and uniq: top 10 client IPs, requests by status class, the 10 most requested paths,
and requests per minute over the last hour. Lines that are not valid JSON are skipped.
EOF
}
[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }

LOG=${1:-/var/log/nginx/africair.access.json}
[[ -r $LOG ]] || die 1 "cannot read $LOG"
require_cmd jq awk sort uniq

# Every record once, as TSV: msec, minute (YYYY-MM-DDTHH:MM), client, status, path (query string removed)
records() {
  jq -Rr 'fromjson? // empty
    | [(.msec | tonumber), (.time[0:16]), .remote_addr, (.status | tostring), (.uri | split("?")[0])] | @tsv' "$LOG"
}

section() { printf '\n== %s ==\n' "$1"; }

section "Top 10 client IPs"
records | awk -F'\t' '{ print $3 }' | sort | uniq -c | sort -rn | head -n 10

section "Requests by status class"
records | awk -F'\t' '{ print substr($4, 1, 1) "xx" }' | sort | uniq -c | sort -k2

section "Top 10 paths"
records | awk -F'\t' '{ print $5 }' | sort | uniq -c | sort -rn | head -n 10

section "Requests per minute, last hour (UTC)"
since=$(jq -n 'now - 3600')
records | awk -F'\t' -v since="$since" '$1 >= since { print $2 }' | sort | uniq -c | awk '{ printf "%s  %5d\n", $2, $1 }'
