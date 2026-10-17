#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "Build failed at line %s (exit %s)\n" "$LINENO" "$status" >&2' ERR

usage() {
  cat <<'EOF'
Usage: scripts/ops/build.sh <git-ref>

Builds the requested Git branch, tag, or commit and writes
africair-<shortsha>.tar.gz and its .sha256 file to the current directory.

Exit codes:
  10  Checkout failed
  20  Dependency installation failed
  30  Quality checks or tests failed
  40  Production build failed
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

git_ref=$1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir/../.." rev-parse --show-toplevel)
repo_url=$(git -C "$repo_root" remote get-url origin) || {
  printf 'Could not determine the origin repository URL\n' >&2
  exit 10
}
output_dir=$(pwd)
tmp_dir=$(mktemp -d)
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

for command in git pnpm node jq tar sha256sum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

checkout_dir="$tmp_dir/source"
if ! git clone --no-checkout "$repo_url" "$checkout_dir"; then
  printf 'Could not clone %s\n' "$repo_url" >&2
  exit 10
fi
if ! git -C "$checkout_dir" fetch origin "$git_ref"; then
  printf 'Could not fetch Git ref: %s\n' "$git_ref" >&2
  exit 10
fi
if ! git -C "$checkout_dir" checkout --detach FETCH_HEAD; then
  printf 'Could not check out Git ref: %s\n' "$git_ref" >&2
  exit 10
fi

if ! (cd "$checkout_dir" && pnpm install --frozen-lockfile); then
  printf 'Dependency installation failed\n' >&2
  exit 20
fi
if ! (cd "$checkout_dir" && pnpm check && pnpm test); then
  printf 'Quality checks or tests failed\n' >&2
  exit 30
fi
if ! (cd "$checkout_dir" && pnpm build); then
  printf 'Production build failed\n' >&2
  exit 40
fi

commit=$(git -C "$checkout_dir" rev-parse HEAD)
short_sha=${commit:0:7}
built_by=$(git -C "$checkout_dir" config user.email || true)
if [[ -z "$built_by" ]]; then
  built_by="${USER:-$(id -un)}@$(hostname)"
fi

jq -n \
  --arg commit "$commit" \
  --arg ref "$git_ref" \
  --arg builtAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg builtBy "$built_by" \
  --arg nodeVersion "$(node --version)" \
  '{commit: $commit, ref: $ref, builtAt: $builtAt, builtBy: $builtBy, nodeVersion: $nodeVersion}' \
  > "$checkout_dir/dist/version.json"

artifact_name="africair-${short_sha}.tar.gz"
artifact="$output_dir/$artifact_name"
tar -czf "$artifact" -C "$checkout_dir" dist
(cd "$output_dir" && sha256sum "$artifact_name" > "${artifact_name}.sha256")
printf 'Created %s\nCreated %s.sha256\n' "$artifact" "$artifact"
