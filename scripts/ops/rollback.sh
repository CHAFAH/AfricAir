#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: sudo scripts/ops/rollback.sh [--web | --api | --all]

Switches `current` back to the release deployed before it, in one atomic step.
  --web   front end only (default): /opt/africair/current, then `nginx -t` and reload
  --api   API only: /opt/africair/api/current, then restart africair-api.service
  --all   both

Running it again goes one more release back. Exit codes: 1 usage, 5 no previous release.
EOF
}

TARGET=web
case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  --web | "") TARGET=web ;;
  --api) TARGET=api ;;
  --all) TARGET=all ;;
  *) usage >&2; exit 1 ;;
esac
require_root
ROOT=${AFRICAIR_ROOT:-/opt/africair}

# roll_back <base-dir>: base-dir contains current -> releases/<id>
roll_back() {
  local base=$1 link current previous
  link=$(readlink "$base/current") || die 5 "$base/current is not a symlink"
  current=$(basename "$link")
  previous=$(release_before "$base/releases" "$current") || die 5 "no release older than $current in $base/releases"
  switch_symlink "$base/current" "releases/$previous"
  log "$base/current: $current -> $previous"
}

if [[ $TARGET == web || $TARGET == all ]]; then
  roll_back "$ROOT"
  nginx -t -q
  systemctl reload nginx
fi
if [[ $TARGET == api || $TARGET == all ]]; then
  roll_back "$ROOT/api"
  systemctl restart africair-api.service
fi
