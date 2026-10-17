#!/usr/bin/env bash
# healthcheck.sh — checks AfricAir health endpoint every run
# Tracks consecutive failures in /var/lib/africair/healthcheck_failures
# After 3 consecutive failures: reloads nginx and logs WARNING
set -Eeuo pipefail

STATE_DIR=/var/lib/africair
FAIL_FILE=$STATE_DIR/healthcheck_failures
HEALTHZ_URL=http://127.0.0.1/healthz
TAG=africair-health

mkdir -p "$STATE_DIR"

log()  { logger -t "$TAG" "$*"; }
warn() { logger -t "$TAG" "WARNING: $*"; }

if curl -fsS --max-time 5 "$HEALTHZ_URL" > /dev/null 2>&1; then
    echo 0 > "$FAIL_FILE"
    log "OK: health check passed"
    exit 0
fi

# Increment failure count
failures=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
failures=$(( failures + 1 ))
echo "$failures" > "$FAIL_FILE"
log "FAIL: health check failed (consecutive failures: $failures)"

if (( failures >= 3 )); then
    warn "3 consecutive failures — reloading nginx"
    systemctl reload nginx
    echo 0 > "$FAIL_FILE"
fi
