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

if (( EUID != 0 )); then
  printf 'ERROR: rollback.sh must run as root.\n' >&2
  printf 'Usage: sudo %s\n' "$0" >&2
  exit 1
fi

current_target="$(readlink -f -- "$CURRENT_LINK" 2>/dev/null || true)"
current_name="$(basename -- "$current_target")"

mapfile -t releases < <(
  find "$RELEASES_DIR" -mindepth 2 -maxdepth 2 -type f -name .healthy \
    -printf '%h\n' |
    xargs -r -n1 basename |
    sort -r
)

previous=''
found_current=false
for release in "${releases[@]}"; do
  if [[ "$found_current" == true ]]; then
    previous="$release"
    break
  fi
  if [[ "$release" == "$current_name" ]]; then
    found_current=true
  fi
done

if [[ -z "$previous" ]]; then
  printf 'ERROR: no previous healthy release is available.\n' >&2
  exit 2
fi

previous_dir="$RELEASES_DIR/$previous"
next_link="$ROOT_DIR/.current.rollback.$$"
ln -sfn "$previous_dir" "$next_link"
mv -Tf "$next_link" "$CURRENT_LINK"

nginx -t
systemctl reload nginx

printf 'Rolled back from %s to %s\n' "$current_name" "$previous"
printf 'Current: %s\n' "$(readlink -f -- "$CURRENT_LINK")"
