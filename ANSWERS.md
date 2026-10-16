# Part A — Understand the Build (Answers)

## Question 1: List every file in `dist/`. Why do the file names under `dist/assets/` contain hashes? What would break if they didn't?

- **Files in `dist/`:**
	- `dist/index.html`
	- `dist/assets/index-CBj_wgb2.css`
	- `dist/assets/index-D8WT6gtn.js`
	- `dist/assets/index.es-C05bQb9q.js`
	- `dist/assets/react-CpYK3H_K.js`
	- `dist/assets/airports-Brwc03ZA.js`
	- `dist/assets/pdf-1mWN_TF.js`
- **Why hashes are used:** Hashes provide content-based cache busting: when file contents change, the filename changes.
- **What would break if they didn't:** Browsers and CDNs may keep serving old cached assets after an update, causing users to see a stale or mismatched application until the cache expires or is cleared.

## Question 2: What do `tsc -b` and `vite build` each do? Which one produces files in `dist/`?

- **`tsc -b`:** Runs the TypeScript compiler in project-build mode, checking and compiling referenced TypeScript projects according to their configuration.
- **`vite build`:** Bundles and optimizes the application for production.
- **Which produces files in `dist/`:** `vite build` generates the production output in `dist/`.

## Question 3: Why `--frozen-lockfile`? Delete `pnpm-lock.yaml`, reinstall, and describe what changed and why that is dangerous in CI.

- **Why `--frozen-lockfile`:** It makes installation fail if the lockfile would need to change, keeping dependency resolution reproducible.
- **What changes if deleted:** A normal install resolves versions from the package manifest and current registry state, then creates a new lockfile. Exact changes depend on the manifest and available versions.
- **Why it is dangerous in CI:** Dependency versions can drift between runs, making builds less reproducible and potentially introducing incompatibilities or bugs. (The lockfile should not be deleted in a real CI workflow.)

## Question 4: Open `vite.config.ts`. What do `manualChunks` and `chunkSizeWarningLimit` do? Which chunk is the largest, and why does that matter to a user on a 3G connection?

- **`manualChunks`:** Controls how modules are grouped into output chunks, enabling deliberate code splitting.
- **`chunkSizeWarningLimit`:** Sets the chunk-size threshold, in kilobytes, above which Vite emits a warning.
- **Largest chunk:** `pdf-1mWN_TF.js` (approximately 584.78 kB / 173.48 kB gzipped).
- **Why it matters on 3G:** A large chunk takes longer to transfer on a slow connection and can delay the features that depend on it. Lazy loading can avoid delaying initial rendering if the chunk is not needed immediately.

## Question 5: Why must `pnpm dev` never be used to serve production traffic? Give three reasons.

1. **Development workflow:** It is intended for development, including HMR and diagnostics, not as a production server.
2. **Production delivery:** It does not provide the production build's optimized static assets and may expose development-oriented error details.
3. **Operations:** It is not intended to provide the deployment-grade security, reliability, scaling, and caching expected for production traffic. Serve the production build with an appropriate production server or CDN instead.

## Question 6: Total size of `dist/`, and its size gzipped (`tar czf - dist | wc -c`)?

- **Gzipped tar stream size:** `460800` bytes. This is the byte count of the compressed tar archive, not the uncompressed directory size.
## B4. Why `ln -sfn` alone is not atomic

`ln -sfn target link` on Linux is implemented as `unlink(link)` followed by `symlink(target, link)`. Between those two syscalls there is a window where `link` does not exist — any process reading it (nginx, a health check) will get `ENOENT`. The `mv -T` approach creates the new symlink under a temporary name first, then atomically replaces the old one in a single `rename(2)` syscall, which the kernel guarantees is atomic.

## B8. Why `TimeoutStopSec` must exceed `SHUTDOWN_DELAY_MS`

`SHUTDOWN_DELAY_MS=5000` means the API deliberately waits 5 seconds after receiving `SIGTERM` before it stops accepting connections — this gives the load balancer time to drain in-flight requests. If `TimeoutStopSec` were shorter than 5 seconds, systemd would send `SIGKILL` before the graceful drain completes, cutting off active requests. Setting it to `15s` gives the API its full 5-second drain window plus headroom.

## B6. Health monitoring with systemd

### `systemctl list-timers`

```
NEXT                        LEFT LAST                           PASSED UNIT                  ACTIVATES
Fri 2026-10-16 04:04:56 UTC  59s Fri 2026-10-16 04:03:56 UTC 560ms ago africair-health.timer africair-health.service

1 timers listed.
```

### `journalctl -t africair-health --since "10 min ago"`

```
Oct 16 04:01:47 ip-172-31-22-202 africair-health[11467]: OK: health check passed
Oct 16 04:02:49 ip-172-31-22-202 africair-health[11527]: OK: health check passed
Oct 16 04:03:56 ip-172-31-22-202 africair-health[11537]: OK: health check passed
```


## Knowledge Check

### 1. What is the difference between `nginx -s reload` and `systemctl restart nginx` for in-flight requests?

`nginx -s reload` sends `SIGHUP` to the master process, which spawns new worker processes with the updated config and gracefully drains the old workers — in-flight requests complete normally. `systemctl restart nginx` stops and starts the process entirely, immediately killing all workers and dropping any in-flight connections. Always use `nginx -s reload` (or `systemctl reload nginx`) in production.

### 2. Your deploy script ran `rm -rf $RELEASE_DIR/` with `RELEASE_DIR` unset. What would `set -u` have done? What else protects you?

`set -u` treats unset variables as errors and immediately exits the script before `rm -rf` runs, preventing the expansion to `rm -rf /`. Additional protections: `set -e` exits on any non-zero command; a guard like `[[ -n "$RELEASE_DIR" ]]` before the `rm`; and never running deploy scripts as root so the blast radius is limited.

### 3. Why does a static SPA still need a server-side health check?

The SPA itself is just files — nginx could be misconfigured, the disk could be full, or the symlink could be broken while the process is still running. A health check at `/healthz` verifies that nginx is actually serving the right content, not just that the process is alive. It also gives the load balancer and monitoring systems a reliable signal for automated rollback.

### 4. Compare EC2 + nginx with S3 + CloudFront: cost at 1M requests/month, scaling, TLS, rollbacks, blast radius.

| | EC2 + nginx | S3 + CloudFront |
|---|---|---|
| Cost at 1M req/month | ~$15–20/mo (t3.small always-on) | ~$0.10 (S3) + ~$0.85 (CF) ≈ $1/mo |
| Scaling | Manual — resize instance or add load balancer | Automatic — CloudFront scales globally |
| TLS | Manual — certbot or ACM via ALB | Built-in — ACM certificate free |
| Rollbacks | Instant — symlink switch + nginx reload | Slow — re-upload + invalidation (minutes) |
| Blast radius | Single AZ — instance failure = outage | Global CDN — no single point of failure |

### 5. A user reports the site shows old content after a deploy to CloudFront. List three possible causes and how you'd check each one.

1. **CloudFront edge cache not invalidated:** Check with `aws cloudfront list-invalidations --distribution-id <id>` — if no recent invalidation exists or it's still `InProgress`, the edge is serving stale content. Fix: create an invalidation for `/index.html` and `/version.json`.
2. **Browser cache:** The user's browser cached `index.html` with a long TTL. Check with DevTools → Network → disable cache and hard reload. Fix: ensure `index.html` is served with `Cache-Control: no-cache`.
3. **S3 upload order was wrong:** `index.html` was uploaded before the new assets, so the old `index.html` still references old asset filenames that were deleted. Check `version.json` on CloudFront vs the deployed SHA. Fix: always upload assets first, then `index.html`.

## Part C — CloudFront acceptance checks

### `curl -sI https://d3c9tcwe5ddvzb.cloudfront.net/ | grep -i x-cache`

```
x-cache: Miss from cloudfront
```

### `aws s3api get-public-access-block --bucket africair-static-887095766978`

```json
{
    "PublicAccessBlockConfiguration": {
        "BlockPublicAcls": true,
        "IgnorePublicAcls": true,
        "BlockPublicPolicy": true,
        "RestrictPublicBuckets": true
    }
}
```

### e2e suite against CloudFront

```
25 passed, 1 failed
[mobile] › e2e/runtime-config.spec.ts — API not reachable (expected: static mode only)
```

The 1 failure is expected — CloudFront serves static files only. The runtime-config test checks for API-driven environment variables which are only available on the EC2 deployment. S3 alone can never keep a secret because all files in a bucket are ultimately served as static HTTP responses — there is no server-side execution to protect secrets from the client.

### Deployer AccessDenied proof

```
=== can list own bucket ===
africair-mark.svg  index.html  version.json  assets/

=== AccessDenied listing all buckets ===
An error occurred (AccessDenied): User: arn:aws:iam::887095766978:user/africair-deployer
is not authorized to perform: s3:ListAllMyBuckets
```
