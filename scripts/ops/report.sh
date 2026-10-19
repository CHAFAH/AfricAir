#!/usr/bin/env bash
set -Eeuo pipefail

logfile="${1:-/var/log/nginx/africair.access.json}"

usage() {
  printf 'Usage: %s [logfile]\n' "$0"
}

if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
  usage
  exit 0
fi

if (( $# > 1 )); then
  usage >&2
  exit 2
fi

if [[ ! -r "$logfile" ]]; then
  printf 'ERROR: log file is not readable: %s\n' "$logfile" >&2
  exit 1
fi

for command in jq awk sort uniq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

if ! jq -e . "$logfile" >/dev/null; then
  printf 'ERROR: log file contains invalid JSON: %s\n' "$logfile" >&2
  exit 1
fi

printf 'Top 10 client IPs\n'
printf '%-10s %s\n' 'REQUESTS' 'CLIENT_IP'
jq -r '.remote_addr // empty' "$logfile" |
  sort |
  uniq -c |
  sort -nr |
  awk 'NR <= 10 { printf "%-10d %s\n", $1, $2 }'

printf '\nRequests by status class\n'
printf '%-10s %s\n' 'REQUESTS' 'CLASS'
jq -r '.status // empty | tostring' "$logfile" |
  awk '/^[1-5][0-9][0-9]$/ { print substr($0, 1, 1) "xx" }' |
  sort |
  uniq -c |
  sort |
  awk '{ printf "%-10d %s\n", $1, $2 }'

printf '\nTop 10 requested paths\n'
printf '%-10s %s\n' 'REQUESTS' 'PATH'
jq -r '.path // empty' "$logfile" |
  sort |
  uniq -c |
  sort -nr |
  awk 'NR <= 10 { count=$1; $1=""; sub(/^ /, ""); printf "%-10d %s\n", count, $0 }'

printf '\nRequests per minute during the last hour\n'
printf '%-10s %s\n' 'REQUESTS' 'MINUTE_UTC'
jq -r '
  select((.timestamp // 0) >= (now - 3600))
  | (.time // "")[0:16]
  | select(length > 0)
' "$logfile" |
  sort |
  uniq -c |
  sort |
  awk '{ printf "%-10d %s\n", $1, $2 }'
