# Project 3 — Answers

| File | Purpose |
|---|---|
| `.github/actions/setup/action.yml` | Composite action: Node, corepack, pnpm store cache keyed on the lockfile, frozen install |
| `.github/workflows/ci.yml` | PR + main: verify → unit (Node 20/22 + Postgres service) · build → e2e (2 shards × desktop/mobile) · images (build, Trivy, push on main) → staging deploy + smoke → GitOps bump |
| `.github/workflows/release.yml` | Tag `vX.Y.Z` → promote by digest → `environment: production` (approval) → deploy → smoke → GitHub Release |
| `.github/workflows/refresh-airports.yml` | Weekly: `pnpm data:airports`, test, build; opens a PR only if `airports.json` changed |
| `.circleci/config.yml` | The same pipeline: executors, commands, orbs, `parallelism`, approval, restricted context |
| `scripts/ci/deploy-ec2.sh` | Deploys a tag to the staging or production EC2 host through **SSM Run Command** (no SSH, no keys) |
| `scripts/ci/promote-images.sh` | `ecr batch-get-image` + `put-image`: adds `vX.Y.Z` to the manifest of `:<sha>` and verifies the digests match |
| `scripts/ci/smoke.sh` | `/healthz`, `/version.json` and `/api/config` all report the expected commit; `/api/readyz` is 200 |
| `deploy/ec2/` | What runs on each host: a Compose stack using the ECR images; secrets come from Secrets Manager through the instance role |
| `deploy/iam/*.json` | GitHub and CircleCI trust policies and the CI deployer policy (rendered by `infra/terraform/modules/ci-oidc`) |

**Targets.** Terraform (`modules/foundation`, applied from `envs/staging`) creates one small EC2 container host per environment
(`Env=staging`, `Env=production`). Each runs the same two images, so `/version.json` and
`/api/config` show exactly which commit is live. Project 4 moves staging to EKS. From then on,
Project 5's Argo CD deploys it from `gitops/` and CI only bumps the image tag there (`gitops-bump`).

> **Evidence status.** Validated locally:
> - `actionlint` passes on all workflows;
> - `shellcheck` passes on every script;
> - every step the pipelines run (check, audit, unit tests including the PostgreSQL suite against
>   Postgres 16, build, e2e against the built site, image builds, Trivy, hadolint) passes locally.
>
> Still to capture: the run URLs, timings, branch-protection screenshot and failure drills. They
> need the repository's Actions/CircleCI projects and the AWS roles from `terraform apply`.

## Setup checklist

1. `make tf-apply` (one apply for everything). Outputs: `ci_role_arns` (`github-ci`,
   `github-production`, `circleci-staging`, `circleci-production`), `ecr_repository_urls`,
   `deploy_bucket`.
2. GitHub, *Settings → Variables*: `AWS_REGION`, `AWS_CI_ROLE_ARN`, `AWS_PRODUCTION_ROLE_ARN`. These
   are role ARNs, not secrets, and no AWS keys are stored anywhere.
3. GitHub, *Environments*:
   - `staging`: no rules;
   - `production`: required reviewers (1+), deployment rule *selected tags* `v*`, "prevent
     self-review".
4. GitHub, *Rulesets* on `main`: require PRs with 1 review, and the status checks `verify`,
   `unit + API tests (node 20)`, `unit + API tests (node 22)`, `e2e (…)`, `images (build, scan)` and
   CircleCI's `ci/circleci: verify`. Bypass list: only the `africair-gitops` GitHub App. Repository
   variable `GITOPS_ENABLED=true` once Project 5 is live.
5. CircleCI:
   - contexts `africair-staging` (`AWS_ROLE_ARN` = the CircleCI staging role) and
     `africair-production` (the production role, restricted to a security group);
   - turn on "Auto-cancel redundant workflows";
   - put the org and project IDs into `terraform.tfvars` (`circleci_org_id`, `circleci_project_id`).
6. Secrets Manager values (the containers are created by Terraform, the values are never in state):
   ```bash
   for env in staging production; do
     aws secretsmanager put-secret-value --secret-id africair/ec2-$env/app --secret-string \
       "{\"ADMIN_TOKEN\":\"$(openssl rand -hex 24)\",\"PROMO_CODES\":\"SAVE10:10,AFRICA20:20\",\"DB_PASSWORD\":\"$(openssl rand -hex 24)\"}"
   done
   ```

## How each requirement is met

| # | Requirement | Implementation |
|---|---|---|
| 1 | Fail fast | `verify` runs `pnpm check` first (timeout 5 min); every other job `needs: verify`. Locally `pnpm check` takes ~6 s, plus ~40 s for checkout and a warm install. |
| 2 | Caching | pnpm store keyed on `hashFiles('pnpm-lock.yaml')` (`restore-keys` only seeds the store, the frozen install keeps it exact). BuildKit `type=gha` cache per image. Playwright browsers: the jobs run in `mcr.microsoft.com/playwright:v1.64.0-noble`, which ships them, so there's nothing to download. CircleCI uses `save_cache`/`restore_cache` on `checksum "pnpm-lock.yaml"`. |
| 3 | Matrix | `node: ["20", "22"]` (GH), `node: ["20.19", "22.21"]` (CircleCI) |
| 3b | Service containers | GH `services: postgres` with `pg_isready` health; CircleCI a secondary `cimg/postgres:16.4`. `TEST_DATABASE_URL` is set and a step greps the JUnit file for `API with PostgreSQL`. Locally that suite gave `Tests 11 passed (11)`, nothing skipped. |
| 4 | Parallel e2e | GH matrix `project × shard` (4 jobs); CircleCI `parallelism: 2` with `--shard=$((CIRCLE_NODE_INDEX+1))/$CIRCLE_NODE_TOTAL` |
| 5 | Reporting | JUnit from Vitest (`--reporter=junit`) and Playwright (`CI=true`) → `mikepenz/action-junit-report` annotations + job summary; `playwright-report/` and traces uploaded as artifacts. CircleCI: `store_test_results` + `store_artifacts`. |
| 6 | Build once, promote | Images are built only in `images` on main and pushed as `:<sha>`. `release.yml` runs `promote-images.sh`: `put-image` of the *same manifest*, then it checks that `describe-images` gives the same digest for `:<sha>` and `:vX.Y.Z`. Production pulls `:vX.Y.Z`, i.e. the digest built on main. |
| 6b | Version stamping | Build args `GIT_SHA=$GITHUB_SHA` (→ `version.json` and the API's `GIT_SHA`) and `VERSION=main-<short>`. In production `APP_VERSION` is set to the release tag at runtime (`deploy/ec2/compose.yaml`), so no rebuild is needed. `smoke.sh` checks both commits. |
| 7 | OIDC | See `deploy/iam/`. GH CI role: `sub` ∈ {`ref:refs/heads/main`, `environment:staging`, `ref:refs/tags/v*`} of this repo. GH production role: only `environment:production`. CircleCI: `aud` = org ID, `sub` pinned to project + `vcs-origin/github.com/CHAFAH/AfricAir` + `vcs-ref` main/tags. No `AWS_ACCESS_KEY_ID` anywhere. |
| 8 | Security gates | `pnpm audit --audit-level=high` (passes today, no exceptions); Trivy fails on CRITICAL (both images also pass HIGH locally); hadolint with `.hadolint.yaml` (one justified ignore) |
| 9 | Environments and approval | GH `environment: production` (required reviewers, tag rule, URL from the deploy step). CircleCI `hold` (`type: approval`) + context `africair-production` restricted to a group. |
| 10 | Concurrency | PR runs: `concurrency: ci-<pr>`, `cancel-in-progress` for PRs only. Deploys: `deploy-staging` and `deploy-production` groups with `cancel-in-progress: false` (queue, never parallel). CircleCI: auto-cancel + `queue/until_front_of_line`. |
| 11 | Reuse | GH composite `setup` action. CircleCI executors, commands (`setup`, `aws-oidc`), orbs `circleci/aws-cli` and `eddiewebb/queue`. |
| 12 | Branch protection | Ruleset in the checklist above (screenshot still to capture). |
| 13 | Data refresh | `refresh-airports.yml`: weekly cron + `workflow_dispatch`; `peter-evans/create-pull-request` with `add-paths: src/data/airports.json`, which does nothing (exits cleanly) when the file didn't change. |

## Failure drills (expected results; record the run URLs when you run them)

| # | Inject | Where it stops |
|---|---|---|
| 1 | TS error in `flights.ts` | `verify` → `pnpm check` fails; every other job is skipped. |
| 2 | Wrong price assertion in `flights.test.ts` | `unit` (both Node versions). The JUnit annotation names the test. The image build also fails, because tests run inside `docker build`. |
| 3 | Rename "Confirm booking" | `e2e` shards fail; the trace is in the `playwright-*` artifact (`trace: retain-on-failure`). |
| 4 | `NGINX_IMAGE=nginx:1.16-alpine` | The `images` Trivy CRITICAL gate fails before any push step runs. |
| 4b | Broken SQL in `001_init.sql` | `unit` → the "API with PostgreSQL" suite fails on `migrate()` against the service container. |
| 5 | Tag pushed from a fork | Its `sub` is `repo:<fork>/AfricAir:…`, not `repo:CHAFAH/AfricAir:…`, so `AssumeRoleWithWebIdentity` is denied ("Not authorized to perform sts:AssumeRoleWithWebIdentity"). Forks don't get `id-token: write` for PRs either. |
| 6 | Two tags 10 s apart | The second `deploy-production` shows "waiting for a pending job in the same concurrency group"; it never runs in parallel. |

## Knowledge check

**1. OIDC vs stored keys.** A stored `AWS_ACCESS_KEY_ID` is a long-lived bearer credential: it works
from anywhere until someone rotates it. It leaks through logs, forks, compromised actions or a
copied repo secret, and nobody can see who used it. With OIDC the CI platform signs a short-lived
JWT (minutes) for this specific job. AWS exchanges it for temporary credentials (1 hour) only after
the trust policy validates:

- the **issuer** (the OIDC provider registered in the account, i.e. its URL and TLS thumbprint);
- the signature;
- **`aud`** (`sts.amazonaws.com`, or the CircleCI org ID);
- **`sub`**: which repository and which ref or environment (and for CircleCI which project and
  VCS origin) the job runs for.

Nothing is stored, and every session is attributable in CloudTrail.

**2. Deploy a digest instead of rebuilding from the tag.** A rebuild is a different artifact: new base
image patches, different transitive dependencies, a different build environment, maybe a different
result. What was tested in staging would not be what runs in production. Deploying the digest built
on main guarantees bit-for-bit identity ("what you tested is what you ship"), is faster, and makes
rollbacks trivial (redeploy an older digest).

**3. `pull_request` vs `pull_request_target`.** `pull_request` runs the PR's code with a read-only token
and **no secrets** for forks. `pull_request_target` runs in the context of the *base* branch, with
secrets and a write token. That's dangerous if the workflow checks out and runs the PR's code (install
scripts, tests, build): an attacker's fork can then exfiltrate secrets or push to the repo. Use it only
for metadata tasks (labelling), never to build untrusted code.

**4. Avoiding stale dependencies.** The cache key contains `hashFiles('pnpm-lock.yaml')`, so any
dependency change produces a new key and a fresh save. `restore-keys` can only seed the store with an
older one. The install is always `--frozen-lockfile`, which installs exactly the lockfile's versions
(fetching what's missing) and fails if `package.json` and the lockfile disagree. The cache makes
installs faster but can never change *what* gets installed.

**5. Flaky tests.** A flaky test passes and fails on the same code (timing, ordering, shared state, the
network). Retries (`retries: 1` with `CI=true`) *hide* flakiness if you only look at the final status.
They *reveal* it if the report keeps the "flaky" outcome: Playwright marks tests that passed on retry
as `flaky`, and the JUnit/HTML reports show it. The pipeline should go green but **report the flaky
list** (job summary, a trend over time) so the tests get fixed or quarantined. This repo had one: the
mtime-based secret-rotation test, now fixed in `server/src/config.ts`.

**6. CircleCI workspace vs cache vs artifact.** A **workspace** passes files between jobs of the
*same workflow* (`persist_to_workspace`/`attach_workspace`: here `dist/` from `build` to `e2e`). A
**cache** reuses files *across workflows* to speed things up (the pnpm store), keyed and immutable,
and the job must work without it. An **artifact** is kept *for humans* after the run (Playwright
reports, traces, coverage), browsable in the UI and not meant as input to other jobs.
