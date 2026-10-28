#!/usr/bin/env bash
set -Eeuo pipefail
# Post-deploy smoke test: the site is up and BOTH the static build and the API report the expected commit.
# Usage: scripts/ci/smoke.sh <base-url> <expected-commit-sha> [expected-app-env]
BASE_URL=${1:?base url}
EXPECTED=${2:?expected commit}
APP_ENV=${3:-}

for _ in $(seq 30); do curl -fsS -m 5 "$BASE_URL/healthz" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS -m 5 "$BASE_URL/healthz" >/dev/null
web_commit=$(curl -fsS -m 5 "$BASE_URL/version.json" | jq -r .commit)
config=$(curl -fsS -m 5 "$BASE_URL/api/config")
api_commit=$(jq -r .commit <<<"$config")
readiness=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$BASE_URL/api/readyz")

echo "web commit: $web_commit"
echo "api commit: $api_commit"
echo "readyz:     $readiness"
echo "appEnv:     $(jq -r .appEnv <<<"$config")  storage: $(jq -r .storage <<<"$config")"
[[ $web_commit == "$EXPECTED" ]] || { echo "version.json commit mismatch (expected $EXPECTED)" >&2; exit 1; }
[[ $api_commit == "$EXPECTED" ]] || { echo "/api/config commit mismatch (expected $EXPECTED)" >&2; exit 1; }
[[ $readiness == 200 ]] || { echo "/api/readyz returned $readiness" >&2; exit 1; }
[[ -z $APP_ENV || $(jq -r .appEnv <<<"$config") == "$APP_ENV" ]] || { echo "appEnv mismatch" >&2; exit 1; }
echo "smoke OK"
