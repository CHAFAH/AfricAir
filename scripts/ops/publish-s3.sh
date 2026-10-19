#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; printf "ERROR: line %s: command failed with exit code %s\n" "${BASH_LINENO[0]}" "$rc" >&2; exit "$rc"' ERR

usage() {
  printf 'Usage: %s <dist-dir> <bucket> <distribution-id>\n' "$0"
}

if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
  usage
  exit 0
fi

if (( $# != 3 )); then
  usage >&2
  exit 2
fi

for command in aws find; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$command" >&2
    exit 2
  fi
done

dist_dir="$(cd -- "$1" 2>/dev/null && pwd -P)" || {
  printf 'ERROR: dist directory does not exist: %s\n' "$1" >&2
  exit 2
}
bucket="${2#s3://}"
bucket="${bucket%/}"
distribution_id=$3

if [[ -z "$bucket" || -z "$distribution_id" ]]; then
  printf 'ERROR: bucket and distribution ID must not be empty.\n' >&2
  exit 2
fi
if [[ ! -f "$dist_dir/index.html" || ! -f "$dist_dir/version.json" || ! -d "$dist_dir/assets" ]]; then
  printf 'ERROR: dist must contain index.html, version.json, and assets/.\n' >&2
  exit 2
fi

printf 'Publishing immutable assets to s3://%s/assets/\n' "$bucket"
aws s3 sync "$dist_dir/assets/" "s3://$bucket/assets/" \
  --cache-control 'public,max-age=31536000,immutable' \
  --only-show-errors

# Publish any additional root/static files before the entry point. They are
# deliberately excluded from the immutable assets policy.
aws s3 sync "$dist_dir/" "s3://$bucket/" \
  --exclude 'assets/*' \
  --exclude 'index.html' \
  --exclude 'version.json' \
  --cache-control 'no-cache' \
  --only-show-errors

printf 'Publishing version.json and index.html with revalidation enabled\n'
aws s3 cp "$dist_dir/version.json" "s3://$bucket/version.json" \
  --cache-control 'no-cache' \
  --content-type 'application/json' \
  --only-show-errors
aws s3 cp "$dist_dir/index.html" "s3://$bucket/index.html" \
  --cache-control 'no-cache' \
  --content-type 'text/html; charset=utf-8' \
  --only-show-errors

# Delete stale keys only after the new entry point is live. This final sync is
# expected to upload nothing because every current file was published above.
printf 'Removing stale objects after the new index is live\n'
aws s3 sync "$dist_dir/" "s3://$bucket/" --delete --only-show-errors

printf 'Invalidating only the mutable entry-point metadata\n'
# MSYS/Git Bash otherwise rewrites paths such as /index.html into Windows
# filesystem paths before aws.exe receives them.
MSYS_NO_PATHCONV=1 aws cloudfront create-invalidation \
  --distribution-id "$distribution_id" \
  --paths '/index.html' '/version.json' \
  --query 'Invalidation.{Id:Id,Status:Status}' \
  --output table

printf 'Published %s to s3://%s through distribution %s\n' \
  "$dist_dir" "$bucket" "$distribution_id"
