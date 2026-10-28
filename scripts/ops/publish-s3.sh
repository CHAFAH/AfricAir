#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ops/publish-s3.sh <dist-dir> <bucket> <distribution-id>

Publishes a built dist/ to a private S3 bucket behind CloudFront, in an order that never serves
an index.html whose assets are missing:

  1. assets/ first, Cache-Control "public,max-age=31536000,immutable" (hashed names never change);
  2. other top-level files (icons, manifests), short cache;
  3. version.json, then index.html, with "no-cache": from this moment users load the new release;
  4. only then delete objects that are not in this build (versioning keeps them recoverable);
  5. invalidate only /index.html, /version.json and / (the default root object is cached under "/").

Requires the AWS CLI with credentials limited to deploy/iam/deployer-policy.json.
EOF
}
[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -eq 3 ]] || { usage >&2; exit 1; }
DIST=${1%/}
BUCKET=$2
DISTRIBUTION_ID=$3
require_cmd aws jq
[[ -f $DIST/index.html && -d $DIST/assets ]] || die 1 "$DIST does not look like a build (index.html, assets/)"
[[ -f $DIST/version.json ]] || log "warning: $DIST/version.json missing (build with scripts/ops/build.sh)"

IMMUTABLE='public,max-age=31536000,immutable'
s3() { aws s3 "$@" --only-show-errors; }

log "1/5 assets -> s3://$BUCKET/assets/"
s3 sync "$DIST/assets" "s3://$BUCKET/assets" --cache-control "$IMMUTABLE"

log "2/5 other static files"
s3 sync "$DIST" "s3://$BUCKET" --exclude 'assets/*' --exclude index.html --exclude version.json \
  --cache-control 'public,max-age=300'

log "3/5 version.json and index.html (no-cache)"
if [[ -f $DIST/version.json ]]; then
  s3 cp "$DIST/version.json" "s3://$BUCKET/version.json" --cache-control no-cache --content-type application/json
fi
s3 cp "$DIST/index.html" "s3://$BUCKET/index.html" --cache-control no-cache --content-type 'text/html; charset=utf-8'

log "4/5 removing objects that are not part of this build"
local_keys=$(cd "$DIST" && find . -type f | sed 's|^\./||' | sort)
remote_keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].Key' --output json | jq -r '.[]?' | sort)
stale=$(comm -13 <(printf '%s\n' "$local_keys") <(printf '%s\n' "$remote_keys") | sed '/^$/d')
if [[ -n $stale ]]; then
  while IFS= read -r key; do
    s3 rm "s3://$BUCKET/$key"
    log "deleted $key"
  done <<<"$stale"
else
  log "nothing stale"
fi

log "5/5 invalidating /index.html /version.json /"
invalidation=$(aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" \
  --paths /index.html /version.json / --query Invalidation.Id --output text)
log "invalidation $invalidation created (aws cloudfront wait invalidation-completed --distribution-id $DISTRIBUTION_ID --id $invalidation)"
