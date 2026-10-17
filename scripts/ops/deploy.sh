#!/usr/bin/env bash
# deploy.sh — zero-downtime deployment for AfricAir
# Usage: sudo ./deploy.sh <artifact.tar.gz>
#        sudo ./deploy.sh --help
#
# Atomicity note: plain `ln -sfn` is not atomic because it first removes the
# existing symlink and then creates a new one — a window exists where `current`
# is missing. Using a temp link + `mv -T` replaces the symlink in a single
# syscall (rename(2)), which is atomic on Linux.
set -Eeuo pipefail

trap 'echo "ERROR: deploy.sh failed at line $LINENO" >&2' ERR

RELEASES_DIR="/opt/africair/releases"
CURRENT_LINK="/opt/africair/current"
KEEP_RELEASES=5
HEALTHZ_URL="http://127.0.0.1/healthz"
VERSION_URL="http://127.0.0.1/version.json"

log()  { echo "[deploy] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "${1:-}" == "--help" ]] && { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[[ $# -lt 1 ]] && { echo "Usage: $0 <artifact.tar.gz>" >&2; exit 1; }
[[ $EUID -ne 0 ]] && { echo "ERROR: must run as root" >&2; exit 1; }

ARTIFACT="$1"
CHECKSUM_FILE="${ARTIFACT}.sha256"

# --- verify checksum ---------------------------------------------------------
[[ -f "$ARTIFACT" ]]      || fail "artifact not found: $ARTIFACT"
[[ -f "$CHECKSUM_FILE" ]] || fail "checksum file not found: $CHECKSUM_FILE"

log "Verifying checksum..."
sha256sum --check "$CHECKSUM_FILE" || fail "checksum mismatch — aborting"

# --- extract release ---------------------------------------------------------
COMMIT=$(tar -xzf "$ARTIFACT" --to-stdout dist/version.json 2>/dev/null | jq -r '.commit' || echo "unknown")
SHORT_SHA="${COMMIT:0:7}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE_DIR="$RELEASES_DIR/${TIMESTAMP}-${SHORT_SHA}"

log "Extracting to $RELEASE_DIR..."
mkdir -p "$RELEASE_DIR"
tar -xzf "$ARTIFACT" -C "$RELEASE_DIR"
chown -R africair:africair "$RELEASE_DIR"

# --- atomic symlink switch ---------------------------------------------------
PREV_RELEASE="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
TEMP_LINK="${CURRENT_LINK}.next"

log "Switching current symlink atomically..."
ln -sfn "$RELEASE_DIR" "$TEMP_LINK"
mv -T "$TEMP_LINK" "$CURRENT_LINK"

# --- nginx reload ------------------------------------------------------------
log "Testing nginx config..."
nginx -t || { mv -T <(ln -sfn "$PREV_RELEASE" /dev/stdin) "$CURRENT_LINK"; fail "nginx config test failed — rolled back"; }
nginx -s reload
log "nginx reloaded"

# --- health check ------------------------------------------------------------
sleep 2
log "Checking /healthz..."
curl -fsS "$HEALTHZ_URL" || {
  log "Health check failed — rolling back to $PREV_RELEASE"
  ln -sfn "$PREV_RELEASE" "$TEMP_LINK"
  mv -T "$TEMP_LINK" "$CURRENT_LINK"
  nginx -s reload
  fail "health check failed — rolled back"
}

log "Checking /version.json commit..."
DEPLOYED_COMMIT="$(curl -fsS "$VERSION_URL" | jq -r '.commit')"
if [[ "$DEPLOYED_COMMIT" != "$COMMIT" ]]; then
  log "Commit mismatch (expected $COMMIT, got $DEPLOYED_COMMIT) — rolling back"
  ln -sfn "$PREV_RELEASE" "$TEMP_LINK"
  mv -T "$TEMP_LINK" "$CURRENT_LINK"
  nginx -s reload
  fail "commit mismatch — rolled back"
fi

# --- prune old releases ------------------------------------------------------
log "Pruning old releases (keeping $KEEP_RELEASES)..."
ls -1dt "$RELEASES_DIR"/*/ | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -rf

log "Deploy complete: $SHORT_SHA -> $RELEASE_DIR"
