#!/usr/bin/env bash
# rollback.sh — switch current to the previous release
# Usage: sudo ./rollback.sh
set -Eeuo pipefail

trap 'echo "ERROR: rollback.sh failed at line $LINENO" >&2' ERR

RELEASES_DIR="/opt/africair/releases"
CURRENT_LINK="/opt/africair/current"

log()  { echo "[rollback] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && { echo "ERROR: must run as root" >&2; exit 1; }

CURRENT="$(readlink -f "$CURRENT_LINK")"
PREVIOUS="$(ls -1dt "$RELEASES_DIR"/*/ | grep -v "^${CURRENT}/$" | head -1 | sed 's|/$||')"

[[ -z "$PREVIOUS" ]] && fail "no previous release found"

log "Rolling back from $CURRENT to $PREVIOUS..."
TEMP_LINK="${CURRENT_LINK}.next"
ln -sfn "$PREVIOUS" "$TEMP_LINK"
mv -T "$TEMP_LINK" "$CURRENT_LINK"

nginx -t || fail "nginx config test failed"
nginx -s reload

log "Rollback complete -> $PREVIOUS"
