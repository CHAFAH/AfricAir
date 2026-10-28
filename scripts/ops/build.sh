#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ops/build.sh [-o OUT_DIR] [-r REPO_URL] <git-ref>

Builds a reproducible AfricAir release from <git-ref> (branch, tag or commit SHA) in a fresh
temporary directory and writes two artifacts, each with a .sha256 checksum file:

  OUT_DIR/africair-<shortsha>.tar.gz       front end: the contents of dist/, including version.json
  OUT_DIR/africair-api-<shortsha>.tar.gz   API: dist/, migrations/, package.json and production-only node_modules

Options:
  -o OUT_DIR    where to write the artifacts (default: ./artifacts)
  -r REPO_URL   repository to clone (default: the origin of this checkout)
  -h            show this help

Environment:
  KEEP_BUILD_DIR=1   keep the temporary build directory for debugging

Exit codes:
  0    success
  1    usage error or missing tool
  10   clone or checkout failed
  20   pnpm install failed
  30   type check or tests failed
  40   build or packaging failed
EOF
}

OUT_DIR=./artifacts
REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo https://github.com/CHAFAH/AfricAir.git)
while getopts ':o:r:h' opt; do
  case $opt in
    o) OUT_DIR=$OPTARG ;;
    r) REPO_URL=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || { usage >&2; exit 1; }
REF=$1

require_cmd git jq tar node
if command -v pnpm >/dev/null 2>&1; then PNPM=(pnpm); else require_cmd corepack; PNPM=(corepack pnpm); fi

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/africair-build.XXXXXX")
cleanup() { if [[ ${KEEP_BUILD_DIR:-0} == 1 ]]; then log "build directory kept: $WORK"; else rm -rf "${WORK:?}"; fi; }
trap cleanup EXIT

# --- checkout (10) ------------------------------------------------------------------------------
log "cloning $REPO_URL"
git clone --quiet --no-checkout "$REPO_URL" "$WORK/src" || die 10 "clone of $REPO_URL failed"
cd "$WORK/src"
COMMIT=$(git rev-parse --verify --quiet "${REF}^{commit}" || git rev-parse --verify --quiet "origin/${REF}^{commit}") \
  || die 10 "ref not found: $REF"
git checkout --quiet --detach "$COMMIT" || die 10 "checkout of $COMMIT failed"
SHORT=${COMMIT:0:7}
log "building $REF at $COMMIT"

export CI=true
# macOS bsdtar would add AppleDouble "._*" files and xattrs; neither belongs in a Linux artifact.
export COPYFILE_DISABLE=1
# --- install (20) -------------------------------------------------------------------------------
"${PNPM[@]}" install --frozen-lockfile || die 20 "pnpm install failed"

# --- quality gates (30) -------------------------------------------------------------------------
"${PNPM[@]}" check || die 30 "type check failed"
"${PNPM[@]}" test || die 30 "tests failed"

# --- build and package (40) ---------------------------------------------------------------------
"${PNPM[@]}" build || die 40 "front-end build failed"
"${PNPM[@]}" build:api || die 40 "API build failed"

jq -n \
  --arg commit "$COMMIT" \
  --arg ref "$REF" \
  --arg builtAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg builtBy "${USER:-$(id -un)}@$(hostname)" \
  --arg nodeVersion "$(node --version)" \
  '{commit: $commit, ref: $ref, builtAt: $builtAt, builtBy: $builtBy, nodeVersion: $nodeVersion}' \
  >dist/version.json || die 40 "could not write version.json"

WEB_ARTIFACT=$OUT_DIR/africair-$SHORT.tar.gz
tar --no-xattrs -C dist -czf "$WEB_ARTIFACT" . || die 40 "packaging the front end failed"

# Production-only dependencies of @africair/api (no TypeScript, Vite or React). `pnpm deploy` packs the
# package like `npm pack`, which skips git-ignored paths, so dist/ is copied explicitly. It needs
# `injectWorkspacePackages: true` (pnpm-workspace.yaml); `--legacy` would also pull in the root dependencies.
API_DIR=$WORK/api
"${PNPM[@]}" --filter @africair/api deploy --prod "$API_DIR" >/dev/null || die 40 "pnpm deploy failed"
rm -rf "${API_DIR:?}/src" "${API_DIR:?}/migrations" "$API_DIR"/tsconfig*.json "$API_DIR/.env.example"
cp -R server/dist server/migrations "$API_DIR/" || die 40 "copying the API build failed"
cp dist/version.json "$API_DIR/version.json"
printf 'GIT_SHA=%s\n' "$COMMIT" >"$API_DIR/build.env" # read by africair-api.service after /etc/africair/api.env
API_ARTIFACT=$OUT_DIR/africair-api-$SHORT.tar.gz
tar --no-xattrs -C "$API_DIR" -czf "$API_ARTIFACT" . || die 40 "packaging the API failed"

for artifact in "$WEB_ARTIFACT" "$API_ARTIFACT"; do
  (cd "$OUT_DIR" && sha256 "$(basename "$artifact")" >"$(basename "$artifact").sha256")
done

log "built $COMMIT"
printf '%s\n' "$WEB_ARTIFACT" "$API_ARTIFACT"
