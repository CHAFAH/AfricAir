# AfricAir with Docker

Two images, built once and promoted unchanged; every difference between environments comes from
environment variables and secrets.

| Image | Dockerfile | Runs as | Ports | Health |
|---|---|---|---|---|
| `africair-web` | `Dockerfile.web` (nginx-unprivileged, static `dist/`, proxies `/api/`) | 101 | 8080 | `/healthz` |
| `africair-api` | `Dockerfile.api` (Alpine + Node 22 binary, prod-only `node_modules`) | `node` (1000) | 4000, 9464 (metrics) | `/api/healthz`, `/api/readyz` |

## Build

```bash
export GIT_SHA=$(git rev-parse HEAD) BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) APP_VERSION=1.0.0
docker buildx build -f Dockerfile.web --build-arg VERSION=$APP_VERSION --build-arg GIT_SHA=$GIT_SHA \
  --build-arg BUILD_DATE=$BUILD_DATE -t africair-web:local --load .
docker buildx build -f Dockerfile.api --build-arg VERSION=$APP_VERSION --build-arg GIT_SHA=$GIT_SHA \
  --build-arg BUILD_DATE=$BUILD_DATE -t africair-api:local --load .
```

Both builds run the type checks and tests. A failing test fails `docker build` (the `build` stage is
`FROM test`, so BuildKit cannot skip it). `pnpm install` is cached on the manifests and on a BuildKit
cache mount for the pnpm store.

## Run the stack

```bash
scripts/docker/make-secrets.sh          # once: random values in ./secrets (git-ignored)
docker compose up -d --build            # db → migrate (one-shot) → api ×2 → web
open http://localhost:8080              # STAGING banner, NGN prices, $5 service fee
docker compose ps                       # migrate: Exited (0); api ×2, db, web: healthy
```

Only `web` publishes a port. `db` and `api` live on the `backend` network, which is `internal: true`
(no internet access either).

## Configure

- **Settings:** `config/staging.env` (`env_file`). After editing it run `docker compose up -d api`:
  `restart` reuses the container and its old environment; `up -d` sees the changed config and
  recreates the container.
- **Secrets:** files in `./secrets/`, mounted as Compose secrets at `/run/secrets/<name>`. The API
  reads them through `*_FILE` variables, so `docker compose exec api env` shows paths, never values.

| File | Used by |
|---|---|
| `secrets/db_password` | `db` (`POSTGRES_PASSWORD_FILE`) |
| `secrets/database_url` | `migrate`, `api` (`DATABASE_URL_FILE`), and must contain the same password |
| `secrets/admin_token` | `api` (`ADMIN_TOKEN_FILE`), unlocks `/#/admin` |
| `secrets/promo_codes` | `api` (`PROMO_CODES_FILE`), e.g. `SAVE10:10,AFRICA20:20` |

`secrets.example/` holds dummy values with the same layout.

## Rotate a secret

```bash
printf '%s' "$(openssl rand -hex 24)" > secrets/admin_token   # printf: no trailing newline
# within SECRET_REFRESH_SECONDS (10 s) the fingerprint on /#/status changes; nothing restarts
```

`ADMIN_TOKEN` and `PROMO_CODES` reload live. `DATABASE_URL` is read once at start (connection pool),
so a database password change needs `docker compose up -d --force-recreate api`.

## Test

```bash
docker compose --profile test up --build --exit-code-from e2e   # Playwright against http://web:8080
for i in $(seq 6); do curl -sI localhost:8080/api/config | grep -i x-upstream; done
```

## Hardened run

Both images run with:

```bash
docker run --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  --memory 128m --cpus 0.5 --pids-limit 100 africair-web:local
```

and `compose.yaml` applies the same settings to `migrate`, `api` and `web`.

## Scan and lint

```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 africair-web:local
trivy image --severity HIGH,CRITICAL --exit-code 1 africair-api:local
trivy image --format cyclonedx -o sbom-api.cdx.json africair-api:local
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint:v2.12.0 < Dockerfile.web
```

## Push

Multi-arch to Docker Hub:

```bash
docker buildx create --use --name africair
for img in web api; do
  docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.$img \
    --build-arg VERSION=1.0.0 --build-arg GIT_SHA=$GIT_SHA --build-arg BUILD_DATE=$BUILD_DATE \
    -t <dockerhub-user>/africair-$img:$GIT_SHA -t <dockerhub-user>/africair-$img:1.0.0 --push .
done
docker buildx imagetools inspect <dockerhub-user>/africair-api:1.0.0   # two platforms
```

To Amazon ECR (the repositories come from `infra/terraform/envs/shared`, and are immutable with
scan-on-push):

```bash
REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-west-1.amazonaws.com
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.api ... -t $REGISTRY/africair-api:$GIT_SHA -t $REGISTRY/africair-api:1.0.0 --push .
```

On the Project 1 EC2 instance, the instance role (`AmazonEC2ContainerRegistryReadOnly`) is enough:
`aws ecr get-login-password | docker login …` then `docker pull $REGISTRY/africair-api:1.0.0`.

**Tags:** `<git-sha>` is the build's identity (immutable, traceable to one commit). `1.0.0` marks a
release of that same digest. `latest` is never deployed: it moves, so the same manifest can mean
different code tomorrow, rollbacks become guesswork, and with immutable tags it can't be pushed twice
anyway.
