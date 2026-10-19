# DevOps Warm-up & Build Analysis Answers

## 1. Dist Folder Analysis
File List: 
  To generate the clean structure of the distribution folder, run `ls -R dist/` in your terminal. The build produces an `index.html` file at the root, along with structured subdirectories in `dist/assets/` containing minified `.js` and `.css` files, alongside static assets.
Why hashes exist: Vite embeds content-driven content hashes (e.g., `index-C9j2x1A.js`) into filenames using asset-graph analysis. 
What breaks without them: Web browsers and CDNs aggressively cache static files. Without asset hashes, if you deploy a new version of the code using the exact same filenames, returning users will serve old components straight out of local disk storage. This results in critical, unpredictable frontend crashes.

## 2. Compiler vs Bundler Lifecycle
 `tsc -b` (TypeScript Project Build Mode): This acts as a compiler gateway. It performs strict, multi-package static type checking across workspaces and transpiles server-side Node.js TypeScript code into native JavaScript engines. It does "NOT" create client bundle chunks.
 `vite build`: This is an asset compiler and bundler. It traces the application import graph, strips out dead code (tree-shaking), combines modules, minifies strings, and compresses code for the user environment.
 Output Destination: `vite build` explicitly compiles and outputs the production files into the client `dist/` directory.

## 3. Lockfile Consistency & CI Risks
 Why `--frozen-lockfile`: This command flag forces the package manager engine to strictly cross-reference dependencies against `pnpm-lock.yaml`. If any modification is detected, it terminates the runtime workflow instantly.
 The Danger: Deleting `pnpm-lock.yaml` triggers an unpinned installation where dependencies fetch newer minor or patch updates from the open upstream registry. In a Continuous Integration (CI) context, this behavior introduces unverified, breaking upstream updates into production environments without developer oversight, turning builds highly non-deterministic.

## 4. Bundle Optimization & 3G Latency
 `manualChunks`: A configuration primitive that splits massive, third-party vendor code blocks (like React cores or layout utilities) out of the main application file into dedicated asynchronous scripts.
 `chunkSizeWarningLimit`: A hard optimization flag setting a memory threshold (default 500kb). If an individual script asset breaches this threshold, Vite emits visual optimization alerts during compiling.
 The Largest Chunk: The main Vendor framework file is the largest chunk. 
 3G Impact: On low-bandwidth, high-latency 3G networks, a single oversized JavaScript chunk paralyzes the main browser rendering engine. The browser cannot parse or initialize the DOM tree until that entire asset finishes downloading over the wire, causing long Time-to-Interactive (TTI) blocks where users stare at an unresponsive white screen.

## 5. Why `pnpm dev` is Forbidden in Production
   1. Dynamic Compilation Overhead: The local dev server does not serve optimized files; it runs an active on-the-fly compiler tracking source file modules and injecting Hot Module Replacement (HMR) debug logic, draining host CPU and RAM resources under concurrent requests.
   2. Missing Production Hardening: It completely lacks modern network security optimizations, rate-limiting handlers, HTTP cache control directives, strict transport policies, or compression engines designed to withstand basic DDoS profiles.
   3. Single-Threaded Saturation: The internal web server is unclustered. A minor burst in simultaneous public connections will completely lock down the single-threaded Node event loop, causing immediate application degradation.

## 6. Storage Footprint Metrics
   Total Folder Volume: 1.4M  dist/
   Gzipped Stream Footprint: 450771



## B4. Why the release switch uses a temporary symlink

Running `ln -sfn <release> /opt/africair/current` directly is not a safe
atomic release switch when `current` already resolves to a directory. Its
behaviour can depend on path resolution and it exposes the public pointer to
the link replacement operation itself. The deployment instead creates a new
temporary symlink beside `current`, then uses `mv -T` to rename that prepared
link over `current`. A rename within the same filesystem is atomic, so Nginx
sees either the complete old release or the complete new release, never a
partially updated pointer.

## B8. API service and credential behaviour

`TimeoutStopSec=20s` is deliberately longer than `SHUTDOWN_DELAY_MS=5000`.
The API first fails readiness, waits five seconds for traffic to drain, then
closes its HTTP and database connections. The longer systemd timeout lets that
graceful shutdown finish instead of sending SIGKILL too early.

`LoadCredential=` copies each secret into a protected credential directory
when the service starts. The unprivileged `africair` user cannot read the
root-owned source files under `/etc/africair/secrets`. Rotating a source file
does not change the already loaded credential copy, so the service must be
restarted before the new admin token takes effect. Once restarted, the API's
file-secret reader notices future changes to its credential copy according to
`SECRET_REFRESH_SECONDS`, but systemd only refreshes that copy at service start.

## Part C. S3 and CloudFront publishing decisions

The publisher uploads content-addressed `assets/` first, then the mutable
`version.json` and `index.html`, and only then deletes stale objects. Publishing
the entry point before its referenced assets could briefly send users to files
that do not exist. Deleting old files before the new index is live creates the
opposite mixed state: users with the old index can receive 404 responses for
its assets. Keeping the old assets until the new entry point is present makes
both generations usable during the transition.

Only `/index.html` and `/version.json` are invalidated. Their names are stable,
so edge caches must revalidate them after a deployment. Asset filenames contain
content hashes; changed bytes produce a new URL, while unchanged bytes can stay
cached for a year. Invalidating `/*` would discard safe immutable cache entries,
increase origin traffic and cost, and make the deployment slower without
improving correctness.

## Knowledge check

### 1. `nginx -s reload` versus `systemctl restart nginx`

`nginx -s reload` asks the running master process to validate and load the new
configuration. It starts new workers and lets old workers finish in-flight
requests before exiting, so a valid reload is graceful. `systemctl restart`
stops the service and starts it again. That replaces the master process and can
interrupt active connections or create a short period with no listener. A
deployment therefore uses `nginx -t` followed by a reload.

### 2. An unset `RELEASE_DIR` in `rm -rf "$RELEASE_DIR/"`

With `set -u`, expanding an unset `RELEASE_DIR` terminates the script instead
of turning it into an empty string and risking `rm -rf /`. Additional defenses
are to use fixed parent directories, quote every expansion, validate that the
resolved target is a release below `/opt/africair/releases`, reject empty or
unexpected values, and never construct destructive targets from unchecked
input. The deployment's strict release-name pattern and bounded `find` depth
also limit cleanup to known release directories.

### 3. Why a static SPA needs a server-side health check

Static files can exist while the service is still unusable: Nginx may have an
invalid configuration, its process may be down, the `current` symlink may be
broken, permissions may deny reads, or the load balancer/CDN route may point at
the wrong origin. A server-side `/healthz` checks the delivery path that users
actually depend on and gives monitoring and deployment automation a stable,
cheap endpoint independent of client-side JavaScript.

### 4. EC2 with Nginx versus S3 with CloudFront

For one million small static requests per month, S3 and CloudFront are normally
far cheaper because there is no continuously running VM; the current CloudFront
Free plan includes one million requests and 100 GB of transfer, subject to plan
eligibility, while storage remains usage-based. A `t3.small` in us-east-1 is
about $0.0208 per hour, roughly $15.18 for 730 hours before EBS, snapshots and
internet transfer. Exact totals depend on region, bytes transferred, cache hit
ratio, free-tier/plan eligibility and taxes, so the AWS calculator should be
used for a real forecast. Pricing references:
[CloudFront pricing](https://aws.amazon.com/cloudfront/pricing/),
[S3 pricing](https://aws.amazon.com/s3/pricing/), and
[EC2 T3 pricing](https://aws.amazon.com/ec2/instance-types/t3/).

CloudFront and S3 scale automatically across edge locations and include managed
TLS at the distribution; EC2 needs capacity planning, patching, certificates
and process monitoring. EC2 rollback is an immediate atomic symlink switch.
S3 rollback uses object versions or republishes a previous build, followed by
invalidation of the mutable files. An EC2 host failure or bad server change can
affect the whole application, while a bad S3 upload is limited to static
content but can be distributed globally very quickly by CloudFront. Versioning,
OAC, staged publication and narrowly scoped credentials reduce that blast
radius.

### 5. CloudFront shows old content after deployment

1. **The mutable files were not invalidated.** Check the CloudFront invalidation
   history and request `/index.html` and `/version.json`, inspecting `Age`,
   `ETag`, `Last-Modified` and `X-Cache`. Create the two-path invalidation if it
   is missing or failed.
2. **The wrong bucket, prefix or distribution was published.** Compare the
   commit in the local `dist/version.json`, the S3 object's body/version ID, and
   `https://<distribution>/version.json`; then inspect the distribution's origin
   and default behavior.
3. **The browser still has an old document or asset.** Test in a private window
   and with `curl`, inspect browser cache/service-worker state, and confirm that
   `index.html` is `no-cache` while hashed assets are immutable. If an asset's
   contents changed without its filename changing, fix the build rather than
   invalidating every object.

## Acceptance evidence

The following checks were run against EC2 instance `i-086f7326e4a35c325`
(`18.234.34.186`) and CloudFront distribution `EBEOM9U4WUFE0`
(`d3hrq91hjpb64p.cloudfront.net`) on 19 October 2026. Secret values are
intentionally omitted.

### EC2 health, version and caching

```console
$ curl -fsS http://127.0.0.1/healthz
ok

$ curl -fsS http://127.0.0.1/version.json | jq .
{
  "commit": "47a9667d292eee38631492e2b7a8786c331674e2",
  "ref": "devops-submission-taiwo",
  "builtAt": "2026-10-19T06:23:03Z",
  "builtBy": "ubuntu@ip-172-31-26-123",
  "nodeVersion": "v22.23.3"
}

$ curl -sI http://127.0.0.1/assets/airports-DafaOCNH.js | grep -i cache-control
Cache-Control: public, max-age=31536000, immutable
```

The root document returned `Cache-Control: no-cache` plus the required headers:

```console
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
X-Frame-Options: DENY
Content-Security-Policy: default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com data:; img-src 'self' data: blob:; connect-src 'self'; worker-src 'self' blob:
Cache-Control: no-cache
```

### Release layout and rejection/rollback safety

```console
$ ls -l /opt/africair/current
lrwxrwxrwx 1 root root 47 Oct 19 06:31 /opt/africair/current -> /opt/africair/releases/20261019T063146Z-47a9667

$ readlink -f /opt/africair/current
/opt/africair/releases/20261019T063146Z-47a9667
```

A copied artifact with an intentionally invalid SHA-256 file was rejected with
a non-zero exit status. Comparing `readlink -f /opt/africair/current` before
and after printed `PASS: deployment remained unchanged`. A subsequent
`rollback.sh` run switched atomically to the previous healthy release;
`/healthz` remained `ok` and `version.json` reported the previous commit. The
newest healthy artifact was then redeployed.

### Service isolation, API and credentials

```console
$ sudo -u africair bash -c 'echo test > /etc/x'
bash: line 1: /etc/x: Permission denied

$ sudo -u africair cat /etc/africair/secrets/admin_token
cat: /etc/africair/secrets/admin_token: Permission denied

$ systemctl show africair-api.service -p User -p ProtectSystem -p NoNewPrivileges
User=africair
ProtectSystem=strict
NoNewPrivileges=yes
```

The redacted `/api/config` result was:

```json
{
  "appEnv": "staging",
  "storage": "database",
  "secrets": {
    "database": { "status": "connected", "source": "file" },
    "adminToken": { "configured": true, "source": "file" },
    "promoCodes": { "count": 2, "source": "file" }
  }
}
```

Both Node listeners were bound to loopback (`127.0.0.1:4000` and
`127.0.0.1:9464`). An external request to port 9464 failed while public port 80
continued to return `ok`. Rotating the root-owned admin-token source left the
active fingerprint at `88944fe4` before restart; after restarting the service
it changed to `34c516cc`, demonstrating systemd credential-copy semantics.

The staging UI showed PostgreSQL storage and all three credentials sourced from
files. Maintenance mode disabled booking while enabled. With it disabled, a
booking using `SAVE10` received the 10% discount, was stored in PostgreSQL, and
appeared on the token-protected admin page.

### Health timer, log report and static analysis

The systemd health timer ran every minute and logged with the
`africair-health` tag. The JSON access-log report produced top client IPs,
status-class counts, top paths, and last-hour requests per minute. ShellCheck
passed every operations script:

```console
$ shellcheck scripts/ops/*.sh
$ echo "$?"
0
```

### S3, CloudFront and least privilege

Bucket `africair-taiwo-981750769980` was verified with all four S3 Block Public
Access values set to `true`, versioning `Enabled`, and default encryption
`AES256` (SSE-S3). Its bucket policy grants `s3:GetObject` only to the
CloudFront service principal when the source ARN is:

```text
arn:aws:cloudfront::981750769980:distribution/EBEOM9U4WUFE0
```

The OAC-backed distribution redirects HTTP to HTTPS, uses `index.html` as the
default root object, and attaches `AfricAir-security-headers`. CloudFront
responses included `X-Cache` and the B5 security headers. Hashed assets returned
`Cache-Control: public,max-age=31536000,immutable`; `index.html` and
`version.json` returned `no-cache`.

The `africair-static-deployer` identity successfully listed only the intended
bucket. Listing another bucket and calling `s3api list-buckets` both returned
`AccessDenied`, proving that the policy does not grant account-wide S3 access.
The publishing script uploaded the site and created an invalidation containing
only `/index.html` and `/version.json`.

The complete Playwright suite passed with:

```console
$ BASE_URL=https://d3hrq91hjpb64p.cloudfront.net pnpm test:e2e
# all tests passed
```

At `/#/status`, the CloudFront deployment correctly reported that the API was
unreachable and used browser-only static storage. Unlike EC2, it has no
PostgreSQL-backed bookings, admin view, runtime announcement/maintenance
settings, or server-side promo validation. S3 stores and returns object bytes;
any secret placed in a static JavaScript bundle, HTML file or downloadable
configuration would be readable by every visitor. Secrets therefore require a
trusted server-side runtime such as the EC2 API (or another serverless compute
service), not S3 alone.



## Five-minute deployment and automatic rollback demonstration

I recorded the stable deployment before starting the test:

- Stable release: `/opt/africair/releases/20261019T104609Z-f408ec9`
- Stable commit: `f408ec9e0c53af3590ff22229f771e88520bf8a8`

I deliberately created an invalid isolated Nginx configuration. `nginx -t`
failed with:

```text
unknown directive "this" in /etc/nginx/conf.d/africair-demo-break.conf:1
nginx: configuration file /etc/nginx/nginx.conf test failed


I then attempted to deploy artifact africair-c6be25b.tar.gz. The deployment
failed safely:

ERROR: nginx configuration test failed; rolling back.
Rolled back to /opt/africair/releases/20261019T104609Z-f408ec9
Deployment exit code: 5

The release and commit before and after the failed deployment were identical:

Before release: /opt/africair/releases/20261019T104609Z-f408ec9
After release:  /opt/africair/releases/20261019T104609Z-f408ec9
Before commit:  f408ec9e0c53af3590ff22229f771e88520bf8a8
After commit:   f408ec9e0c53af3590ff22229f771e88520bf8a8
PASS: automatic rollback restored the stable release

After deleting the deliberately invalid configuration, nginx -t passed,
Nginx reloaded successfully, and /healthz returned ok.
I then deployed the new artifact successfully:

Deployment successful: 20261019T110725Z-c6be25b
Commit: c6be25b859051dbde70520708aac11a238a060ef
Current: /opt/africair/releases/20261019T110725Z-c6be25b

This demonstrates that a failed deployment does not leave the application
pointing at a broken release and that the corrected artifact can subsequently
be deployed successfully.

Save it, then commit and push:

```bash
git add ANSWERS.md
git diff --cached --check
git commit -m "Document automatic rollback demonstration"
git push submission-fork devops-submission-taiwo