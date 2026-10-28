#!/usr/bin/env bash
set -Eeuo pipefail
# Runs ON the EC2 container host, started by SSM Run Command (scripts/ci/deploy-ec2.sh).
# Usage: deploy.sh <staging|production> <image-tag> <bundle-dir>
#   1. logs in to ECR and reads secrets with the instance role (no keys on the host);
#   2. writes the secret files (root:root 0600 dir, files readable by the containers' users only via secrets:);
#   3. pulls the images by tag and records their digests;
#   4. `docker compose up -d` (one-shot migrate, then api ×2, then web), waits for readiness and checks
#      that /api/config reports the image's commit; on failure it redeploys the previous tag.
trap 'echo "deploy.sh: error on line $LINENO" >&2' ERR

APP_ENV=${1:?environment}
IMAGE_TAG=${2:?image tag}
BUNDLE=${3:?bundle dir}
STACK=/opt/africair-stack
TOKEN=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com" IMAGE_TAG APP_ENV

install -d -m 0755 "$STACK" "$STACK/config"
install -d -m 0700 "$STACK/secrets"
install -m 0644 "$BUNDLE/compose.yaml" "$STACK/compose.yaml"
install -m 0644 "$BUNDLE/config/$APP_ENV.env" "$STACK/config/$APP_ENV.env"
cd "$STACK"

# --- secrets: one Secrets Manager JSON document per environment ---------------------------------
secret_json=$(aws secretsmanager get-secret-value --secret-id "africair/ec2-$APP_ENV/app" --query SecretString --output text)
write_secret() { (umask 077 && printf '%s' "$2" >"secrets/$1"); }
db_password=$(jq -er .DB_PASSWORD <<<"$secret_json")
write_secret db_password "$db_password"
write_secret database_url "postgres://africair:$(jq -rn --arg p "$db_password" '$p|@uri')@db:5432/africair"
write_secret admin_token "$(jq -er .ADMIN_TOKEN <<<"$secret_json")"
write_secret promo_codes "$(jq -er .PROMO_CODES <<<"$secret_json")"
unset secret_json db_password
# Compose bind-mounts secret files: the API (uid 1000) must be able to read them inside the container.
chmod 0644 secrets/*

# --- pull and start -----------------------------------------------------------------------------
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
previous_tag=$(cat .deployed-tag 2>/dev/null || true)
docker compose pull --quiet
for img in africair-web africair-api; do
  echo "digest $img:$IMAGE_TAG $(docker image inspect "$REGISTRY/$img:$IMAGE_TAG" --format '{{index .RepoDigests 0}}')"
done

up() { docker compose up -d --remove-orphans --wait --wait-timeout 180; }
if ! up; then
  echo "deploy of $IMAGE_TAG failed" >&2
  docker compose logs --tail 50 migrate api >&2 || true
  if [[ -n $previous_tag ]]; then
    echo "rolling back to $previous_tag" >&2
    IMAGE_TAG=$previous_tag up || true
  fi
  exit 1
fi

expected=$(docker image inspect "$REGISTRY/africair-api:$IMAGE_TAG" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
served=$(curl -fsS http://127.0.0.1/api/config | jq -r .commit)
if [[ $served != "$expected" ]]; then
  echo "served commit $served != image revision $expected" >&2
  exit 1
fi
printf '%s' "$IMAGE_TAG" >.deployed-tag
docker image prune -af --filter 'until=168h' >/dev/null || true
echo "deployed $APP_ENV $IMAGE_TAG (commit $served)"
