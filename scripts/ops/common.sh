# shellcheck shell=bash
# Shared helpers for scripts/ops/*.sh. Source it right after `set -Eeuo pipefail`:
#   . "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SCRIPT_NAME=$(basename "${BASH_SOURCE[1]:-$0}")

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCRIPT_NAME" "$*" >&2; }

# die <exit-code> <message...>
die() {
  local code=$1
  shift
  log "ERROR: $*"
  exit "$code"
}

# Print the failing line and command for any unhandled error (set -E makes this fire inside functions too).
on_error() {
  local rc=$? line=$1 cmd=$2
  log "ERROR: line ${line}: '${cmd}' exited with status ${rc}"
  exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_root() { [[ ${EUID} -eq 0 ]] || die 1 "must be run as root (use sudo)"; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die 1 "required command not found: $cmd"
  done
}

# sha256 <file> -> prints "<hash>  <file>" (GNU coreutils on Linux, shasum on macOS)
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# verify_checksum <artifact>: checks <artifact>.sha256 (written by build.sh) from the artifact's directory.
verify_checksum() {
  local artifact=$1 dir base
  dir=$(cd "$(dirname "$artifact")" && pwd)
  base=$(basename "$artifact")
  [[ -f "$dir/$base.sha256" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dir" && sha256sum --check --status "$base.sha256")
  else
    (cd "$dir" && shasum -a 256 --check --status "$base.sha256")
  fi
}

# switch_symlink <link> <target>: atomic replacement. `ln -sfn` alone unlinks and recreates the link,
# so for a moment the path does not exist; rename(2) via `mv -T` swaps it in a single step.
switch_symlink() {
  local link=$1 target=$2
  ln -sfn "$target" "$link.tmp.$$"
  mv -Tf "$link.tmp.$$" "$link"
}

# release_before <releases-dir> <release-id>: prints the release that sorts just before <release-id>.
release_before() {
  local dir=$1 current=$2 prev="" r
  while IFS= read -r r; do
    [[ $r == "$current" ]] && break
    prev=$r
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort)
  [[ -n $prev ]] && printf '%s\n' "$prev"
}
