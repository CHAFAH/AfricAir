#!/usr/bin/env bash
set -Eeuo pipefail
# Installed as /usr/local/sbin/africair-healthcheck and run every minute by africair-health.timer.
# Standalone on purpose (no common.sh): the systemd unit runs this single file.

usage() {
  cat <<'EOF'
Usage: africair-healthcheck

Checks BASE_URL/healthz (and BASE_URL/api/healthz when africair-api.service is active). Logs to journald
with tag africair-health. After THRESHOLD consecutive failures (default 3) it reloads nginx, logs a
WARNING and resets the counter. The counter lives in STATE_DIR/health.failures (/var/lib/africair).
EOF
}
[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }

BASE_URL=${BASE_URL:-http://127.0.0.1}
THRESHOLD=${THRESHOLD:-3}
STATE_DIR=${STATE_DIR:-/var/lib/africair}
STATE_FILE=$STATE_DIR/health.failures
TAG=africair-health

say() { logger -t "$TAG" -p "user.$1" -- "$2"; }
trap 'say err "healthcheck script error on line $LINENO"' ERR

mkdir -p "$STATE_DIR"
failures=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
[[ $failures =~ ^[0-9]+$ ]] || failures=0

problems=()
curl -fsS -m 5 -o /dev/null "$BASE_URL/healthz" || problems+=("web /healthz")
if systemctl is-active --quiet africair-api.service; then
  curl -fsS -m 5 -o /dev/null "$BASE_URL/api/healthz" || problems+=("api /api/healthz")
fi

if ((${#problems[@]} == 0)); then
  ((failures > 0)) && say notice "recovered after $failures failed check(s)"
  echo 0 >"$STATE_FILE"
  exit 0
fi

failures=$((failures + 1))
say err "check failed ($failures/$THRESHOLD): ${problems[*]}"
if ((failures >= THRESHOLD)); then
  say warning "WARNING: $failures consecutive failures, reloading nginx"
  if nginx -t -q 2>/dev/null; then systemctl reload nginx; else say crit "nginx -t failed, not reloading"; fi
  failures=0
fi
echo "$failures" >"$STATE_FILE"
exit 1
