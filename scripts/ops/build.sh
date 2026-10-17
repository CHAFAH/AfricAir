#!/usr/bin/env bash
# build.sh — reproducible build artifact for AfricAir
# Usage: ./build.sh <git-ref>
#        ./build.sh --help
#
# Exit codes:
#   0  success
#   1  usage error
#  10  checkout failure
#  20  pnpm install failure
#  30  test/check failure
#  40  build failure
set -Eeuo pipefail

trap 'echo "ERROR: build.sh failed at line $LINENO" >&2' ERR

REPO_URL="https://github.com/engineerkg/AfricAir.git"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/africair-artifacts}"

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

log() { echo "[build] $*"; }

[[ "${1:-}" == "--help" ]] && usage
[[ $# -lt 1 ]] && { echo "Usage: $0 <git-ref>" >&2; exit 1; }

GIT_REF="$1"
BUILD_DIR="$(mktemp -d /tmp/africair-build-XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# --- checkout ----------------------------------------------------------------
log "Cloning $REPO_URL at ref $GIT_REF..."
git clone --quiet "$REPO_URL" "$BUILD_DIR" || { echo "ERROR: git clone failed" >&2; exit 10; }
git -C "$BUILD_DIR" checkout "$GIT_REF"    || { echo "ERROR: git checkout $GIT_REF failed" >&2; exit 10; }

COMMIT="$(git -C "$BUILD_DIR" rev-parse HEAD)"
SHORT_SHA="$(git -C "$BUILD_DIR" rev-parse --short HEAD)"
log "Checked out $COMMIT"

# --- install -----------------------------------------------------------------
log "Installing dependencies..."
(cd "$BUILD_DIR" && pnpm install --frozen-lockfile) || { echo "ERROR: pnpm install failed" >&2; exit 20; }

# --- check + test ------------------------------------------------------------
log "Running TypeScript check..."
(cd "$BUILD_DIR" && pnpm check) || { echo "ERROR: pnpm check failed" >&2; exit 30; }

log "Running unit tests..."
(cd "$BUILD_DIR" && pnpm test --run) || { echo "ERROR: pnpm test failed" >&2; exit 30; }

# --- build -------------------------------------------------------------------
log "Building frontend..."
(cd "$BUILD_DIR" && pnpm build) || { echo "ERROR: pnpm build failed" >&2; exit 40; }

log "Building API..."
(cd "$BUILD_DIR" && pnpm build:api) || { echo "ERROR: pnpm build:api failed" >&2; exit 40; }

# --- version.json ------------------------------------------------------------
jq -n \
  --arg commit    "$COMMIT" \
  --arg ref       "$GIT_REF" \
  --arg builtAt   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg builtBy   "$(whoami)@$(hostname)" \
  --arg nodeVersion "$(node --version)" \
  '{ commit: $commit, ref: $ref, builtAt: $builtAt, builtBy: $builtBy, nodeVersion: $nodeVersion }' \
  > "$BUILD_DIR/dist/version.json"

log "version.json written"

# --- package frontend artifact -----------------------------------------------
mkdir -p "$OUTPUT_DIR"
ARTIFACT="$OUTPUT_DIR/africair-${SHORT_SHA}.tar.gz"

tar -czf "$ARTIFACT" -C "$BUILD_DIR" dist

sha256sum "$ARTIFACT" > "${ARTIFACT}.sha256"
log "Frontend artifact: $ARTIFACT"

# --- package API artifact ----------------------------------------------------
# Install production-only dependencies into server/
(cd "$BUILD_DIR/server" && npm install --omit=dev --legacy-peer-deps --quiet)

API_ARTIFACT="$OUTPUT_DIR/africair-api-${SHORT_SHA}.tar.gz"

tar -czf "$API_ARTIFACT" \
  -C "$BUILD_DIR" \
  server/dist \
  server/migrations \
  server/package.json \
  server/node_modules

sha256sum "$API_ARTIFACT" > "${API_ARTIFACT}.sha256"
log "API artifact:      $API_ARTIFACT"

log "Build complete for $SHORT_SHA"
