#!/usr/bin/env bash
# bootstrap.sh — idempotent server setup for AfricAir
# Usage: sudo ./bootstrap.sh
# Exit codes: 0 success, 1 not root
set -Eeuo pipefail

trap 'echo "ERROR: bootstrap.sh failed at line $LINENO" >&2' ERR

log() { echo "[bootstrap] $*"; }
ok()  { echo "[bootstrap] OK: $*"; }

# --- root check --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (sudo ./bootstrap.sh)" >&2
  exit 1
fi

# --- packages ----------------------------------------------------------------
log "Checking packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

for pkg in git curl jq ufw nginx; do
  if dpkg -s "$pkg" &>/dev/null 2>&1; then
    ok "$pkg already installed"
  else
    apt-get install -y -qq "$pkg"
    ok "$pkg installed"
  fi
done

# Node.js LTS
if command -v node &>/dev/null; then
  ok "node already installed ($(node --version))"
else
  log "Installing Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y -qq nodejs
  ok "node installed ($(node --version))"
fi

# corepack
if corepack --version &>/dev/null 2>&1; then
  ok "corepack already available"
else
  corepack enable
  ok "corepack enabled"
fi

# --- system user -------------------------------------------------------------
if id africair &>/dev/null 2>&1; then
  ok "user 'africair' already exists"
else
  useradd --system --no-create-home --shell /usr/sbin/nologin africair
  ok "user 'africair' created"
fi

# --- directory layout --------------------------------------------------------
for dir in /opt/africair/releases /opt/africair/shared; do
  if [[ -d "$dir" ]]; then
    ok "$dir already exists"
  else
    mkdir -p "$dir"
    ok "$dir created"
  fi
done

chown -R africair:africair /opt/africair
ok "ownership set on /opt/africair"

# --- ufw ---------------------------------------------------------------------
ufw --force enable &>/dev/null
for rule in OpenSSH "Nginx HTTP" "Nginx HTTPS"; do
  if ufw status | grep -q "$rule"; then
    ok "ufw rule '$rule' already present"
  else
    ufw allow "$rule"
    ok "ufw rule '$rule' added"
  fi
done

# --- nginx -------------------------------------------------------------------
if systemctl is-enabled nginx &>/dev/null; then
  ok "nginx already enabled"
else
  systemctl enable nginx
  ok "nginx enabled"
fi

if systemctl is-active nginx &>/dev/null; then
  ok "nginx already running"
else
  systemctl start nginx
  ok "nginx started"
fi

log "Bootstrap complete."
