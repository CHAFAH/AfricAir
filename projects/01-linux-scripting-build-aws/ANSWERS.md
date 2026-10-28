# Project 1 — Answers

Infrastructure for this project is in Terraform: `infra/terraform/envs/shared` (modules `hosting`
for the EC2 server and `static-site` for S3 + CloudFront + the deployer role). See
[`infra/terraform/README.md`](../../infra/terraform/README.md).

> **Evidence status.** Every script, the nginx site, the systemd units and the API under systemd were
> exercised on an Ubuntu 24.04 host running systemd as PID 1 (a privileged container, built from
> `ubuntu:24.04`), using artifacts from `build.sh`. Results are quoted below. Output that only an
> AWS deployment can produce (EC2 security group, SSM, CloudFront) is marked **capture after
> `terraform apply`**, with the exact command to run.

## Part A — the build

Commands: `corepack enable && pnpm install --frozen-lockfile && pnpm build`.

**1. Files in `dist/`**

```text
     352  dist/africair-mark.svg
  289186  dist/assets/airports-BrwcO3ZA.js
   44666  dist/assets/index-CBj_wgb2.css
  117585  dist/assets/index-D8WT6gtn.js
  159767  dist/assets/index.es-C05bQb9q.js
  584775  dist/assets/pdf-o1MWN_TF.js
  223309  dist/assets/react-CpYK3H_K.js
     791  dist/index.html
      60  dist/manus-routes.json
```

The hash is derived from the file's content. A file that changes gets a new name, so every file
under `assets/` can be cached for a year (`immutable`), and `index.html` (never cached) decides which
names a page loads. Without hashes, a deploy would leave browsers and CDNs holding the old
`index.js` under the same URL: users would get a mix of old and new code (old JS against a new
`index.html`, or the other way round), and the only fix would be short cache lifetimes, i.e. slow
pages for everyone.

**2. `tsc -b` vs `vite build`.** `tsc -b` type-checks the project references (`tsconfig.app.json`,
`tsconfig.node.json`) and fails on type errors. With `noEmit` it writes only `*.tsbuildinfo`
incremental state, no JavaScript. `vite build` bundles, transpiles (esbuild), minifies and
content-hashes the app with Rollup, and it is the step that writes `dist/`. Vite strips types without
checking them, which is why the build runs `tsc -b` first.

**3. `--frozen-lockfile`.** It installs exactly what `pnpm-lock.yaml` records and *fails* if
`package.json` and the lockfile disagree, instead of quietly re-resolving. After deleting the lockfile,
`pnpm install` resolves every range again (`vite ^6.0.11` → the newest 6.x, plus new versions of
hundreds of transitive packages) and writes a different lockfile. In CI that means a build is no
longer reproducible from its commit: two builds of the same SHA can ship different code, a new
upstream release (or a compromised one) enters production without review, and "works on my
machine" bugs appear. The lockfile is part of the source code.

**4. `manualChunks` / `chunkSizeWarningLimit`.** `manualChunks` puts jsPDF (+ html2canvas, DOMPurify)
into `pdf-*.js`, the airport dataset into `airports-*.js` and React into `react-*.js`. Each changes
at its own pace, so a typical app change only invalidates the small `index-*.js` and the big chunks
stay cached. `chunkSizeWarningLimit: 700` (kB) raises Vite's 500 kB warning threshold because the PDF
chunk is about 585 kB on purpose. The largest chunk is **`pdf-*.js`: 585 kB, 173 kB gzipped**. It
matters on 3G (~50–100 kB/s effective) because `index.html` *modulepreloads* it (the import in
`src/lib/pdf.ts` is static), so roughly 2–3 seconds of a first visit are spent downloading a PDF
library that is only needed after a booking is confirmed. A dynamic `import('jspdf')` at confirmation
time would remove it from the critical path.

**5. Why `pnpm dev` must never serve production.** (1) It serves untransformed source modules
on demand, unbundled and unminified, with hundreds of requests per page and a JIT TypeScript/JSX
transform: slow and CPU-heavy. (2) It is a development server with HMR websockets, permissive
settings (`host 0.0.0.0`, a proxy, and file-system access to the project) and none of the hardening,
caching headers or graceful reloads of nginx/CloudFront. Vite's dev server has had file-disclosure
CVEs precisely because it is not meant to be exposed. (3) It needs the whole toolchain, source and
`node_modules` on the server, and it ties availability to a single Node process with no
health-checked, atomic release.

**6. Size.** `du -sh dist` → **1.4 MB**. `tar czf - dist | wc -c` → **460 800 bytes (~450 kB)**.

## Part B — Linux server

### B2 `bootstrap.sh`: idempotency

First run (abridged; fresh Ubuntu 24.04):

```text
[bootstrap.sh] changed: installed packages: nginx git ufw jq curl gnupg postgresql postgresql-client
[bootstrap.sh] changed: installed Node.js v22.23.4
[bootstrap.sh] changed: corepack enabled (pnpm shim)
[bootstrap.sh] changed: system user africair
[bootstrap.sh] changed: directory /opt/africair/releases (755 africair:africair)
...
[bootstrap.sh] changed: ufw enabled (default deny incoming)
[bootstrap.sh] changed: secret /etc/africair/secrets/admin_token (generated)
[bootstrap.sh] changed: postgres role africair_app
[bootstrap.sh] changed: postgres database africair
[bootstrap.sh] done: 11 change(s)
```

Second run:

```text
[bootstrap.sh] done: no changes
exit=0
```

Two edge cases the test host exposed, now handled: nginx can be installed but not running (the
script starts it instead of reloading it), and ufw's `OpenSSH` profile only exists once
`openssh-server` is installed (the script falls back to `22/tcp`).

### B3 `build.sh`

`scripts/ops/build.sh --help` documents the exit codes: 10 checkout, 20 install, 30 checks/tests,
40 build/packaging. A bad ref returned `exit=10`. On a branch whose workspace lacked the pnpm deploy
setting, packaging failed with `exit=40`. `version.json` is written with `jq -n --arg ...`:

```json
{ "commit": "7f0125339eefbfe223f88d03e9d6cef5e228d6ec", "ref": "main",
  "builtAt": "2026-10-27T23:19:00Z", "builtBy": "chafahsani@…", "nodeVersion": "v26.0.0" }
```

The API artifact holds `dist/`, `migrations/`, `package.json`, `build.env` (`GIT_SHA=…`) and
production-only `node_modules` (only `pg` and `prom-client`): **1.5 MB**, down from 12 MB. Getting
there needed `injectWorkspacePackages: true` in `pnpm-workspace.yaml`, because with `--legacy`,
`pnpm deploy` also copied the workspace root's React and jsPDF. Artifacts are created with
`COPYFILE_DISABLE=1 tar --no-xattrs`: on macOS, bsdtar otherwise adds `._001_init.sql` AppleDouble
files, which the migration runner then tried to execute as SQL.

### B4 deploy / rollback

**Why a plain `ln -sfn` is not atomic.** `ln -sfn new current` calls `unlink("current")` and then
`symlink("new", "current")`. Between the two system calls `current` does not exist, and nginx
requests in that window get 404s. Creating the new link under a temporary name and then
`mv -T tmp current` uses a single `rename(2)`, which atomically replaces the directory entry: every
request sees either the old target or the new one.

Results on the test host:

```text
$ deploy.sh africair-122a5a6.tar.gz
[deploy.sh] front end live: 20261027T232859Z-122a5a6
[deploy.sh] API live: 20261027T232859Z-122a5a6
$ curl -s localhost/version.json | jq -r .commit   → 122a5a6dd4c1…
$ curl -s localhost/api/config  | jq -r .commit    → 122a5a6dd4c1…

$ deploy.sh /tmp/bad.tar.gz            # wrong .sha256
[deploy.sh] ERROR: checksum mismatch or missing .sha256 for /tmp/bad.tar.gz: nothing changed
exit=2 current unchanged: yes

$ deploy.sh broken/africair-122a5a6.tar.gz    # API entrypoint throws on start
[deploy.sh] previous API release is ready
[deploy.sh] ERROR: /api/readyz did not return 200 within 30s: API rolled back to releases/20261027T232926Z-122a5a6
exit=4

$ rollback.sh
[rollback.sh] /opt/africair/current: 20261027T232859Z-122a5a6 -> 20261027T232733Z-7f01253
$ curl -s localhost/version.json | jq -r .commit   → 7f0125339eef…  (previous commit)
```

Retention: `prune` keeps the newest `KEEP_RELEASES` (5) directories and never deletes the one
`current` points to.

### B5 nginx

`deploy/nginx/africair.conf` plus `africair-security-headers.conf`. Checked on the test host:

```text
$ curl -fsS localhost/healthz                                  → ok
$ curl -sI localhost/assets/<x>.js | grep -i cache-control     → Cache-Control: public, max-age=31536000, immutable
$ curl -sI localhost/ | grep -iE 'cache-control|x-content-type|content-security'
Cache-Control: no-cache
X-Content-Type-Options: nosniff
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com data:; img-src 'self' data: blob:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'
```

Notes:

- `add_header` is inherited only by locations that set **no** `add_header` of their own. Every
  location that adds `Cache-Control` therefore includes the security-header snippet again; without
  that, `/assets/` would silently lose the CSP.
- `location /` uses `try_files $uri $uri/ =404`. With only `$uri`, `/` itself returned **404**,
  because `/` is a directory and only `$uri/` lets `index` map it to `/index.html`.
- `style-src 'unsafe-inline'` is required by jsPDF and runtime style attributes. `font-src` and
  `style-src` allow Google Fonts. `img-src data: blob:` is for the generated PDF.
- The JSON log uses `escape=json`, so a user agent containing quotes can't break the line.
- `logrotate`: daily, rotate 14, compress (plus `delaycompress`), with `kill -USR1` to reopen the logs.

### B6 health check (systemd timer)

```text
$ journalctl -t africair-health --since "10 min ago" -o cat
check failed (1/3): web /healthz api /api/healthz
check failed (2/3): web /healthz api /api/healthz
check failed (3/3): web /healthz api /api/healthz
WARNING: 3 consecutive failures, reloading nginx
$ systemctl list-timers africair-health.timer
NEXT                         LEFT LAST                         PASSED UNIT
Tue 2026-10-27 23:31:00 UTC  51s  Tue 2026-10-27 23:30:00 UTC  8s ago africair-health.timer
```

The counter lives in `/var/lib/africair/health.failures`. A healthy run resets it and logs `recovered`.

### B7 log report

```text
== Requests by status class ==        == Top 10 paths ==
     63 2xx                               36 /api/readyz
     23 4xx                               27 /api/config
     35 5xx                               24 /
                                           9 /version.json
== Requests per minute, last hour (UTC) ==
2026-10-27T23:29     35
2026-10-27T23:30     69
```

(The 5xx are the deliberately broken API release returning 502 during the rollback drill.)

### B8 API under systemd

`/api/config` on the test host:

```json
{"appEnv":"staging","commit":"122a5a6…","storage":"database","serviceFeeUsd":9,"defaultCurrency":"KES",
 "announcement":{"text":"Welcome to the AfricAir staging server","level":"info"},
 "secrets":{"db":{"status":"connected","source":"file"},"admin":"file","promo":2}}
```

```text
$ sudo -u africair cat /etc/africair/secrets/admin_token → cat: /etc/africair/secrets/admin_token: Permission denied
$ sudo -u africair bash -c 'echo test > /etc/x'          → bash: /etc/x: Permission denied
$ systemctl show africair-api -p User,NoNewPrivileges,ProtectSystem,MemoryMax
User=africair NoNewPrivileges=yes ProtectSystem=strict MemoryMax=268435456
$ curl -s -o /dev/null -w '%{http_code}' localhost/metrics → 404   (not proxied)
```

Port 9464 is closed from outside twice over: ufw only allows 22/80/443, and the EC2 security group
(Terraform) only opens 80/443 (plus 22 from your IP if enabled). **Capture after `terraform apply`:**
`curl -s -m 3 http://<ec2>:9464/metrics; echo $?` → `28` (timeout).

`LoadCredential=` copies each root-only file into `/run/credentials/africair-api.service/` (a private
mount visible only to that service) and the app reads `ADMIN_TOKEN_FILE=%d/admin_token`. The unit
also sets `InaccessiblePaths=/etc/africair/secrets`, so even a bug in the app can't read the
originals.

> The container used for testing cannot mount systemd credentials (even `SetCredential=` gives no
> file under Docker Desktop), so the API path was verified there with a **test-only** drop-in that
> pointed `*_FILE` at africair-readable copies. On EC2 the units run unchanged. **Capture:**
> `systemctl show africair-api -p LoadCredential` and `/#/status` showing all three secrets as
> *mounted file*.

**Rotating `admin_token` without a restart: it does not take effect.** `LoadCredential=` copies the
file **once, when the service starts**. The app re-reads `ADMIN_TOKEN_FILE` every
`SECRET_REFRESH_SECONDS`, but that path is the private copy, which never changes. A rotation needs
`systemctl restart africair-api` (or `systemctl reload`, if the unit refreshed credentials on reload).
Contrast with Kubernetes in Project 4, where the kubelet updates the mounted file in place.

**`TimeoutStopSec=20`.** On SIGTERM the API fails readiness, waits `SHUTDOWN_DELAY_MS` (5 s) so load
balancers stop sending traffic, then drains open connections, force-exiting after 10 s. systemd
SIGKILLs a service that hasn't stopped within `TimeoutStopSec`, so it must be longer than 5 s + 10 s,
or in-flight requests are cut.

**The show-the-effect steps** (capture as screenshots on EC2 after `terraform apply`):
change `ANNOUNCEMENT_TEXT` in `/etc/africair/api.env` → `systemctl restart africair-api` → the banner
changes; `MAINTENANCE_MODE=true` → *Confirm booking* is disabled; book with `SAVE10` → the discount
line, and the booking appears at `/#/admin`.

## Part C — S3 + CloudFront

Terraform (`modules/static-site`) creates a private bucket (Block Public Access on, versioning,
SSE-S3), a CloudFront distribution with OAC, `index.html` as the default root object,
`redirect-to-https`, and a response-headers policy with the same security headers as nginx. It also
creates a deployer role with exactly the policy in `deploy/iam/deployer-policy.json`.

**Publish order (`publish-s3.sh`).** Assets go first, because a new `index.html` that went live
before its hashed assets existed would reference files that 404. `version.json` then `index.html`
come next, and the switch to the new release happens at that moment. Stale files are removed only
after that, because users still running the old `index.html` keep lazily loading old chunks (and
CloudFront may still serve the old `index.html` until the invalidation completes); deleting them
first would break those sessions. Versioning keeps the deleted objects recoverable.

**Invalidate only `/index.html`, `/version.json` and `/`, never `/*`.** Hashed assets never change
under the same name, so invalidating them is pointless. `/*` would also evict every edge cache
worldwide, causing a thundering herd to the origin and slower first loads, and paths beyond the free
monthly allowance are billed. `/` is included because a request for the root is cached under the key
`/`, even though it is served from the default root object.

**Least privilege, proved.** Capture after `terraform apply`:

```bash
eval "$(aws sts assume-role --role-arn "$(terraform -chdir=infra/terraform/envs/shared output -raw static_deployer_role_arn)" \
  --role-session-name proof --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text \
  | awk '{print "export AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3}')"
aws s3 ls s3://some-other-bucket   # → An error occurred (AccessDenied) when calling the ListObjectsV2 operation
```

**Static mode.** On CloudFront, `/#/status` reports *API not reachable*: `/api/*` isn't routed
anywhere, so the app falls back to its built-in defaults. Compared with EC2, the static site has:

- no server-side bookings (only the browser's local storage, so a booking can't be found from
  another device);
- no admin page;
- no promo codes;
- no announcement, maintenance mode, environment banner or runtime brand;
- default currency and fee only.

**Why S3 can never keep a secret.** Everything in the bucket is sent to whoever requests it, and
anything a static file uses must be in the file, so in every user's browser. A secret needs code that
runs somewhere the user can't read (the API), which decides what to reveal.

## Knowledge check

**1. `nginx -s reload` vs `systemctl restart nginx`.** A reload (SIGHUP) makes the master re-read
the config and start new workers. Old workers stop accepting connections but **finish their in-flight
requests**, then exit. Nothing is dropped, and an invalid config is rejected while the old workers keep
running. A restart stops the master and all workers, terminating every open connection (in-flight
requests fail, keep-alives reset), and leaves the site down if the new config is broken.

**2. `rm -rf $RELEASE_DIR/` with `RELEASE_DIR` unset.** Without `set -u` it expands to `rm -rf /`.
With `set -u` bash aborts with `RELEASE_DIR: unbound variable` before running `rm`. Other protections
in these scripts: `${var:?}` in every `rm -rf` path (fails even if the variable is set but empty),
quoting, deleting only names produced by `find … -mindepth 1 -maxdepth 1` under a known parent, never
deleting the target of `current`, GNU `rm`'s `--preserve-root` default, and running the app as an
unprivileged user.

**3. Why a static SPA still needs a server-side health check.** "The files exist" isn't "users can
load the site". nginx can be stopped, misconfigured after a reload, out of disk, or serving the wrong
`root` (for example a dangling `current` symlink). A check from the server's point of view
(`/healthz`, and `/version.json` matching the deployed commit) is what lets the deploy verify itself
and roll back, lets the timer self-heal, and gives load balancers something to probe. The API part
(`/api/healthz`) obviously needs one.

**4. EC2 + nginx vs S3 + CloudFront**

| | EC2 + nginx | S3 + CloudFront |
|---|---|---|
| Cost at 1M requests/month (~1.5 MB first load, mostly cached) | t3.small ≈ $15/month + EBS ≈ $1.6 + egress (~50–100 GB ≈ $5–9). **~$22–26**, fixed whether traffic is 0 or 1M | 1M HTTPS requests ≈ $1.00 + ~50–100 GB transfer ≈ $4–8 (the always-free tier covers 1 TB and 10M requests) + S3 cents. **~$0–9**, usage-based |
| Scaling | Vertical, or you build an ALB + ASG; one instance is a single point of failure | 600+ edge locations; scales automatically |
| TLS | certbot on the box, renewal is yours | ACM certificate, free, auto-renewed |
| Rollbacks | `rollback.sh` (seconds, atomic symlink) | Re-publish the previous build, or use S3 object versions plus an invalidation (minutes to propagate) |
| Blast radius | A compromised instance exposes the OS, the database and the secrets; one AZ | No server to compromise; risk is limited to the bucket's contents and the deployer role; CloudFront is global |
| Dynamic API | Yes (the API runs on the box) | No: static mode only |

**5. Old content after a CloudFront deploy.** (1) The invalidation hasn't finished, or doesn't cover
`/` (`aws cloudfront get-invalidation --id …`; `curl -sI https://<cf>/` shows `X-Cache: Hit from cloudfront` and an old `Age`). (2)
The browser cached `index.html` because the object's `Cache-Control` is wrong (`aws s3api
head-object --bucket … --key index.html` → `CacheControl: no-cache`; DevTools shows *from disk
cache*). (3) The upload went somewhere else, or failed half-way: wrong bucket or prefix, or a stale
build directory (`curl https://<cf>/version.json` vs the commit you built; `aws s3 ls`; compare
`dist/index.html` with the object). A service worker or an intermediate proxy is a fourth suspect.

## Deliverables checklist

- [x] `scripts/ops/`: `bootstrap.sh`, `build.sh`, `deploy.sh`, `rollback.sh`, `healthcheck.sh`,
      `report.sh`, `publish-s3.sh` (+ `common.sh`); `shellcheck -x` clean
- [x] `deploy/nginx/africair.conf` (+ security-header snippet), `deploy/logrotate/africair`
- [x] `deploy/systemd/africair-api.service`, `africair-migrate.service`, `africair-health.service|.timer`
- [x] `deploy/iam/deployer-policy.json`, `deploy/config/api.env.example`
- [x] Terraform for the EC2 host, S3, CloudFront and the deployer role (`infra/terraform/envs/shared`)
- [ ] Screenshots from the real EC2/CloudFront deployment and the 5-minute demo recording
