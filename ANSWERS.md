# Project 2 — Containerise AfricAir with Docker

## Knowledge check

### 1. `CMD` vs `ENTRYPOINT`

`ENTRYPOINT` selects the executable that starts when a container starts. `CMD`
supplies its default arguments, or acts as the command when no entrypoint is
defined. The `nginxinc/nginx-unprivileged` image keeps its entrypoint, which runs
the scripts in `/docker-entrypoint.d/`. Those scripts render the files in
`/etc/nginx/templates` using environment variables and then execute the image's
default Nginx `CMD`. Replacing `CMD` changes what the entrypoint eventually
executes; replacing `ENTRYPOINT` bypasses template rendering entirely.

### 2. Lockfiles, cached layers, and cache mounts

Package manifests and lockfiles are copied before application source so that a
source-only change does not invalidate the dependency-install layer. Docker can
then reuse that layer while rerunning only the source, test, and build steps.

A cached layer is the immutable result of a Dockerfile instruction; when its
inputs match, BuildKit skips that entire instruction. A cache mount is mutable
builder storage, such as pnpm's content-addressable package store. It speeds up
an instruction that must rerun by reusing downloaded packages, but its contents
do not become part of the final image layer.

### 3. Environment-variable secrets vs file secrets

Environment-variable secrets can leak through:

1. `docker inspect` or Compose configuration output;
2. `/proc/<pid>/environ` and process diagnostics;
3. crash reports, debug dumps, support bundles, or accidental logging.

File secrets are mounted only where needed and the application reads them from
`/run/secrets`. They are not included in the normal environment or image. File
permissions and service-level mounts further restrict access.

### 4. Compose readiness conditions

Basic `depends_on` controls creation order, not application readiness. A process
can be running while its database is still starting. `service_healthy` waits for
the dependency's configured health check to pass. `service_completed_successfully`
waits for a one-shot dependency to exit with status 0. AfricAir uses both: the
migration waits for healthy PostgreSQL, and API replicas wait for a successful
migration.

### 5. Separate metrics port

Metrics use port 9464 so operational traffic can be isolated from user-facing API
traffic on port 4000. Firewall and network policies can allow Prometheus to reach
metrics without exposing them publicly. The ports can also have separate access
controls, logging, timeouts, and scaling behavior.

### 6. One-shot migrations

Migrations are a separate one-shot container so schema changes complete before
any API replica accepts traffic. With `MIGRATE_ON_START=true`, five replicas could
all try to migrate simultaneously, increasing lock contention and creating
uncertain startup behavior if one migration fails. AfricAir's advisory lock makes
concurrent migration attempts safer, but a single explicit job is still easier
to observe, retry, and gate with `service_completed_successfully`.

## Task 6 — Read-only Nginx root cause

The Nginx image's entrypoint renders templates from `/etc/nginx/templates` into
`/etc/nginx/conf.d` by default. With a read-only root filesystem, that write
fails. The fix preserves `read_only: true` by setting:

```dockerfile
NGINX_ENVSUBST_OUTPUT_DIR=/tmp
```

Compose mounts `/tmp` as a small `tmpfs`, so runtime-generated configuration is
writable and ephemeral while the image root filesystem remains immutable.

## Task 7 — Size, layers, and cache

### Web image

The final web image is 8,746,161 bytes (about 8.75 MB), below the 50 MB limit.
Its largest meaningful layers are the pinned Nginx Alpine slim runtime, the
compiled `dist/` assets (about 1.47 MB), and the Nginx configuration/template.
Node, pnpm, source code, and development dependencies are absent from runtime.

### API image

The API image is below 120 MB. Its largest meaningful layers are the Node 22
Alpine runtime, production `node_modules` (about 5.62 MB), and compiled API plus
migrations. TypeScript, Vite, React, frontend assets, and source files are absent.

### Cache evidence

After changing `src/components/Home.tsx`, the dependency-install layers stayed
`CACHED` because the manifests and lockfile were unchanged; later source/test/build
layers reran. After changing `server/src/app.ts`, the API source and compilation
reran while dependencies stayed cached. The web build also reran its shared
workspace gate because `pnpm check` validates both workspace packages.

## Task 8 — Scan, SBOM, and lint

Both final images passed Trivy with `--severity HIGH,CRITICAL --exit-code 1`:

```text
africair-web:compose  Total: 0 (HIGH: 0, CRITICAL: 0)
africair-api:compose  Total: 0 (HIGH: 0, CRITICAL: 0)
```

No `.trivyignore` was needed. SPDX JSON SBOMs are committed under
`evidence/sbom/`: web contains 22 packages and API contains 41. The API has more
because it includes Node.js and the PostgreSQL and Prometheus production
dependency trees. Both Dockerfiles passed Hadolint with exit code 0.

## Task 9 — Registries and tag strategy

### Published images

- Docker Hub: `joketaiwo/africair-web:1.0.0`
- Docker Hub: `joketaiwo/africair-api:1.0.0`
- ECR: `981750769980.dkr.ecr.us-east-1.amazonaws.com/africair-web`
- ECR: `981750769980.dkr.ecr.us-east-1.amazonaws.com/africair-api`

Both repositories contain `linux/amd64` and `linux/arm64` manifests. ECR contains
both `1.0.0` and immutable commit tag `c57a91a`. The ECR repositories use immutable
tags, scan-on-push for `africair-*`, and lifecycle rules that expire untagged
images after one day and retain the latest ten tagged images.

The EC2 pull was performed with the `Afric-Air` instance role. The role had
`ecr:GetAuthorizationToken` and read access only to the two AfricAir repositories.
No long-lived AWS user key was copied to EC2. Both `c57a91a` images were pulled
successfully.

### Why `latest` is not deployed

The release tag `1.0.0` communicates a human-readable version, while `c57a91a`
identifies the exact source commit. Deployment uses the commit tag or, preferably,
the registry digest. `latest` is mutable and does not state which code is running;
it can change between environments, makes rollback ambiguous, and prevents a
reliable audit trail. Build once and promote the same digest instead of rebuilding
or following `latest`.

### ECR scan note

The tagged multi-platform entry is an OCI image index, so its page reports
`Scan not found`; ECR scans its referenced Linux platform manifests. A repeated
manual request returned `LIMIT_EXCEEDED` because basic scanning allows one scan
per image per 24 hours. Independent Trivy gates for both final images reported no
HIGH or CRITICAL findings.

## Evidence checklist

The submission should include captured screenshots or terminal output for:

- all seven visible Task 5 configuration and secret checks;
- both read-only filesystem failures and the Nginx fix;
- image size, history, and BuildKit cache behavior;
- Trivy, SBOM package counts, and Hadolint;
- Docker Hub multi-architecture manifests;
- ECR settings, lifecycle rules, image tags, and platform scan pages;
- EC2 assumed-role identity, ECR login, and successful pulls;
- all seven debugging drills, including each error, explanation, and fix.
