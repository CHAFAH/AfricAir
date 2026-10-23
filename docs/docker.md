# AfricAir Docker operations guide

## Prerequisites

- Docker Desktop with BuildKit/buildx
- Git
- AWS CLI v2 for ECR operations
- Docker Hub account for public images

Run commands from the repository root. Never commit `secrets/`.

## Build

Set reproducible build metadata:

```bash
VERSION=1.0.0
GIT_SHA="$(git rev-parse --short=7 HEAD)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

Build the web and API images:

```bash
docker build --file Dockerfile.web --tag africair-web:compose \
  --build-arg VERSION="$VERSION" --build-arg GIT_SHA="$GIT_SHA" \
  --build-arg BUILD_DATE="$BUILD_DATE" .

docker build --file Dockerfile.api --tag africair-api:compose \
  --build-arg VERSION="$VERSION" --build-arg GIT_SHA="$GIT_SHA" \
  --build-arg BUILD_DATE="$BUILD_DATE" .
```

The Dockerfiles run the required build gates. A failing TypeScript or unit test
causes the web build to fail.

## Configure

Non-secret staging settings live in `config/staging.env`. Copy the committed
dummy files into the ignored local secret directory, then replace each dummy
value with a local value:

```bash
mkdir -p secrets
cp secrets.example/db_password secrets/db_password
cp secrets.example/admin_token secrets/admin_token
cp secrets.example/promo_codes secrets/promo_codes
printf '%s' 'postgres://africair:CHANGE_ME@db:5432/africair' > secrets/database_url
```

Use `printf`, not `echo`, for secrets. In particular, PostgreSQL does not trim a
trailing newline read through `POSTGRES_PASSWORD_FILE`. Ensure the password in
`database_url` matches `secrets/db_password`.

## Run

Start the database, one-shot migration, two API replicas, and web proxy:

```bash
docker compose up -d --build
docker compose ps
curl -fsS http://localhost:8080/healthz
curl -fsS http://localhost:8080/api/readyz
```

Open `http://localhost:8080`. Database and API ports are not published to the
host; browser/API traffic goes through the web container on port 8080.

Stop the stack without deleting bookings:

```bash
docker compose down
```

Delete the stack and PostgreSQL volume only when the data is no longer needed:

```bash
docker compose down -v
```

## Change configuration

After editing `config/staging.env`, recreate the API containers:

```bash
docker compose up -d api
```

`docker compose restart` is insufficient because it restarts the existing
container without recreating it from the changed environment configuration.

## Rotate secrets

Rotate the admin token without rebuilding or restarting:

```bash
printf '%s' 'NEW_LOCAL_ADMIN_TOKEN' > secrets/admin_token
```

After `SECRET_REFRESH_SECONDS`, verify the fingerprint changes on `/#/status`.
The old token must fail and the new token must work. Promo-code files use the
same mounted-file refresh mechanism.

## Test

Run the complete Compose end-to-end profile and return the E2E exit status:

```bash
docker compose --profile test up --build --exit-code-from e2e
```

Run key acceptance checks:

```bash
curl -fsS localhost:8080/healthz
curl -fsS localhost:8080/api/readyz
curl -sI localhost:8080/ | grep -i x-environment
for i in $(seq 6); do curl -sI localhost:8080/api/config | grep -i x-upstream; done
docker compose exec api sh -c 'id -u; env' | grep -Ei 'token|password|promo'
```

Scan and lint:

```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 africair-web:compose
trivy image --severity HIGH,CRITICAL --exit-code 1 africair-api:compose
docker run --rm -i hadolint/hadolint:v2.12.0-alpine < Dockerfile.web
docker run --rm -i hadolint/hadolint:v2.12.0-alpine < Dockerfile.api
```

## Publish to Docker Hub

Create and select a buildx builder, then authenticate:

```bash
docker buildx create --name africair-builder --use 2>/dev/null || docker buildx use africair-builder
docker buildx inspect --bootstrap
docker login
```

Publish both architectures with version and immutable commit tags:

```bash
GIT_SHA="$(git rev-parse --short=7 HEAD)"

docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.web \
  -t "joketaiwo/africair-web:$GIT_SHA" -t joketaiwo/africair-web:1.0.0 \
  --provenance=true --sbom=true --push .

docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.api \
  -t "joketaiwo/africair-api:$GIT_SHA" -t joketaiwo/africair-api:1.0.0 \
  --provenance=true --sbom=true --push .
```

Verify with `docker buildx imagetools inspect`. Do not publish or deploy
`latest`; promote an exact commit tag or digest.

## Publish to Amazon ECR

The private ECR repositories are `africair-web` and `africair-api` in
`us-east-1`. They have immutable tags, scan-on-push, and lifecycle policies.

Authenticate:

```bash
aws ecr get-login-password --region us-east-1 --profile africair-deployer | \
  docker login --username AWS --password-stdin \
  981750769980.dkr.ecr.us-east-1.amazonaws.com
```

Publish multi-architecture images:

```bash
GIT_SHA="$(git rev-parse --short=7 HEAD)"
REGISTRY=981750769980.dkr.ecr.us-east-1.amazonaws.com

docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.web \
  -t "$REGISTRY/africair-web:$GIT_SHA" -t "$REGISTRY/africair-web:1.0.0" \
  --provenance=true --sbom=true --push .

docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.api \
  -t "$REGISTRY/africair-api:$GIT_SHA" -t "$REGISTRY/africair-api:1.0.0" \
  --provenance=true --sbom=true --push .
```

On EC2, authenticate with the instance role and pull the immutable commit:

```bash
aws ecr get-login-password --region us-east-1 | sudo docker login \
  --username AWS --password-stdin 981750769980.dkr.ecr.us-east-1.amazonaws.com
sudo docker pull 981750769980.dkr.ecr.us-east-1.amazonaws.com/africair-web:c57a91a
sudo docker pull 981750769980.dkr.ecr.us-east-1.amazonaws.com/africair-api:c57a91a
```

## Secret and image safety

- Keep real files under `secrets/` out of Git and the Docker build context.
- Commit only dummy examples under `secrets.example/`.
- Do not put secrets in Dockerfiles, build arguments, image labels, or registries.
- Build once and promote the same digest between environments.
- Use environment variables and mounted secret files for runtime differences.
