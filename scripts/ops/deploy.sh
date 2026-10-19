#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local exit_code=$?
  printf 'ERROR: line %s: command failed with exit code %s\n' \
    "${BASH_LINENO[0]}" "$exit_code" >&2
  exit "$exit_code"
}
trap on_error ERR

ROOT_DIR=/opt/africair
RELEASES_DIR="$ROOT_DIR/releases"
CURRENT_LINK="$ROOT_DIR/current"

usage() {
  printf 'Usage: sudo %s <web-artifact.tar.gz> [api-artifact.tar.gz]\n' "$0"
}

if (( EUID != 0 )); then
  printf 'ERROR: deploy.sh must run as root.\n' >&2
  usage >&2
  exit 1
fi

if (( $# < 1 || $# > 2 )); then
  usage >&2
  exit 2
fi

for command in curl jq nginx sha256sum tar; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$command" >&2
    exit 2
  fi
done

artifact="$(readlink -f -- "$1")"
api_artifact=""
if (( $# == 2 )); then
  api_artifact="$(readlink -f -- "$2")"
fi
checksum_file="${artifact}.sha256"

if [[ ! -f "$artifact" ]]; then
  printf 'ERROR: artifact not found: %s\n' "$artifact" >&2
  exit 2
fi
if [[ ! -f "$checksum_file" ]]; then
  printf 'ERROR: checksum file not found: %s\n' "$checksum_file" >&2
  exit 2
fi

printf 'Verifying %s\n' "$(basename -- "$artifact")"
if ! (cd "$(dirname -- "$artifact")" && sha256sum -c "$(basename -- "$checksum_file")"); then
  printf 'ERROR: artifact checksum verification failed.\n' >&2
  exit 3
fi

if tar -tzf "$artifact" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  printf 'ERROR: artifact contains an unsafe path.\n' >&2
  exit 4
fi

version_json="$(tar -xOf "$artifact" ./version.json 2>/dev/null || true)"
if ! jq -e '.commit | strings | test("^[0-9a-f]{40}$")' >/dev/null <<<"$version_json"; then
  printf 'ERROR: artifact version.json has no valid commit SHA.\n' >&2
  exit 4
fi

expected_commit="$(jq -r '.commit' <<<"$version_json")"
short_sha="${expected_commit:0:7}"
release_id="$(date -u +'%Y%m%dT%H%M%SZ')-${short_sha}"
release_dir="$RELEASES_DIR/$release_id"
staging_dir="$RELEASES_DIR/.${release_id}.staging"
previous_target="$(readlink -f -- "$CURRENT_LINK" 2>/dev/null || true)"

if [[ -e "$release_dir" || -e "$staging_dir" ]]; then
  printf 'ERROR: release path already exists: %s\n' "$release_id" >&2
  exit 4
fi

rollback_failed_deploy() {
  local reason=$1
  printf 'ERROR: %s; rolling back.\n' "$reason" >&2

  if [[ -n "$previous_target" && -d "$previous_target" ]]; then
    local rollback_link="$ROOT_DIR/.current.rollback.$$"
    ln -sfn "$previous_target" "$rollback_link"
    mv -Tf "$rollback_link" "$CURRENT_LINK"
    if nginx -t; then
      systemctl reload nginx
    fi
    printf 'Rolled back to %s\n' "$previous_target" >&2
  else
    printf 'WARNING: no previous release was available for rollback.\n' >&2
  fi
  exit 5
}

install -d -o africair -g africair -m 0755 "$RELEASES_DIR"
install -d -o africair -g africair -m 0755 "$staging_dir"
tar -xzf "$artifact" -C "$staging_dir"
chown -R africair:africair "$staging_dir"
mv -T "$staging_dir" "$release_dir"

if [[ ! -f "$release_dir/index.html" || ! -f "$release_dir/version.json" ]]; then
  rollback_failed_deploy 'release is missing index.html or version.json'
fi

next_link="$ROOT_DIR/.current.next.$$"
ln -sfn "$release_dir" "$next_link"
mv -Tf "$next_link" "$CURRENT_LINK"

if ! nginx -t; then
  rollback_failed_deploy 'nginx configuration test failed'
fi
systemctl reload nginx

if ! health_body="$(curl --fail --silent --show-error http://127.0.0.1/healthz)"; then
  rollback_failed_deploy '/healthz request failed'
fi
if [[ "${health_body//$'\r'/}" != 'ok' ]]; then
  rollback_failed_deploy "/healthz returned unexpected content: $health_body"
fi

if ! live_version="$(curl --fail --silent --show-error http://127.0.0.1/version.json)"; then
  rollback_failed_deploy '/version.json request failed'
fi
live_commit="$(jq -r '.commit // empty' <<<"$live_version")"
if [[ "$live_commit" != "$expected_commit" ]]; then
  rollback_failed_deploy "deployed commit $live_commit does not match $expected_commit"
fi

touch "$release_dir/.healthy"
chown africair:africair "$release_dir/.healthy"

mapfile -t old_releases < <(
  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d \
    -printf '%f\n' |
    grep -E '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7}$' |
    sort -r |
    tail -n +6 || true
)

for old_release in "${old_releases[@]}"; do
  printf 'Removing old release %s\n' "$old_release"
  rm -rf -- "${RELEASES_DIR:?}/$old_release"
done

printf 'Deployment successful: %s\n' "$release_id"
printf 'Commit: %s\n' "$expected_commit"
printf 'Current: %s\n' "$(readlink -f -- "$CURRENT_LINK")"

if [[ -n "$api_artifact" ]]; then
  api_checksum_file="${api_artifact}.sha256"
  if [[ ! -f "$api_artifact" || ! -f "$api_checksum_file" ]]; then
    printf 'ERROR: API artifact or checksum not found.\n' >&2
    exit 6
  fi
  if ! (cd "$(dirname -- "$api_artifact")" && sha256sum -c "$(basename -- "$api_checksum_file")"); then
    printf 'ERROR: API artifact checksum verification failed.\n' >&2
    exit 6
  fi
  if tar -tzf "$api_artifact" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    printf 'ERROR: API artifact contains an unsafe path.\n' >&2
    exit 6
  fi

  api_version_json="$(tar -xOf "$api_artifact" version.json 2>/dev/null || tar -xOf "$api_artifact" ./version.json 2>/dev/null || true)"
  if ! jq -e '.commit | strings | test("^[0-9a-f]{40}$")' >/dev/null <<<"$api_version_json"; then
    printf 'ERROR: API artifact version.json has no valid commit SHA.\n' >&2
    exit 6
  fi

  api_commit="$(jq -r '.commit' <<<"$api_version_json")"
  api_release_id="$(date -u +'%Y%m%dT%H%M%SZ')-${api_commit:0:7}"
  api_root="$ROOT_DIR/api"
  api_releases="$api_root/releases"
  api_current="$api_root/current"
  api_release="$api_releases/$api_release_id"
  api_staging="$api_releases/.${api_release_id}.staging"
  api_previous="$(readlink -f -- "$api_current" 2>/dev/null || true)"

  install -d -o africair -g africair -m 0755 "$api_releases" "$api_staging"
  tar -xzf "$api_artifact" -C "$api_staging"
  if [[ ! -f "$api_staging/server/dist/index.js" || ! -d "$api_staging/server/node_modules" ]]; then
    rm -rf -- "$api_staging"
    printf 'ERROR: API artifact is missing its application or production dependencies.\n' >&2
    exit 6
  fi
  chown -R africair:africair "$api_staging"
  mv -T "$api_staging" "$api_release"
  api_next="$api_root/.current.next.$$"
  ln -sfn "$api_release" "$api_next"
  mv -Tf "$api_next" "$api_current"

  if ! systemctl start africair-api-migrate.service || ! systemctl restart africair-api.service; then
    if [[ -n "$api_previous" && -d "$api_previous" ]]; then
      api_rollback="$api_root/.current.rollback.$$"
      ln -sfn "$api_previous" "$api_rollback"
      mv -Tf "$api_rollback" "$api_current"
      systemctl restart africair-api.service || true
    fi
    printf 'ERROR: API migration or service startup failed; API release rolled back.\n' >&2
    exit 7
  fi

  if ! curl --fail --silent --show-error --retry 10 --retry-delay 1 --retry-connrefused \
    http://127.0.0.1:4000/api/readyz >/dev/null; then
    if [[ -n "$api_previous" && -d "$api_previous" ]]; then
      api_rollback="$api_root/.current.rollback.$$"
      ln -sfn "$api_previous" "$api_rollback"
      mv -Tf "$api_rollback" "$api_current"
      systemctl restart africair-api.service || true
    fi
    printf 'ERROR: API readiness check failed; API release rolled back.\n' >&2
    exit 7
  fi

  touch "$api_release/.healthy"
  chown africair:africair "$api_release/.healthy"
  mapfile -t old_api_releases < <(
    find "$api_releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
      grep -E '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7}$' | sort -r | tail -n +6 || true
  )
  for old_api_release in "${old_api_releases[@]}"; do
    rm -rf -- "${api_releases:?}/$old_api_release"
  done
  printf 'API deployment successful: %s\n' "$api_release_id"
fi
