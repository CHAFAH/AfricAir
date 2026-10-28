#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: sudo scripts/ops/deploy.sh [--no-api] <africair-SHA.tar.gz> [africair-api-SHA.tar.gz]

Zero-downtime release of artifacts produced by build.sh:
  1. verifies each artifact against its .sha256 file (abort, nothing changed, on mismatch);
  2. extracts to /opt/africair/releases/<UTC-timestamp>-<sha>/ owned by africair;
  3. switches /opt/africair/current atomically (temporary symlink + mv -T);
  4. runs `nginx -t`, then reloads nginx (never restarts it);
  5. checks /healthz and that /version.json reports the expected commit, rolling back automatically
     and exiting non-zero if not;
  6. keeps the KEEP_RELEASES most recent releases.

The API artifact (next to the web artifact, or given explicitly) is installed the same way under
/opt/africair/api/: migrations run through africair-migrate.service, then africair-api.service is
restarted and /api/readyz plus /api/config .commit are verified, with the same automatic rollback.

Environment: AFRICAIR_ROOT (/opt/africair), BASE_URL (http://127.0.0.1), KEEP_RELEASES (5)

Exit codes: 1 usage, 2 checksum mismatch, 3 web verification failed (rolled back),
            4 API migration or verification failed (rolled back)
EOF
}

WITH_API=1
args=()
for arg in "$@"; do
  case $arg in
    -h | --help) usage; exit 0 ;;
    --no-api) WITH_API=0 ;;
    *) args+=("$arg") ;;
  esac
done
[[ ${#args[@]} -ge 1 && ${#args[@]} -le 2 ]] || { usage >&2; exit 1; }
require_root
require_cmd tar jq curl nginx systemctl

ROOT=${AFRICAIR_ROOT:-/opt/africair}
BASE_URL=${BASE_URL:-http://127.0.0.1}
KEEP_RELEASES=${KEEP_RELEASES:-5}
WEB_ARTIFACT=${args[0]}
[[ -f $WEB_ARTIFACT ]] || die 1 "artifact not found: $WEB_ARTIFACT"
if [[ ${#args[@]} -eq 2 ]]; then
  API_ARTIFACT=${args[1]}
else
  API_ARTIFACT=$(dirname "$WEB_ARTIFACT")/$(basename "$WEB_ARTIFACT" | sed 's/^africair-/africair-api-/')
fi
[[ $WITH_API == 1 && ! -f $API_ARTIFACT ]] && { log "no API artifact at $API_ARTIFACT: deploying the front end only"; WITH_API=0; }

# --- 1. checksums before anything is touched ----------------------------------------------------
verify_checksum "$WEB_ARTIFACT" || die 2 "checksum mismatch or missing .sha256 for $WEB_ARTIFACT: nothing changed"
if ((WITH_API)); then
  verify_checksum "$API_ARTIFACT" || die 2 "checksum mismatch or missing .sha256 for $API_ARTIFACT: nothing changed"
fi

COMMIT=$(tar -xzOf "$WEB_ARTIFACT" ./version.json | jq -er .commit) || die 1 "artifact has no version.json"
RELEASE_ID="$(date -u +%Y%m%dT%H%M%SZ)-${COMMIT:0:7}"

# extract <artifact> <releases-dir>: unpack into a hidden directory, then rename into place,
# so a half-extracted release is never visible under its final name.
extract() {
  local artifact=$1 releases=$2 tmp
  tmp="$releases/.incoming-$RELEASE_ID"
  rm -rf "${tmp:?}"
  mkdir -p "$tmp"
  tar -xzf "$artifact" -C "$tmp" --no-same-owner
  chown -R africair:africair "$tmp"
  chmod -R u=rwX,go=rX "$tmp"
  mv -T "$tmp" "$releases/$RELEASE_ID"
}

# prune <releases-dir> <current-id>: delete everything except the newest KEEP_RELEASES (never the current one).
prune() {
  local releases=$1 current=$2 old
  mapfile -t old < <(find "$releases" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort | head -n "-$KEEP_RELEASES")
  for r in "${old[@]}"; do
    [[ -n $r && $r != "$current" ]] || continue
    rm -rf "${releases:?}/${r:?}"
    log "pruned release $r"
  done
}

reload_nginx() { nginx -t -q && systemctl reload nginx; }

# --- 2-5. front end -----------------------------------------------------------------------------
PREVIOUS_WEB=$(readlink "$ROOT/current" 2>/dev/null || true)
extract "$WEB_ARTIFACT" "$ROOT/releases"
switch_symlink "$ROOT/current" "releases/$RELEASE_ID"
reload_nginx || {
  [[ -n $PREVIOUS_WEB ]] && switch_symlink "$ROOT/current" "$PREVIOUS_WEB"
  die 3 "nginx -t failed: restored $PREVIOUS_WEB"
}

served=$(curl -fsS -m 5 "$BASE_URL/version.json" | jq -r .commit || true)
if ! curl -fsS -m 5 "$BASE_URL/healthz" >/dev/null || [[ $served != "$COMMIT" ]]; then
  if [[ -n $PREVIOUS_WEB ]]; then
    switch_symlink "$ROOT/current" "$PREVIOUS_WEB"
    reload_nginx
  fi
  die 3 "verification failed (served commit '${served:-none}', expected $COMMIT): rolled back to ${PREVIOUS_WEB:-nothing}"
fi
log "front end live: $RELEASE_ID"

# --- API ----------------------------------------------------------------------------------------
if ((WITH_API)); then
  mkdir -p "$ROOT/api/releases"
  PREVIOUS_API=$(readlink "$ROOT/api/current" 2>/dev/null || true)
  extract "$API_ARTIFACT" "$ROOT/api/releases"
  switch_symlink "$ROOT/api/current" "releases/$RELEASE_ID"

  # wait_ready: up to 30 s for /api/readyz to return 200
  wait_ready() {
    local _
    for _ in $(seq 30); do
      curl -fsS -m 2 "$BASE_URL/api/readyz" >/dev/null 2>&1 && return 0
      sleep 1
    done
    return 1
  }

  rollback_api() {
    if [[ -n $PREVIOUS_API ]]; then
      switch_symlink "$ROOT/api/current" "$PREVIOUS_API"
      # A crash-looping release can trip systemd's start limit, which would refuse the restart.
      systemctl reset-failed africair-api.service 2>/dev/null || true
      systemctl restart africair-api.service || true
      if wait_ready; then log "previous API release is ready"; else log "WARNING: previous API release is not ready either"; fi
    else
      rm -f "$ROOT/api/current" # first deploy: leave no link to a release that never worked
      systemctl stop africair-api.service || true
    fi
    die 4 "$1: API rolled back to ${PREVIOUS_API:-nothing}"
  }

  # Migrations are forward-only and idempotent; they run before the new code serves traffic.
  systemctl start africair-migrate.service || rollback_api "migrations failed (journalctl -u africair-migrate)"
  systemctl restart africair-api.service || rollback_api "africair-api failed to start"
  wait_ready || rollback_api "/api/readyz did not return 200 within 30s"
  api_commit=$(curl -fsS -m 5 "$BASE_URL/api/config" | jq -r .commit || true)
  [[ $api_commit == "$COMMIT" ]] || rollback_api "/api/config reports commit '${api_commit:-none}', expected $COMMIT"
  log "API live: $RELEASE_ID"
  prune "$ROOT/api/releases" "$RELEASE_ID"
fi

prune "$ROOT/releases" "$RELEASE_ID"
log "deployed $COMMIT as $RELEASE_ID"
