# DevOps Warm-up & Build Analysis Answers

1. Dist Folder Analysis
File List: 
  To generate the clean structure of the distribution folder, run `ls -R dist/` in your terminal. The build produces an `index.html` file at the root, along with structured subdirectories in `dist/assets/` containing minified `.js` and `.css` files, alongside static assets.
Why hashes exist: Vite embeds content-driven content hashes (e.g., `index-C9j2x1A.js`) into filenames using asset-graph analysis. 
What breaks without them: Web browsers and CDNs aggressively cache static files. Without asset hashes, if you deploy a new version of the code using the exact same filenames, returning users will serve old components straight out of local disk storage. This results in critical, unpredictable frontend crashes.

2. Compiler vs Bundler Lifecycle
 `tsc -b` (TypeScript Project Build Mode): This acts as a compiler gateway. It performs strict, multi-package static type checking across workspaces and transpiles server-side Node.js TypeScript code into native JavaScript engines. It does "NOT" create client bundle chunks.
 `vite build`: This is an asset compiler and bundler. It traces the application import graph, strips out dead code (tree-shaking), combines modules, minifies strings, and compresses code for the user environment.
 Output Destination: `vite build` explicitly compiles and outputs the production files into the client `dist/` directory.

3. Lockfile Consistency & CI Risks
 Why `--frozen-lockfile`: This command flag forces the package manager engine to strictly cross-reference dependencies against `pnpm-lock.yaml`. If any modification is detected, it terminates the runtime workflow instantly.
 The Danger: Deleting `pnpm-lock.yaml` triggers an unpinned installation where dependencies fetch newer minor or patch updates from the open upstream registry. In a Continuous Integration (CI) context, this behavior introduces unverified, breaking upstream updates into production environments without developer oversight, turning builds highly non-deterministic.

4. Bundle Optimization & 3G Latency
 `manualChunks`: A configuration primitive that splits massive, third-party vendor code blocks (like React cores or layout utilities) out of the main application file into dedicated asynchronous scripts.
 `chunkSizeWarningLimit`: A hard optimization flag setting a memory threshold (default 500kb). If an individual script asset breaches this threshold, Vite emits visual optimization alerts during compiling.
 The Largest Chunk: The main Vendor framework file is the largest chunk. 
 3G Impact: On low-bandwidth, high-latency 3G networks, a single oversized JavaScript chunk paralyzes the main browser rendering engine. The browser cannot parse or initialize the DOM tree until that entire asset finishes downloading over the wire, causing long Time-to-Interactive (TTI) blocks where users stare at an unresponsive white screen.

5. Why `pnpm dev` is Forbidden in Production
   1. Dynamic Compilation Overhead: The local dev server does not serve optimized files; it runs an active on-the-fly compiler tracking source file modules and injecting Hot Module Replacement (HMR) debug logic, draining host CPU and RAM resources under concurrent requests.
   2. Missing Production Hardening: It completely lacks modern network security optimizations, rate-limiting handlers, HTTP cache control directives, strict transport policies, or compression engines designed to withstand basic DDoS profiles.
   3. Single-Threaded Saturation: The internal web server is unclustered. A minor burst in simultaneous public connections will completely lock down the single-threaded Node event loop, causing immediate application degradation.

6. Storage Footprint Metrics
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
