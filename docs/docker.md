# AfricAir on Docker

Two images, built once and promoted unchanged across environments. All behaviour differences come from environment variables and secrets, never from rebuilding.

| Image | Contents | Port | User |
|---|---|---|---|
| `africair-web` | Static front end (`dist/`) served by nginx-unprivileged, which also proxies `/api/` | 8080 | 101 |
| `africair-api` | Node.js API (distroless Node 22): runtime config, secrets, bookings, metrics | 4000 (app), 9464 (metrics) | nonroot (65532) |

## Build

```bash
# Web (multi-stage: deps -> test -> build -> nginx runtime). Tests gate the build.
docker build -f Dockerfile.web -t africair-web:latest \
  --build-arg VERSION=1.0.0 --build-arg GIT_SHA="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_DATE="$(date -u +%FT%TZ)" .

# API (multi-stage: build -> prod-deps -> distroless runtime)
docker build -f Dockerfile.api -t africair-api:latest .
```

`.dockerignore` keeps `node_modules`, `dist`, `.git`, `test-results` and `.env*` (except `.env.example`) out of the build context.

## Run the whole stack

```bash
docker compose up -d --build
# db (postgres) -> migrate (one-shot) -> api (2 replicas) -> web (:8080)
```

- `db` and `api` publish no host ports; only `web` is reachable on `localhost:8080`.
- Startup order is enforced with `depends_on` conditions: `db: service_healthy`,
  `migrate: service_completed_successfully`.

## Configure

Non-secret settings live in `config/staging.env` (env banner, brand, announcement,
currency, service fee, maintenance mode). After editing it:

```bash
docker compose up -d api   # recreate — NOT `restart`, which keeps old env
```

## Secrets

Secrets are files under `secrets/` (git-ignored; see `secrets.example/` for the shape),
mounted as Compose secrets and referenced via `*_FILE` env vars:

| File | API variable |
|---|---|
| `secrets/db_password` | builds the DB connection |
| `secrets/admin_token` | `ADMIN_TOKEN_FILE=/run/secrets/admin_token` |
| `secrets/promo_codes` | `PROMO_CODES_FILE=/run/secrets/promo_codes` |

### Rotate a secret with no restart

```bash
printf '%s' "$(openssl rand -hex 24)" > secrets/admin_token
# within SECRET_REFRESH_SECONDS the API re-reads the file:
curl -s localhost:8080/api/config | jq '.secrets.adminToken.fingerprint'
```

Write secret files with `printf '%s'` (no trailing newline) — `echo` appends `\n`, which
breaks Postgres password auth.

## Test

```bash
docker compose --profile test up --build --exit-code-from e2e
```

## Scan, SBOM, lint

```bash
hadolint Dockerfile.web Dockerfile.api
trivy image --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore africair-web:latest
trivy image --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore africair-api:latest
syft africair-web:latest -o spdx-json=sbom/africair-web.spdx.json
syft africair-api:latest -o spdx-json=sbom/africair-api.spdx.json
```

See `.trivyignore` for the justified API base-image suppressions.

## Push to ECR

```bash
REG=887095766978.dkr.ecr.us-east-1.amazonaws.com
SHA=$(git rev-parse --short HEAD)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REG"
for img in web api; do
  docker tag africair-$img:latest $REG/africair-$img:$SHA
  docker tag africair-$img:latest $REG/africair-$img:1.0.0
  docker push $REG/africair-$img:$SHA
  docker push $REG/africair-$img:1.0.0
done
```

Repos are IMMUTABLE with scan-on-push and a lifecycle policy (keep last 10 tagged,
expire untagged after 1 day). Deploy by **git sha or semver**, never `latest`.
