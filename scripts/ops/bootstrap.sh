#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

usage() {
  cat <<'EOF'
Usage: sudo scripts/ops/bootstrap.sh [--no-postgres]

Idempotent setup of an Ubuntu 24.04 server for AfricAir. Run it from a checkout of the repository:
it installs packages, creates the `africair` system user and the /opt/africair layout, installs the
nginx site, logrotate rule and systemd units from deploy/, configures ufw (OpenSSH, 80, 443 only)
and, unless --no-postgres is given, a local PostgreSQL database plus the API secret files.

A second run changes nothing and prints "no changes".

Layout:
  /opt/africair/releases/<id>        front-end releases     current -> releases/<id>
  /opt/africair/api/releases/<id>    API releases           api/current -> api/releases/<id>
  /opt/africair/shared/              survives releases
  /etc/africair/api.env              API settings (root:africair 0640)
  /etc/africair/secrets/             API secrets (root:root 0700, files 0600), delivered with LoadCredential=
  /var/lib/africair/                 health-check state
EOF
}

WITH_POSTGRES=1
case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  --no-postgres) WITH_POSTGRES=0 ;;
  "") ;;
  *) usage >&2; exit 1 ;;
esac

require_root

APP_USER=africair
APP_ROOT=/opt/africair
NODE_MAJOR=22
CHANGES=0
changed() { CHANGES=$((CHANGES + 1)); log "changed: $*"; }

# ensure_dir <path> <mode> <owner:group>
ensure_dir() {
  local path=$1 mode=$2 owner=$3
  if [[ -d $path && $(stat -c '%a %U:%G' "$path") == "$mode $owner" ]]; then return 0; fi
  install -d -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$path"
  changed "directory $path ($mode $owner)"
}

# ensure_file <source> <dest> <mode> <owner:group>: copies only when content or metadata differ.
ensure_file() {
  local src=$1 dest=$2 mode=$3 owner=$4
  if [[ -f $dest ]] && cmp -s "$src" "$dest" && [[ $(stat -c '%a %U:%G' "$dest") == "$mode $owner" ]]; then
    return 1
  fi
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dest"
  changed "file $dest"
}

# ensure_secret <name> <command producing the value>: creates /etc/africair/secrets/<name> once, never overwrites.
ensure_secret() {
  local file=/etc/africair/secrets/$1
  shift
  if [[ -s $file ]]; then return 0; fi
  (umask 077 && "$@" >"$file")
  chown root:root "$file"
  chmod 0600 "$file"
  changed "secret $file (generated)"
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# --- 1. packages --------------------------------------------------------------------------------
packages=(nginx git ufw jq curl ca-certificates gnupg openssl)
((WITH_POSTGRES)) && packages+=(postgresql postgresql-client)
missing=()
for p in "${packages[@]}"; do pkg_installed "$p" || missing+=("$p"); done
if ((${#missing[@]})); then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  changed "installed packages: ${missing[*]}"
fi

# Node.js LTS from NodeSource (Ubuntu's own nodejs package is too old and has no corepack).
if ! command -v node >/dev/null 2>&1 || [[ $(node -p 'process.versions.node.split(".")[0]') != "$NODE_MAJOR" ]]; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    >/etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null
  changed "installed Node.js $(node --version)"
fi
if ! command -v pnpm >/dev/null 2>&1; then
  corepack enable
  changed "corepack enabled (pnpm shim)"
fi

# --- 2. user and directory layout ---------------------------------------------------------------
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$APP_ROOT" --no-create-home --shell /usr/sbin/nologin "$APP_USER"
  changed "system user $APP_USER"
fi
ensure_dir "$APP_ROOT" 755 root:root
ensure_dir "$APP_ROOT/releases" 755 "$APP_USER:$APP_USER"
ensure_dir "$APP_ROOT/shared" 755 "$APP_USER:$APP_USER"
ensure_dir "$APP_ROOT/api" 755 root:root
ensure_dir "$APP_ROOT/api/releases" 755 "$APP_USER:$APP_USER"
ensure_dir /etc/africair 750 "root:$APP_USER"
ensure_dir /etc/africair/secrets 700 root:root
ensure_dir /var/lib/africair 750 root:root

# --- 3. configuration from deploy/ --------------------------------------------------------------
nginx_changed=0
ensure_file "$REPO_ROOT/deploy/nginx/africair.conf" /etc/nginx/sites-available/africair 644 root:root && nginx_changed=1
ensure_file "$REPO_ROOT/deploy/nginx/africair-security-headers.conf" /etc/nginx/snippets/africair-security-headers.conf 644 root:root && nginx_changed=1
if [[ $(readlink /etc/nginx/sites-enabled/africair 2>/dev/null) != /etc/nginx/sites-available/africair ]]; then
  ln -sfn /etc/nginx/sites-available/africair /etc/nginx/sites-enabled/africair
  changed "enabled nginx site africair"
  nginx_changed=1
fi
if [[ -L /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
  changed "disabled nginx default site"
  nginx_changed=1
fi
if ((nginx_changed)); then
  nginx -t -q
  if systemctl is-active --quiet nginx; then systemctl reload nginx; fi
fi
if ! systemctl is-active --quiet nginx; then
  systemctl enable --now nginx >/dev/null 2>&1
  changed "started nginx"
fi
ensure_file "$REPO_ROOT/deploy/logrotate/africair" /etc/logrotate.d/africair 644 root:root || true

# Settings file: installed once from the example; operators edit it in place afterwards.
if [[ ! -f /etc/africair/api.env ]]; then
  install -m 0640 -o root -g "$APP_USER" "$REPO_ROOT/deploy/config/api.env.example" /etc/africair/api.env
  changed "settings /etc/africair/api.env (from example)"
fi

units_changed=0
for unit in africair-api.service africair-migrate.service africair-health.service africair-health.timer; do
  ensure_file "$REPO_ROOT/deploy/systemd/$unit" "/etc/systemd/system/$unit" 644 root:root && units_changed=1
done
ensure_file "$SCRIPT_DIR/healthcheck.sh" /usr/local/sbin/africair-healthcheck 755 root:root && units_changed=1
((units_changed)) && systemctl daemon-reload
if ! systemctl is-enabled --quiet africair-health.timer; then
  systemctl enable --now africair-health.timer >/dev/null 2>&1
  changed "enabled africair-health.timer"
fi
if ! systemctl is-enabled --quiet africair-api.service; then
  systemctl enable africair-api.service >/dev/null 2>&1 # started by deploy.sh once a release exists
  changed "enabled africair-api.service"
fi

# --- 4. firewall: only SSH, HTTP and HTTPS ------------------------------------------------------
# The OpenSSH application profile exists only when openssh-server is installed (it is on EC2 images).
ssh_rule=OpenSSH
ufw app info OpenSSH >/dev/null 2>&1 || ssh_rule=22/tcp
for rule in "$ssh_rule" 80/tcp 443/tcp; do
  if ! ufw status | grep -qE "^${rule}[[:space:]]+ALLOW"; then
    ufw allow "$rule" >/dev/null
    changed "ufw allow $rule"
  fi
done
if ! ufw status | grep -q '^Status: active'; then
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  changed "ufw enabled (default deny incoming)"
fi

# --- 5. PostgreSQL and API secrets --------------------------------------------------------------
if ((WITH_POSTGRES)); then
  systemctl is-active --quiet postgresql || { systemctl enable --now postgresql >/dev/null 2>&1; changed "started postgresql"; }
  # Hex passwords need no URL-encoding inside DATABASE_URL.
  ensure_secret db_password openssl rand -hex 24
  ensure_secret admin_token openssl rand -hex 24
  ensure_secret promo_codes printf '%s' 'SAVE10:10,AFRICA20:20'
  db_password=$(cat /etc/africair/secrets/db_password)
  ensure_secret database_url printf 'postgres://africair_app:%s@127.0.0.1:5432/africair' "$db_password"

  psql_admin() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -qtA "$@"; }
  if [[ $(psql_admin -c "SELECT 1 FROM pg_roles WHERE rolname = 'africair_app'") != 1 ]]; then
    # Passed through stdin so psql interpolates :'pw' (it does not interpolate -c) and the password never hits argv.
    psql_admin -v pw="$db_password" <<<"CREATE ROLE africair_app LOGIN PASSWORD :'pw';"
    changed "postgres role africair_app"
  fi
  if [[ $(psql_admin -c "SELECT 1 FROM pg_database WHERE datname = 'africair'") != 1 ]]; then
    runuser -u postgres -- createdb --owner africair_app africair
    changed "postgres database africair"
  fi
  unset db_password
fi

if ((CHANGES)); then log "done: $CHANGES change(s)"; else log "done: no changes"; fi
