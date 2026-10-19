#!/usr/bin/env bash

set -Eeuo pipefail

trap 'rc=$?; printf "ERROR: command failed at line %s with exit code %s\n" \
  "${BASH_LINENO[0]}" "$rc" >&2; exit "$rc"' ERR

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: bootstrap.sh must be run as root." >&2
  echo "Run: sudo ./scripts/ops/bootstrap.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log() {
  printf '[bootstrap] %s\n' "$*"
}

install_base_packages() {
  local packages=(
    ca-certificates
    curl
    gnupg
    nginx
    git
    ufw
    jq
    postgresql
  )
  local missing=()
  local package

  for package in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
      grep -q 'install ok installed'; then
      missing+=("$package")
    fi
  done

  if ((${#missing[@]} > 0)); then
    log "Installing packages: ${missing[*]}"
    apt-get update
    apt-get install -y "${missing[@]}"
  else
    log "Base packages already installed."
  fi
}

install_node() {
  local required_major="22"
  local installed_major=""

  if command -v node >/dev/null 2>&1; then
    installed_major="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
  fi

  if [[ "$installed_major" == "$required_major" ]]; then
    log "Node.js 22 already installed."
    return
  fi

  log "Configuring the NodeSource Node.js 22 repository."

  install -d -m 0755 /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/nodesource.gpg ]]; then
    curl -fsSL \
      https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
      gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  fi

  local architecture
  local repository
  architecture="$(dpkg --print-architecture)"
  repository="deb [arch=${architecture} signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main"

  if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]] ||
    [[ "$(< /etc/apt/sources.list.d/nodesource.list)" != "$repository" ]]; then
    printf '%s\n' "$repository" > /etc/apt/sources.list.d/nodesource.list
  fi

  apt-get update
  apt-get install -y nodejs

  log "Installed $(node --version)."
}

enable_corepack() {
  if ! command -v corepack >/dev/null 2>&1; then
    log "Installing Corepack."
    npm install --global corepack
  else
    log "Corepack already installed."
  fi

  corepack enable
}

create_service_user() {
  if ! id africair >/dev/null 2>&1; then
    log "Creating system user africair."
    useradd \
      --system \
      --home-dir /opt/africair \
      --shell /usr/sbin/nologin \
      --user-group \
      africair
  else
    log "System user africair already exists."
  fi
}

create_directory_layout() {
  log "Ensuring /opt/africair directory layout exists."

  install -d -o africair -g africair -m 0755 \
    /opt/africair \
    /opt/africair/releases \
    /opt/africair/releases/bootstrap \
    /opt/africair/shared

  if [[ ! -e /opt/africair/current && ! -L /opt/africair/current ]]; then
    ln -s /opt/africair/releases/bootstrap /opt/africair/current
    chown -h africair:africair /opt/africair/current
    log "Created initial current symlink."
  else
    log "Current symlink or path already exists; leaving it unchanged."
  fi
}

configure_ufw() {
  log "Configuring UFW."

  grep -q '^DEFAULT_INPUT_POLICY="DROP"' /etc/default/ufw ||
    ufw default deny incoming

  grep -q '^DEFAULT_OUTPUT_POLICY="ACCEPT"' /etc/default/ufw ||
    ufw default allow outgoing

  ufw status | grep -qE '^OpenSSH[[:space:]]+ALLOW' ||
    ufw allow OpenSSH

  ufw status | grep -qE '^80/tcp[[:space:]]+ALLOW' ||
    ufw allow 80/tcp

  ufw status | grep -qE '^443/tcp[[:space:]]+ALLOW' ||
    ufw allow 443/tcp

  if ufw status | grep -q '^Status: inactive'; then
    ufw --force enable
  else
    log "UFW already enabled."
  fi
}

enable_nginx() {
  if ! systemctl is-enabled --quiet nginx; then
    systemctl enable nginx
  fi

  if ! systemctl is-active --quiet nginx; then
    systemctl start nginx
  fi

  log "Nginx is enabled and running."
}

main() {
  install_base_packages
  install_node
  enable_corepack
  create_service_user
  create_directory_layout
  configure_ufw
  enable_nginx

  log "Bootstrap completed successfully."
  log "Node: $(node --version)"
  log "NPM: $(npm --version)"
  log "Corepack: $(corepack --version)"
}

main "$@"
