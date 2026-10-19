#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; printf "ERROR: line %s: command failed with exit code %s\n" "${BASH_LINENO[0]}" "$rc" >&2; exit "$rc"' ERR

usage() {
  cat <<'EOF'
Usage: scripts/ops/build.sh <git-ref>

Clone the repository into a temporary directory, check out <git-ref>, run
the locked install and quality gates, and create these files in the current
working directory:

  africair-<shortsha>.tar.gz
  africair-<shortsha>.tar.gz.sha256

<git-ref> may be a branch, tag, or commit SHA.

Environment:
  AFRICAIR_REPO_URL  Override the Git repository URL used for the build.
  BUILD_USER         Override the value written to version.json as builtBy.

Exit codes:
  10  Repository clone, fetch, or checkout failure
  20  pnpm install failure
  30  TypeScript check or test failure
  40  Production build or artifact-generation failure
EOF
}

if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
  usage
  exit 0
fi

if (( $# != 1 )); then
  usage >&2
  exit 2
fi

for command in git node pnpm jq tar sha256sum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$command" >&2
    exit 2
  fi
done

git_ref=$1
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir/../.." rev-parse --show-toplevel)"
output_dir="$(pwd -P)"
tmp_dir="$(mktemp -d)"
checkout_dir="$tmp_dir/source"

cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

repo_url="${AFRICAIR_REPO_URL:-}"
if [[ -z "$repo_url" ]]; then
  repo_url="$(git -C "$repo_root" remote get-url submission-fork 2>/dev/null || true)"
fi
if [[ -z "$repo_url" ]]; then
  repo_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
fi
if [[ -z "$repo_url" ]]; then
  printf 'ERROR: could not determine a repository URL. Set AFRICAIR_REPO_URL.\n' >&2
  exit 10
fi

printf 'Building ref %s from %s\n' "$git_ref" "$repo_url"

if ! git clone --no-checkout --quiet "$repo_url" "$checkout_dir"; then
  printf 'ERROR: could not clone %s\n' "$repo_url" >&2
  exit 10
fi

if ! git -C "$checkout_dir" fetch --quiet origin "$git_ref"; then
  printf 'ERROR: could not fetch Git ref: %s\n' "$git_ref" >&2
  exit 10
fi

if ! git -C "$checkout_dir" checkout --quiet --detach FETCH_HEAD; then
  printf 'ERROR: could not check out Git ref: %s\n' "$git_ref" >&2
  exit 10
fi

commit="$(git -C "$checkout_dir" rev-parse HEAD)"
short_sha="$(git -C "$checkout_dir" rev-parse --short=7 HEAD)"
printf 'Checked out %s (%s)\n' "$commit" "$git_ref"

if ! (cd "$checkout_dir" && pnpm install --frozen-lockfile); then
  printf 'ERROR: dependency installation failed.\n' >&2
  exit 20
fi

if ! (cd "$checkout_dir" && pnpm check); then
  printf 'ERROR: TypeScript quality check failed.\n' >&2
  exit 30
fi

if ! (cd "$checkout_dir" && pnpm test); then
  printf 'ERROR: test suite failed.\n' >&2
  exit 30
fi

if ! (cd "$checkout_dir" && pnpm build); then
  printf 'ERROR: production build failed.\n' >&2
  exit 40
fi

built_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
built_by="${BUILD_USER:-${USER:-$(id -un)}@$(hostname)}"
node_version="$(node --version)"

if ! jq -n \
  --arg commit "$commit" \
  --arg ref "$git_ref" \
  --arg builtAt "$built_at" \
  --arg builtBy "$built_by" \
  --arg nodeVersion "$node_version" \
  '{
    commit: $commit,
    ref: $ref,
    builtAt: $builtAt,
    builtBy: $builtBy,
    nodeVersion: $nodeVersion
  }' > "$checkout_dir/dist/version.json"; then
  printf 'ERROR: could not write dist/version.json.\n' >&2
  exit 40
fi

artifact_name="africair-${short_sha}.tar.gz"
artifact="$output_dir/$artifact_name"
checksum="$artifact.sha256"

if ! tar -czf "$artifact" -C "$checkout_dir/dist" .; then
  printf 'ERROR: could not create %s.\n' "$artifact_name" >&2
  exit 40
fi

if ! (cd "$output_dir" && sha256sum "$artifact_name" > "${artifact_name}.sha256"); then
  printf 'ERROR: could not create %s.sha256.\n' "$artifact_name" >&2
  exit 40
fi

printf 'Created artifact: %s\n' "$artifact"
printf 'Created checksum: %s\n' "$checksum"
printf 'Commit: %s\n' "$commit"
