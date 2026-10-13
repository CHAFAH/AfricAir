# Project 2 — Containerise AfricAir with Docker

> **Domains assessed:** Dockerfiles & multi-stage builds · BuildKit caching · image hardening · runtime configuration · Docker networking & Compose · image scanning & SBOMs · registries (Docker Hub, Amazon ECR)
> **Suggested duration:** 1 week · **Team size:** 1–2 · **Builds on:** Project 1 (nginx config, build process)

## Scenario

The platform team wants **one immutable image** that is built once and promoted unchanged from dev to staging to production. The image must be:

- small,
- non-root,
- secure enough to run with a read-only filesystem,
- able to prove what's inside it,
- and its behaviour must be verified automatically by the existing Playwright suite, running **in another container**.

## Know the application

| Fact | Detail |
|---|---|
| Build | `corepack enable && pnpm install --frozen-lockfile && pnpm build` → static files in `dist/` |
| Gates | `pnpm check` (types) and `pnpm test` (unit tests) must pass before an image is produced |
| Runtime | Static files only: any web server works. You will use **`nginxinc/nginx-unprivileged`**, which listens on **8080** as UID **101**. |
| E2E tests | `BASE_URL=http://<host>:<port> pnpm test:e2e`. Playwright **1.64.0**; matching image: `mcr.microsoft.com/playwright:v1.64.0-noble` |
| Lockfile inputs | `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml` |

## Tasks

### 1. Multi-stage `Dockerfile`

Create a `Dockerfile` at the repo root with **named stages**:

| Stage | Purpose |
|---|---|
| `deps` | Node LTS base. Copy **only** the lockfile inputs, then `pnpm install --frozen-lockfile`, using a BuildKit **cache mount** for the pnpm store (`--mount=type=cache`). |
| `test` | `FROM deps`. Copy the source, then run `pnpm check` and `pnpm test`. **The image build must fail if a test fails.** |
| `build` | Run `pnpm build` and generate `dist/version.json` from build args. |
| `runtime` | `nginxinc/nginx-unprivileged:<pinned-version>-alpine`. Copy only `dist/` and your nginx config. No Node, no source, no `node_modules`. |

Requirements:

- Pin every base image to a specific version. **Stretch:** pin by digest, and explain how you'd keep digests updated (Renovate or Dependabot).
- Build args `VERSION`, `GIT_SHA` and `BUILD_DATE` populate both `/version.json` and **OCI labels** (`org.opencontainers.image.revision`, `.version`, `.created`, `.source`).
- Add a `HEALTHCHECK` that calls `/healthz`. Alpine has BusyBox `wget`, not `curl`.
- `EXPOSE 8080`, and **no** `USER root` in the final stage.

### 2. `.dockerignore`

Exclude `node_modules`, `dist`, `.git`, `test-results`, `playwright-report`, and any env or secret files. Prove the effect: compare the build-context size with and without the file (BuildKit prints `transferring context`).

### 3. nginx configuration in the image

Reuse your Project 1 config, adapted to port 8080 and a non-root user:

- `/healthz`, gzip, `immutable` caching for `/assets/`, `no-cache` for `index.html` and `version.json`, and security headers;
- **runtime configuration**: use the image's built-in **envsubst templates** (`/etc/nginx/templates/*.template`) so that `APP_ENV=staging` adds the response header `X-Environment: staging`. The **same image** must report different environments depending only on `-e APP_ENV=...`.

### 4. Prove "build once, run anywhere"

```bash
docker build -t africair:dev --build-arg GIT_SHA=$(git rev-parse HEAD) --build-arg VERSION=0.1.0 --build-arg BUILD_DATE=$(date -u +%FT%TZ) .
docker run -d --name stg  -p 8081:8080 -e APP_ENV=staging    africair:dev
docker run -d --name prod -p 8082:8080 -e APP_ENV=production africair:dev
curl -sI localhost:8081 | grep X-Environment   # staging
curl -sI localhost:8082 | grep X-Environment   # production
```

### 5. Hardening: it must still work like this

```bash
docker run -d --name hardened -p 8080:8080 \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  --memory 64m --cpus 0.25 --pids-limit 100 \
  -e APP_ENV=hardened africair:dev
```

> ⚠️ This **will** break at first. The envsubst entrypoint writes into `/etc/nginx/conf.d`, which is read-only now. Find out why and fix it **without** dropping `--read-only`. Hint: read the image's `docker-entrypoint.d` scripts and look for `NGINX_ENVSUBST_OUTPUT_DIR`. Document the root cause in `ANSWERS.md`.

### 6. Size and layers

- The final image must be **under 50 MB**. Report `docker images` and `docker history --no-trunc` and explain the three largest layers.
- **Cache proof:** change one line in `src/components/Home.tsx` and rebuild. Show that the `deps` layer is `CACHED` and only later steps re-run. Then change `package.json` and explain the difference.
- Compare the final image with a naive single-stage `node:22` image that runs `pnpm dev`. Record size, CVE count and startup time.

### 7. Scan and SBOM

- `trivy image --severity HIGH,CRITICAL --exit-code 1 africair:dev` must pass, or each finding must be documented and justified in `.trivyignore` with a reason.
- Produce an SBOM, with `docker buildx build --sbom=true` or `syft`, and answer: which packages in the runtime image come from the base image, and which from you?
- Check the Dockerfile with `hadolint Dockerfile` (zero warnings, or justified ignores).

### 8. Docker Compose: test the container with a container

Create `compose.yaml` with:

| Service | Details |
|---|---|
| `web` | Your image (built from the Dockerfile). Healthcheck. **2 replicas**. |
| `proxy` | An nginx or Traefik reverse proxy on host port `80`, load-balancing to `web` by service name. Add `X-Upstream: $upstream_addr` so you can **see** requests alternate between replicas. |
| `e2e` | `mcr.microsoft.com/playwright:v1.64.0-noble`, repo mounted at `/work`. Runs `corepack enable && pnpm install --frozen-lockfile && BASE_URL=http://proxy pnpm test:e2e`. Starts only when `proxy` is healthy (`depends_on: condition: service_healthy`). |

- Use a **user-defined network**. Show that `web` is **not** reachable from the host directly, only through `proxy`.
- One command runs the whole suite and returns the test exit code:
  ```bash
  docker compose up --build --exit-code-from e2e
  ```
- Break a test on purpose (e.g. change an expected heading) and show the command exits non-zero.

### 9. Registries

- **Multi-arch:** build for `linux/amd64` and `linux/arm64` with `docker buildx` and push to **Docker Hub**. Show the manifest list with `docker buildx imagetools inspect`.
- **Amazon ECR:**
  - create a private repository with **scan on push**, **immutable tags**, and a lifecycle policy that keeps the last 10 tagged images and expires untagged ones after 1 day;
  - push the image tagged `<git-sha>` and `0.1.0`;
  - pull it back on your Project 1 EC2 instance using its **instance role**, not access keys.
- **Tag strategy:** explain in `ANSWERS.md` why `latest` is never deployed, and how `sha`, `semver` and `env` tags relate.

## Debugging drills

Reproduce each one, capture the error, explain it, and fix it:

1. The container runs, but every page returns **403**. Hint: file ownership or permissions after `COPY`.
2. You change the listen port to `80` with the unprivileged image and the container exits immediately.
3. `docker compose up` passes locally, but the `e2e` service fails with `ECONNREFUSED` on a colleague's slower laptop.
4. The image works on your Mac (arm64) but crashes with `exec format error` on EC2 (amd64).
5. A rebuild after a one-line CSS change takes as long as a clean build. Find and fix the layer-ordering mistake.

## Acceptance checks (the instructor will run these)

```bash
docker build -t check .                                         # succeeds; fails if you break a unit test
docker image inspect check --format '{{.Config.User}}'          # non-root (101)
docker image inspect check --format '{{json .Config.Labels}}'   # OCI labels present
docker images check --format '{{.Size}}'                        # < 50MB
docker run --rm --entrypoint sh check -c 'ls /usr/share/nginx/html; which node || echo "no node"'
# run the hardened command from task 5, then:
curl -fsS localhost:8080/healthz && curl -s localhost:8080/version.json | jq .
docker inspect --format '{{.State.Health.Status}}' hardened     # healthy
trivy image --severity CRITICAL --exit-code 1 check
docker compose up --build --exit-code-from e2e; echo $?          # 0
```

## Knowledge check (`ANSWERS.md`)

1. What is the difference between `CMD` and `ENTRYPOINT`, and how do they interact in the nginx image?
2. Why does copying lockfiles before the source speed up builds? What is a cache mount, and how does it differ from a layer?
3. `COPY . .` vs `ADD`: when, if ever, should you use `ADD`?
4. Why is `--read-only` valuable, and what typically needs a `tmpfs`?
5. Explain `depends_on` with and without `condition: service_healthy`.
6. Why don't the Playwright tests run inside the runtime image?

## Deliverables

Pull request containing:

- `Dockerfile`, `.dockerignore`, `deploy/nginx/*.template`, `compose.yaml`, optional `.trivyignore` and `.hadolint.yaml`
- `docs/docker.md` with the commands to build, run, test and push
- `ANSWERS.md` with the evidence for every task and drill
- links to the Docker Hub and ECR images

## Grading rubric (100 pts)

| Area | Points |
|---|---|
| Multi-stage design, tests gate the build, cache efficiency | 20 |
| Final image: size, non-root, labels, healthcheck, `version.json` | 15 |
| Runtime config via templates (same image, many envs) | 10 |
| Hardened run (read-only, caps, limits) incl. root-cause write-up | 15 |
| Compose: networking, replicas behind proxy, e2e exit code | 15 |
| Scanning, SBOM, hadolint | 10 |
| Registries: multi-arch, ECR lifecycle/immutability, instance-role pull | 10 |
| Debugging drills | 5 |

## Cost and cleanup

ECR storage costs cents. Delete the repository, or keep it for Projects 3 and 4. Prune locally with `docker system prune -a`.
