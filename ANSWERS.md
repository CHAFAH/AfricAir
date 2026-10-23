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

## Debugging drills

### Drill 1 — Nginx returns 403 because of file ownership

I reproduced the failure by making `/usr/share/nginx/html` root-owned with mode
`700` while Nginx continued to run as UID 101. A request returned:

```text
HTTP/1.1 403 Forbidden
"/usr/share/nginx/html/index.html" is forbidden (13: Permission denied)
```

The runtime process cannot read a root-only document root. The permanent fix is
to assign the compiled files to the unprivileged Nginx user while copying them:

```dockerfile
COPY --from=build --chown=101:101 /app/dist/ /usr/share/nginx/html/
```

The corrected container reported `uid=101(nginx)`, `index.html` was owned by
`nginx:nginx` with readable mode `0644`, and the same request returned `200 OK`.
The captured terminal output is in `evidence/drills/01-web-403.txt`.

### Drill 2 — Non-root Nginx cannot bind to port 80

I changed the temporary image to listen on port 80, ran it as UID 101 with all
capabilities dropped, and enforced the conventional unprivileged-port boundary.
It exited with:

```text
bind() to 0.0.0.0:80 failed (13: Permission denied)
```

Granting `NET_BIND_SERVICE` or running as root would weaken the container. The
fix is to keep Nginx on unprivileged port 8080 and let Docker, a load balancer,
or another reverse proxy publish port 80 externally. With the same hardening on
port 8080, the container stayed running as UID 101 and `/healthz` returned
`200 OK`. Evidence is in `evidence/drills/02-port-80.txt`.

### Drill 3 — API starts before migration finishes

I started the API against a new PostgreSQL database without running migrations.
The API process was live, but the database contained no relations. The first
valid booking returned `503` and the API logged:

```text
relation "bookings" does not exist
```

I then ran the same API image as a one-shot migration container with
`node dist/migrate.js`. It exited 0, created `bookings` and
`schema_migrations`, and the same request returned `201 Created`. The permanent
Compose ordering is `db` healthy → `migrate` completed successfully → API
replicas start. This prevents traffic from reaching an API whose schema is not
ready. Evidence is in `evidence/drills/03-migration-order.txt`.

### Drill 4 — ARM64 image on AMD64 EC2

The EC2 host reported `x86_64`. I deliberately pulled the `linux/arm64`
platform manifest and attempting to run it produced `exec format error` because
the host cannot execute ARM64 binaries natively. Pulling `linux/amd64` from the
same multi-platform `c57a91a` tag produced an AMD64 image that started and
returned `200 OK` from `/healthz`. A multi-architecture image index lets each
host automatically select its compatible manifest while preserving one release
tag and source version.

### Drill 5 — Nginx keeps stale Docker DNS addresses

I reproduced the failure with a temporary Nginx image whose API proxy used a
static `proxy_pass http://api:4000`. After replacing the API containers, Nginx
continued using their old container addresses and returned `502 Bad Gateway`.
The response showed the stale upstream addresses in `X-Upstream`.

The production configuration uses Docker's embedded DNS server and resolves the
upstream again at runtime:

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;
set $api_upstream "${API_UPSTREAM}";
proxy_pass $api_upstream;
```

Using a variable in `proxy_pass` makes Nginx consult the configured resolver
instead of retaining only the addresses resolved during startup. The correct
Compose web container continued to reach `/api/config` after the API replicas
were recreated, without restarting Nginx. Evidence is in
`evidence/drills/05-nginx-dns.txt`.

### Drill 6 — `pnpm start` prevents reliable graceful shutdown

The deliberately incorrect image used `CMD ["pnpm", "start"]`. Its process tree
contained several wrapper processes instead of Node running directly as the
container process. In this run, Corepack/pnpm also attempted dependency
verification and download, the API did not become usable, and `docker stop`
waited the full timeout (approximately 11 seconds). No `shutdown requested`
message appeared.

The correct image uses `CMD ["node", "dist/index.js"]`. Its process tree showed
`node dist/index.js` as the direct container process. On `docker stop`, Node
received `SIGTERM`, logged `shutdown requested`, waited the configured one
second drain period, logged `shutdown complete`, and exited in approximately
one second.

Running the pnpm-wrapped experiment with Docker's `--init` made `tini` PID 1 and
allowed the wrapper to be stopped in about one second, but the API still never
started because pnpm was downloading/verifying itself. `--init` helps forward
signals and reap orphaned children; it does not remove package-manager wrapper
behavior or guarantee that the application receives signals correctly. The
production command therefore remains direct Node execution. Evidence is in
`evidence/drills/06-sigterm-pid1.txt`.

### Drill 7 — Secret-file whitespace causes database authentication failure

I first created the PostgreSQL password file with a CRLF line ending. With the
current `postgres:16-alpine` entrypoint this still returned `200 OK`, showing
that its shell-based `_FILE` handling removed the trailing line ending. This is
an important implementation detail: a normal trailing newline did not reproduce
the claimed failure with this specific image version.

I then reproduced the underlying hidden-whitespace fault with a trailing space,
confirmed as byte `20` using `od`. PostgreSQL initialized the role with that
space as part of its password, while the API connection URL contained the
visually identical password without it. `/api/readyz` returned `503 Service
Unavailable`, and the API logged `password authentication failed`.

The fix was to create the secret deterministically without trailing whitespace:

```bash
printf '%s' 'DrillPass2026' > secrets/drill7/db_password
```

Because `POSTGRES_PASSWORD_FILE` is used only when a new PostgreSQL data
directory is initialized, I recreated the temporary drill volume after fixing
the file. The API then returned `200 OK` with `{"status":"ready","db":"connected"}`.
The AfricAir API itself reads `_FILE` secrets with `.trim()`, but callers should
still generate exact secret bytes and must not assume every consuming image
trims files in the same way. Evidence is in
`evidence/drills/07-password-newline.txt`.

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
