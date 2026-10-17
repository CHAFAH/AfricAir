#!/usr/bin/env bash
# publish-s3.sh — publish AfricAir dist/ to S3 + invalidate CloudFront
# Usage: scripts/ops/publish-s3.sh <dist-dir> <bucket> <distribution-id>
#
# Upload order matters:
#   1. assets/ first (immutable, hashed filenames — safe to cache forever)
#   2. index.html + version.json last (no-cache — must point to new assets)
#   3. --delete only after new index.html is live (avoids serving index.html
#      that references assets already deleted)
#
# Invalidation: only /index.html and /version.json, never /* because:
#   - assets/ filenames are content-hashed — old URLs never change content
#   - /* invalidation is expensive and unnecessary for immutable assets
set -Eeuo pipefail

trap 'echo "ERROR: publish-s3.sh failed at line $LINENO" >&2' ERR

[[ $# -ne 3 ]] && { echo "Usage: $0 <dist-dir> <bucket> <distribution-id>" >&2; exit 1; }

DIST_DIR="$1"
BUCKET="$2"
DISTRIBUTION_ID="$3"

[[ ! -d "$DIST_DIR" ]] && { echo "ERROR: dist dir not found: $DIST_DIR" >&2; exit 1; }

log() { echo "[publish-s3] $*"; }

# Step 1: sync assets/ with immutable cache headers
log "Syncing assets/..."
aws s3 sync "$DIST_DIR/assets/" "s3://$BUCKET/assets/" \
  --cache-control "public,max-age=31536000,immutable" \
  --no-cli-pager

# Step 2: upload index.html and version.json with no-cache
log "Uploading index.html and version.json..."
aws s3 cp "$DIST_DIR/index.html" "s3://$BUCKET/index.html" \
  --cache-control "no-cache,no-store,must-revalidate" \
  --content-type "text/html" \
  --no-cli-pager

aws s3 cp "$DIST_DIR/version.json" "s3://$BUCKET/version.json" \
  --cache-control "no-cache,no-store,must-revalidate" \
  --content-type "application/json" \
  --no-cli-pager

# Step 3: delete stale files only after new index.html is live
log "Removing stale files..."
aws s3 sync "$DIST_DIR/" "s3://$BUCKET/" \
  --delete \
  --exclude "assets/*" \
  --exclude "index.html" \
  --exclude "version.json" \
  --no-cli-pager

# Step 4: invalidate only index.html and version.json
log "Invalidating CloudFront cache..."
aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/index.html" "/version.json" \
  --no-cli-pager | jq '{InvalidationId: .Invalidation.Id, Status: .Invalidation.Status}'

log "Publish complete."
