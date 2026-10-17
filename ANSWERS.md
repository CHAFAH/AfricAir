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
   