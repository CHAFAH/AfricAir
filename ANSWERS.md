## Project 2 — Task 6: Read-only Nginx root cause
- what originally failed;
- why it failed;
- why `/tmp` is writable;
- how the fix preserves `--read-only`.

The `nginxinc/nginx-unprivileged` image uses an entrypoint script to process configuration templates from `/etc/nginx/templates/`. By default, the rendered configuration is written to `/etc/nginx/conf.d/`.

When the container runs with a read-only root filesystem, `/etc/nginx/conf.d/` cannot be modified. The entrypoint therefore cannot create the final Nginx configuration, leaving Nginx without the AfricAir server configuration.

This is fixed without disabling the read-only filesystem by setting:

```dockerfile
NGINX_ENVSUBST_OUTPUT_DIR=/tmp



## Project 2 — Task 7: Image sizes and layers

### Web image

The AfricAir web image is below the required 50 MB limit. Its largest layers are:

1. The pinned `nginxinc/nginx-unprivileged` Alpine base image, containing Nginx, Alpine libraries and runtime utilities.
2. The copied production `dist/` directory, containing the compiled JavaScript, CSS, airport data and static assets.
3. The Nginx configuration layer, containing the runtime template and read-only-compatible main configuration.

Node.js, pnpm, source code and development dependencies are absent because the final runtime stage copies only the compiled frontend into the Nginx image.

### API image

The AfricAir API image is below the required 120 MB limit. Its largest layers are:

1. The Node.js 22 Alpine base image, containing the Node runtime and required Alpine libraries.
2. Production `node_modules`, primarily PostgreSQL and Prometheus runtime dependencies and their transitive packages.
3. The compiled API, migrations and package metadata copied into the runtime stage.

TypeScript, Vite, React, frontend assets and source files are excluded from the API runtime image.




## Project 2 — Task 7: Image sizes and layers

# Web image

The AfricAir web image is below the required 50 MB limit. Its largest layers are:

1. The pinned `nginxinc/nginx-unprivileged` Alpine base image, containing Nginx, Alpine libraries and runtime utilities.
2. The copied production `dist/` directory, containing the compiled JavaScript, CSS, airport data and static assets.
3. The Nginx configuration layer, containing the runtime template and read-only-compatible main configuration.

Node.js, pnpm, source code and development dependencies are absent because the final runtime stage copies only the compiled frontend into the Nginx image.

=== WEB LAYERS ===
24.6kB | COPY --chown=101:101 deploy/nginx/default.co…
16.4kB | COPY --chown=101:101 deploy/nginx/nginx.conf…
1.47MB | COPY --chown=101:101 /app/dist/ /usr/share/n…

# API image

The AfricAir API image is below the required 120 MB limit. Its largest layers are:

1. The Node.js 22 Alpine base image, containing the Node runtime and required Alpine libraries.
2. Production `node_modules`, primarily PostgreSQL and Prometheus runtime dependencies and their transitive packages.
3. The compiled API, migrations and package metadata copied into the runtime stage.

TypeScript, Vite, React, frontend assets and source files are excluded from the API runtime image.

=== API LAYERS ===
16.4kB | COPY --chown=node:node /app/server/migration…
98.3kB | COPY --chown=node:node /app/server/dist/ ./d…
5.62MB | COPY --chown=node:node /prod/api/node_module…
12.3kB | COPY --chown=node:node /prod/api/package.jso…
8.19kB | WORKDIR /app




## Project 2 — Task 7.4: API source cache test

# BuildKit cache behaviour

After changing `src/components/Home.tsx`, the dependency-install layers in both Dockerfiles remained cached because `package.json`, `server/package.json`, `pnpm-lock.yaml` and `pnpm-workspace.yaml` had not changed. The source-copy and later test/build layers reran.

After changing `server/src/app.ts`, the API source-copy and API compilation layers reran, while its dependency-install layer remained cached.

The web Dockerfile also reran its shared workspace test and build stages. This is because it copies the complete workspace and `pnpm check` validates both the frontend and API packages. This is conservative but ensures an API TypeScript failure also blocks the web image build. The dependency layer still remained cached because no package manifest or lockfile changed.

A BuildKit cache mount is different from a cached image layer. A cached layer skips the entire Dockerfile instruction when its inputs are unchanged. A cache mount preserves reusable package files, such as pnpm’s content-addressable store, even when the installation instruction must run again.



## Task 8 — Image scanning, SBOMs and linting

# Vulnerability scanning

Both production images were scanned with Trivy using the `HIGH,CRITICAL`
severity gate and `--exit-code 1`.

The original web runtime was based on an outdated Nginx/Alpine image and
reported 59 fixable findings: 57 HIGH and 2 CRITICAL. I updated the runtime
base image and pinned it by digest. The final result was:

```text
africair-web:compose
Total: 0 (HIGH: 0, CRITICAL: 0)
Exit code: 0


No `.trivyignore` file was needed.

# SBOM comparison

Syft generated SPDX JSON SBOMs for both images.

- africair-web: 72 packages
- africair-api: 41 packages

The web image contains more packages because Nginx requires additional operating-system libraries for HTTP, TLS, compression and static-file handling. The API image contains Node.js and only the API production dependencies. Build tools and package managers are excluded from its runtime.

### Dockerfile linting

Both Dockerfiles passed Hadolint without warnings or errors.

- Dockerfile.web exit code: 0
- Dockerfile.api exit code: 0
