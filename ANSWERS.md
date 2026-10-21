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
