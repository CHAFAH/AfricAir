# GitHub Actions vs CircleCI for AfricAir

Both platforms run the same pipeline: `.github/workflows/{ci,release,refresh-airports}.yml` and
`.circleci/config.yml`. Both use the same scripts (`scripts/ci/*.sh`) and AWS roles
(`terraform/ci.tf`: one OIDC role, main branch only).

| | GitHub Actions | CircleCI |
|---|---|---|
| **Syntax and reuse** | A workflow per trigger. Reuse comes from a composite action (`.github/actions/setup`: node, corepack, store cache, install), reusable workflows and marketplace actions. Matrices are first-class. | One `config.yml` with `executors` (node, node+Postgres, Playwright, machine), `commands` (`setup`, `aws-oidc`), parameterised jobs, `matrix` and orbs (`circleci/aws-cli`, `eddiewebb/queue`). Pipeline logic sits in one file, which is easier to read top to bottom. |
| **Caching** | `actions/cache` keyed on `hashFiles('pnpm-lock.yaml')`, plus `type=gha` BuildKit cache for images. 10 GB per repo, evicted after 7 days unused. | `save_cache`/`restore_cache` keyed on `checksum "pnpm-lock.yaml"`. Immutable keys (a key is never overwritten). Docker layer caching is a paid machine option. |
| **Parallelism and test splitting** | Matrix: `project × shard` = 4 e2e jobs, each a full VM with its own setup. | `parallelism: 2` plus `$CIRCLE_NODE_INDEX`; `circleci tests split --split-by=timings` can balance by history. Less setup overhead per shard. |
| **Secrets and contexts** | Repo, org and environment secrets/variables. Environment secrets are only released to jobs that pass the environment's protection rules. | Project env vars and **contexts**, which can be restricted to security groups (`africair-production`). |
| **OIDC** | `permissions: id-token: write` + `aws-actions/configure-aws-credentials`. `sub` encodes ref or environment (`repo:CHAFAH/AfricAir:environment:production`). | `$CIRCLE_OIDC_TOKEN_V2` + `assume-role-with-web-identity`. `sub` encodes org, project, user, VCS origin and **ref** (`…/vcs-ref/refs/tags/v*`), so "tags only" is enforced by IAM itself. |
| **Approvals and environments** | `environment: production` with required reviewers, wait timers, deployment rules (tags `v*`) and a deployment URL/history in the UI. | A `type: approval` job (anyone with write access can approve unless the following job's context is restricted) plus restricted contexts. No built-in deployment history. |
| **Concurrency** | `concurrency:` groups: cancel superseded PR runs; `deploy-production` queues. | "Auto-cancel redundant workflows" (project setting, not on the default branch). Serialised deploys need an orb (`queue/until_front_of_line`) or a paid feature. |
| **Self-hosted runners** | Actions Runner Controller on Kubernetes (autoscaling, ephemeral). Free to run; you pay for the infrastructure. | Self-hosted runners via a container agent or machine runner; available on paid plans, limited on Free. |
| **Developer experience** | Lives in the repo UI: checks on PRs, job summaries, artifacts, the release in one place; `act` for local runs. | Faster, clearer UI for pipelines, SSH into failed jobs (`Rerun with SSH`), insights on flaky tests and timings, and `circleci config validate` locally. |

## Pricing for ~300 builds/month

There are no pipeline runs yet, so this uses an *estimated* duration, to be replaced with measured
numbers after the first week. A main-branch pipeline is about 35 job-minutes: verify 2, unit 2 × 4,
build 2, e2e 4 × 4, images 8 (deploy and smoke excluded). That gives **≈ 10,500 job-minutes/month**.

- **GitHub Actions:** free for a public repository. For a private repo on Team, 3,000 included
  minutes, then about $0.008/min for Linux 2-core: **≈ $60/month**.
- **CircleCI:** Free covers 30,000 credits. Docker medium is 10 credits/min and the machine executor
  and `large` cost more, so ≈ 120k–140k credits on Performance, **≈ $70–85/month**.

Check current price lists before deciding: both vendors change them yearly.

## Recommendation: GitHub Actions

Choose **GitHub Actions** as the primary platform:

- **Environments are the deciding feature.** Production approval, the tags-only rule, deployment
  URLs, history and environment-scoped OIDC all come in one built-in, auditable mechanism. On
  CircleCI the same needs an approval job, a restricted context and an orb for serialisation.
- **No second account or vendor.** Permissions, secrets and audit logs stay with the code; the
  refresh-airports PR workflow and the GitOps bump use the same tokens and apps; it costs nothing for
  a public repo.
- **CircleCI is better at** splitting tests by timing, SSH debugging and pipeline UX. Its OIDC `sub`
  also encodes the ref even inside a context, which makes tag-only trust policies simpler.

Trade-offs accepted:

- e2e shards on GitHub pay more setup time per job.
- Cache eviction is less predictable (7 days).
- Long, complex workflows are harder to read than one `config.yml`.

If the team grows to many repositories with heavy test suites, or needs Arm/GPU fleets without
running its own runners, look at CircleCI again. Until then, keep `.circleci/config.yml` green as a
fallback: it costs nothing while it sits on the Free plan.
