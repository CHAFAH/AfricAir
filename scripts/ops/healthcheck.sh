#!/usr/bin/env bash
set -Eeuo pipefail

TAG=africair-health
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1/healthz}"
STATE_DIR="${STATE_DIR:-/var/lib/africair}"
STATE_FILE="$STATE_DIR/healthcheck.failures"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"

log() {
  logger -t "$TAG" -- "$*"
}

warn() {
  logger -p user.warning -t "$TAG" -- "WARNING: $*"
}

trap 'rc=$?; warn "healthcheck script failed at line ${BASH_LINENO[0]} with exit code $rc"; exit "$rc"' ERR

install -d -o root -g root -m 0755 "$STATE_DIR"

failures=0
if [[ -f "$STATE_FILE" ]]; then
  stored="$(< "$STATE_FILE")"
  if [[ "$stored" =~ ^[0-9]+$ ]]; then
    failures="$stored"
  else
    warn "invalid failure state '$stored'; resetting it"
  fi
fi

write_state() {
  local value=$1
  local temporary="$STATE_DIR/.healthcheck.failures.$$"
  printf '%s\n' "$value" > "$temporary"
  chmod 0644 "$temporary"
  mv -f "$temporary" "$STATE_FILE"
}

body=''
if body="$(curl --fail --silent --show-error --max-time 10 "$HEALTH_URL")" &&
  [[ "${body//$'\r'/}" == 'ok' ]]; then
  write_state 0
  log "OK: $HEALTH_URL returned 200 ok; consecutive_failures=0"
  exit 0
fi

failures=$((failures + 1))
write_state "$failures"
warn "$HEALTH_URL failed; consecutive_failures=$failures/$FAILURE_THRESHOLD"

if (( failures >= FAILURE_THRESHOLD )); then
  warn "failure threshold reached; validating and reloading nginx"
  if nginx -t; then
    systemctl reload nginx
    warn 'nginx reload completed after three consecutive health failures'
  else
    warn 'nginx configuration test failed; nginx was not reloaded'
  fi
  write_state 0
fi

exit 1
