#!/usr/bin/env bash
set -Eeuo pipefail
# Creates ./secrets/{db_password,database_url,admin_token,promo_codes} for compose.yaml.
# Existing files are kept, so running it twice is safe. Uses printf, never echo: a trailing newline in
# db_password would become part of the Postgres password (POSTGRES_PASSWORD_FILE is not trimmed).

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
umask 077
mkdir -p secrets

write() { [[ -s secrets/$1 ]] || { printf '%s' "$2" >"secrets/$1"; echo "created secrets/$1"; }; }

write db_password "$(openssl rand -hex 24)"
write database_url "postgres://africair:$(cat secrets/db_password)@db:5432/africair"
write admin_token "$(openssl rand -hex 24)"
write promo_codes 'SAVE10:10,AFRICA20:20'
echo "admin token: secrets/admin_token"
