# AfricAir

> Africa-first flight discovery and booking experience — bilingual, currency-aware, and designed around continent-wide journeys.

![AfricAir landing page](docs/images/africair-landing-page.png)

## Overview

AfricAir is a responsive flight booking site. Travellers search any airport in the world, compare outbound and return options, enter passenger details, review the full fare, and confirm. The confirmation creates a booking reference, e-ticket numbers and a downloadable PDF itinerary. **No payment is collected at any point.**

## Features

- **Worldwide coverage**: 4,008 airports with scheduled service in 233 countries and territories, from the [OurAirports](https://ourairports.com/data/) open dataset (public domain). All 247 countries and territories are listed on the Destinations page. Countries without an airport of their own (Monaco, Andorra, Vatican City…) point to their nearest gateways.
- **Airport search** by IATA code, city, airport name or country, in English or French, accent-insensitive, with keyboard navigation.
- **Search**: round trip or one way, 1–9 travellers (adults, children 2–11, infants under 2 on a lap), and four cabins. Dates are validated.
- **Results**: nonstop and connecting itineraries (via real hub airports), with durations based on distance, fares that vary by cabin, a ±3-day fare calendar, sort (best, cheapest, fastest, earliest), a stops filter, and expandable segment details with layovers.
- **Traveller details** with field-level validation: names, age rules per passenger type on the travel date, nationality, and passport/ID valid beyond the last flight. Contact email and phone are collected once per booking.
- **Review and confirm** with a fare breakdown per passenger type, taxes and service fee, and a required confirmation checkbox. No payment step.
- **PDF itinerary** (jsPDF): booking reference, status, every flight segment with airports, times, aircraft and baggage, travellers with e-ticket numbers and masked document numbers, fare summary, and important information. It downloads automatically on confirmation and can be downloaded again at any time.
- **My trips**: bookings are saved in the browser's local storage. Travellers can find a booking by reference and last name, view it, re-download the PDF, cancel it (the PDF is then marked cancelled) or remove it.
- **English / French** throughout, plus **35 display currencies** at indicative rates.
- **Shareable URLs**: a search lives in the URL (`#/flights?from=NBO&to=LOS&depart=…`), the browser back button works, and an in-progress booking survives a page reload.

## Runtime configuration, secrets and the API

The front end is static, so anything sent to the browser is public. Real configuration and secrets therefore live in a small **API** (`server/`, Node 22) that the site calls at `/api`. Without the API the site still works in **static mode** with built-in defaults (bookings stay in the browser).

**Environment variables → visible changes.** Restart the API after changing them.

| Variable | What changes in the app |
|---|---|
| `APP_ENV`, `APP_VERSION`, `GIT_SHA` | Coloured environment banner (hidden when `APP_ENV=production`); version on `/#/status` |
| `BRAND_NAME` | Brand in header, footer and browser tab |
| `ANNOUNCEMENT_TEXT`, `ANNOUNCEMENT_LEVEL` | Site-wide banner (info / warning / critical) |
| `MAINTENANCE_MODE=true` | Maintenance notice; *Confirm booking* is disabled |
| `SERVICE_FEE_USD` | The service fee line on every fare |
| `DEFAULT_LANGUAGE`, `DEFAULT_CURRENCY` | Starting language and currency for new visitors |
| `FEATURE_DESTINATIONS`, `FEATURE_MY_TRIPS`, `FEATURE_PROMO_CODES` | Show or hide those features |
| `SUPPORT_EMAIL`, `SUPPORT_PHONE` | Help link and footer |

**Secrets → new behaviour.** Each can be given as `NAME=value` or as `NAME_FILE=/path`. File secrets are re-read every `SECRET_REFRESH_SECONDS`, so a rotated Kubernetes Secret mounted as a volume takes effect **without a restart**; env-var secrets need one.

| Secret | Effect |
|---|---|
| `DATABASE_URL` (or `PG*` variables) | Bookings are saved to PostgreSQL and can be found from any device; enables the admin page data |
| `ADMIN_TOKEN` | Unlocks `/#/admin` (bookings table and revenue stats) |
| `PROMO_CODES` (e.g. `SAVE10:10,AFRICA20:20`) | Promo box on the review page; codes are checked on the server and never sent to the browser |

**`/#/status`** shows the configuration the deployment received, and for each secret whether it is configured, where it came from (file or env), when it was loaded, and a short fingerprint (hidden in production). It never shows secret values, so it is a safe way to check that a secret arrived.

| Endpoint | Purpose |
|---|---|
| `GET /api/healthz` | Liveness: the process is up |
| `GET /api/readyz` | Readiness: `503` while the database is unreachable or during shutdown |
| `GET /api/config` | Public runtime config and secret status (no values) |
| `POST /api/promo/validate` | Checks a promo code (rate-limited) |
| `POST /api/bookings`, `GET /api/bookings/:ref?lastName=`, `POST /api/bookings/:ref/cancel` | Server-side bookings |
| `GET /api/admin/bookings` | Admin list and stats (`Authorization: Bearer <ADMIN_TOKEN>`) |
| `GET :9464/metrics` | Prometheus metrics on a separate port (not exposed publicly) |

Run it locally (see `server/.env.example` for every variable):

```bash
pnpm build:api
DATABASE_URL=postgres://user:pass@localhost:5432/africair node server/dist/migrate.js   # create the schema
APP_ENV=dev ADMIN_TOKEN=dev-token PROMO_CODES=SAVE10:10 DATABASE_URL=... pnpm dev:api
pnpm dev                     # the Vite dev server proxies /api to localhost:4000
```

## Important note

There is no live airline inventory. Schedules and fares are generated deterministically for each route, date and cabin, so the same search always returns the same flights, and they are labelled as indicative. Carriers are fictional. Nothing is ticketed and no payment is taken. Connecting to real inventory (an NDC or GDS provider) would replace `src/lib/flights.ts`.

## Run locally

```bash
pnpm install
pnpm dev            # http://localhost:3000
```

## Quality checks

```bash
pnpm check          # TypeScript
pnpm test           # unit + API tests (set TEST_DATABASE_URL to include the PostgreSQL tests)
pnpm test:e2e       # Playwright: full booking flows on desktop + mobile (run `npx playwright install chromium` once)
pnpm build
```

## Run it on AWS

The full path from an empty AWS account to AfricAir on EKS, with Argo CD, monitoring and CI/CD.

> ⚠️ **Cost.** The EKS control plane, NAT gateway, nodes (4 × t3.large with the platform node group),
> RDS, two ALBs (staging and production) and three t3.small EC2 hosts cost roughly **$15–18 per day**.
> Run `make destroy` when you stop (step 13). A budget alert is part of the apply (`monthly_budget_usd`,
> default 400).

**Tools:** AWS CLI v2, Terraform ≥ 1.13, kubectl, Helm ≥ 3.14, the `argocd` CLI, Docker with buildx, `jq`, `openssl`,
`git`. `htpasswd` (from apache2-utils / httpd-tools) is used for the Argo CD password hash. Optional:
`tflint` and `trivy`, which `make tf-plan` runs as quality gates.

### 1. Authenticate with AWS

```bash
aws configure sso --profile africair        # IAM Identity Center (recommended), or: aws configure --profile africair
aws sso login --profile africair
export AWS_PROFILE=africair AWS_REGION=eu-west-1
aws sts get-caller-identity                 # the account and the role you are using
```

You need administrator rights in the account: the apply creates IAM roles, VPCs, EKS and RDS. For
Terraform's `admin_principal_arns` you need the **IAM role** ARN, not the session ARN that
`get-caller-identity` prints:

```bash
aws iam list-roles --query "Roles[?contains(RoleName,'AdministratorAccess')].Arn" --output text
```

### 2. Create the state bucket (once per account)

```bash
terraform -chdir=infra/terraform/bootstrap init
terraform -chdir=infra/terraform/bootstrap apply          # prints state_bucket = "africair-tfstate-<account-id>"
```

This is the only resource created outside the main apply: Terraform can't store its state in a
bucket it hasn't created yet. The bucket is versioned, encrypted and protected from `destroy`.

### 3. Configure and `terraform init`

```bash
cd infra/terraform/envs/staging
cp backend.hcl.example backend.hcl                 # set bucket = "africair-tfstate-<account-id>"
cp terraform.tfvars.example terraform.tfvars       # edit (below)
aws eks describe-cluster-versions --status STANDARD_SUPPORT --query 'clusterVersions[].clusterVersion'
cd -
make tf-init                                       # terraform init -backend-config=backend.hcl
```

In `terraform.tfvars`:

| Variable | Value |
|---|---|
| `team` | Short name used in resource names (`africair-<team>-staging`) |
| `kubernetes_version` | The newest version printed by `describe-cluster-versions` |
| `team_cidrs` | Your public IP as `x.x.x.x/32` (`curl -s https://checkip.amazonaws.com`): the only source allowed on the EKS API endpoint |
| `admin_principal_arns` | The IAM role from step 1 (cluster admin) |
| `owner`, `budget_email` | Owner tag; where the budget alerts go |
| `github_repository` | `owner/name` of your fork: the only repo whose workflows may use the CI roles |
| `circleci_org_id`, `circleci_project_id` | Only if you use CircleCI (step 12) |
| `domain_name`, `hosted_zone_id` | Optional: a Route 53 domain for HTTPS (`staging.`, `argocd.`, `grafana.` hosts) |

Nothing in `terraform.tfvars` or `backend.hcl` is secret.

### 4. Plan and apply: everything in one apply

```bash
make tf-plan       # fmt, validate, tflint, trivy config, then terraform plan -out=tfplan
make tf-apply      # applies the plan: about 25 minutes, EKS and RDS take longest
```

A single `terraform apply` of `infra/terraform/envs/staging` creates:

| Module | Resources |
|---|---|
| `foundation` (Projects 1–3) | ECR repositories `africair-web` and `africair-api` (immutable tags, scan on push, lifecycle) · GitHub Actions OIDC provider and roles `africair-github-ci` / `africair-github-production` (and the CircleCI ones if configured) · S3 deploy bucket · EC2 container hosts `africair-staging-host` and `africair-production-host` (Docker, managed through SSM) with their Secrets Manager containers `africair/ec2-<env>/app` · the Project 1 nginx server `africair-web-server` · private S3 bucket + CloudFront distribution (OAC, security headers) + deployer role · monthly AWS Budget with email alerts |
| `network` | VPC `10.40.0.0/16` across 3 AZs: 3 public, 3 private (/20) and 3 isolated database subnets, internet gateway, one NAT gateway, route tables, VPC flow logs (rejected traffic) |
| `eks` | EKS cluster with access entries (you as admin, the CI role as editor of `africair-staging`), KMS key for Secrets encryption, control-plane logs (7 days) · node groups `general` (2–4 × t3.large) and `platform` (tainted, for Argo CD and monitoring), AL2023, IMDSv2 hop limit 1 · add-ons: VPC CNI (prefix delegation, network policy), CoreDNS, kube-proxy, Pod Identity agent, EBS CSI driver, metrics-server |
| `database` | RDS PostgreSQL 16 (`db.t4g.micro`, private, `rds.force_ssl=1`, password managed by RDS in Secrets Manager), its security group (5432 from the cluster only), SSM parameters `/africair/staging/db/{host,port,name}` |
| `platform` | Secrets Manager containers `africair/{staging,production}/app` and `africair/platform/{argocd,grafana,alertmanager}` · S3 backup bucket · Pod Identity roles for External Secrets, the AWS Load Balancer Controller and the backup job · Helm releases: AWS Load Balancer Controller, External Secrets Operator, Reloader · default `gp3` StorageClass |
| root | ACM certificate with DNS validation (only with `domain_name`) |

### 5. Outputs

```bash
terraform -chdir=infra/terraform/envs/staging output
make configure     # writes the outputs into gitops/values/cluster.yaml and aws-load-balancer-controller.yaml
git add gitops/values && git commit -m "gitops: cluster values" && git push    # Argo CD reads them from Git
```

| Output | Used for |
|---|---|
| `kubeconfig_command` | Connecting kubectl (step 8) |
| `ecr_registry`, `ecr_repository_urls` | Pushing images (step 7) |
| `ci_role_arns` | GitHub variables and CircleCI contexts (step 12) |
| `rds_master_secret_arn`, `backup_bucket`, `vpc_id`, `cluster_name`, `acm_certificate_arn` | Written into the values files by `make configure` |
| `app_secret_arns`, `platform_secret_arns` | Secret containers to fill (step 6) |
| `container_hosts`, `deploy_bucket` | Project 3 CI deploy targets |
| `web_server`, `static_site`, `static_deployer_role_arn` | Projects 1 and 3 (see their ANSWERS) |
| `oidc_issuer_url`, `pod_identity_role_arns`, `region`, `database_subnet_cidrs` | Reference and troubleshooting |

### 6. Write the secret values

Terraform creates the secret *containers* only, so the values never appear in Terraform state:

```bash
aws secretsmanager put-secret-value --secret-id africair/staging/app --secret-string \
  "{\"ADMIN_TOKEN\":\"$(openssl rand -hex 24)\",\"PROMO_CODES\":\"SAVE10:10,AFRICA20:20\"}"
aws secretsmanager put-secret-value --secret-id africair/production/app --secret-string \
  "{\"ADMIN_TOKEN\":\"$(openssl rand -hex 24)\",\"PROMO_CODES\":\"SAVE10:10\"}"
# Argo CD, Grafana, Alertmanager (Slack webhooks; any https URL works to start with)
pw=$(openssl rand -base64 18); echo "Argo CD admin password: $pw"      # keep it in your password manager
hash=$(htpasswd -nbBC 10 "" "$pw" | tr -d ':\n' | sed 's/$2y/$2a/')
aws secretsmanager put-secret-value --secret-id africair/platform/argocd --secret-string \
  "{\"adminPasswordBcrypt\":\"$hash\",\"adminPasswordMtime\":\"$(date -u +%FT%TZ)\",\"slackToken\":\"xoxb-replace-me\"}"
aws secretsmanager put-secret-value --secret-id africair/platform/grafana --secret-string \
  "{\"adminUser\":\"admin\",\"adminPassword\":\"$(openssl rand -base64 18)\"}"
aws secretsmanager put-secret-value --secret-id africair/platform/alertmanager --secret-string \
  '{"slackWebhookUrl":"https://hooks.slack.com/services/REPLACE","pageWebhookUrl":"https://hooks.slack.com/services/REPLACE","deadmansSwitchUrl":"https://hc-ping.com/REPLACE"}'
# Project 3 EC2 hosts (only if you use the CI deploys to them)
for env in staging production; do
  aws secretsmanager put-secret-value --secret-id africair/ec2-$env/app --secret-string \
    "{\"ADMIN_TOKEN\":\"$(openssl rand -hex 24)\",\"PROMO_CODES\":\"SAVE10:10\",\"DB_PASSWORD\":\"$(openssl rand -hex 24)\"}"
done
```

Read a value back only on your own terminal:
`aws secretsmanager get-secret-value --secret-id africair/staging/app --query SecretString --output text`.

### 7. Build the images and push them to ECR

The nodes are x86_64 (t3), so build for `linux/amd64`. That matters on Apple Silicon. CI does the
same thing on every push to `main` (step 12).

```bash
REGISTRY=$(terraform -chdir=infra/terraform/envs/staging output -raw ecr_registry)
TAG=$(git rev-parse HEAD)           # immutable tags: one image per commit
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
for img in web api; do
  docker buildx build --platform linux/amd64 -f Dockerfile.$img \
    --build-arg VERSION=1.0.0 --build-arg GIT_SHA=$TAG --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
    -t $REGISTRY/africair-$img:$TAG --push .
done
aws ecr describe-images --repository-name africair-api --query 'imageDetails[].imageTags'
```

Both builds run the type checks and tests, so a failing test stops the push.

### 8. Connect to the cluster

```bash
$(terraform -chdir=infra/terraform/envs/staging output -raw kubeconfig_command)    # or: make kubeconfig
kubectl get nodes -L workload          # 2 × general + 2 × platform, private IPs
kubectl -n kube-system get deploy aws-load-balancer-controller reloader
kubectl -n external-secrets get pods
```

### 9. Deploy the app with Helm

```bash
make cluster-secret-stores                 # ESO stores for Secrets Manager and Parameter Store
make helm-install TAG=$TAG                 # chart + values-staging.yaml + gitops/values/cluster.yaml
kubectl -n africair-staging get externalsecret,deploy,pods,ingress,hpa
```

The ExternalSecrets show `SecretSynced`, the migration Job completes, and two `web` and two `api` pods
become Ready. The Ingress gets an ADDRESS within 2–3 minutes, once the ALB is provisioned.

### 10. Deploy Argo CD, monitoring and the rest through GitOps

From here Git is the source of truth: Argo CD installs monitoring, adopts the Helm release from
step 9, and manages production.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd --version 10.11.6 -n argocd --create-namespace \
  -f gitops/values/argocd.yaml --wait
kubectl apply -n argocd -f gitops/bootstrap/root-app.yaml       # the only Application applied by hand
kubectl -n argocd get applications -w                           # Ctrl-C when all are Synced/Healthy
```

(Instead of the `helm` command you can set `enable_argocd = true` in `terraform.tfvars` and apply:
the same release, installed by Terraform.)

The root app (`gitops/apps`) creates, in sync-wave order:
1. the AppProjects;
2. Argo CD itself (self-managed);
3. External Secrets, the Load Balancer Controller and Reloader (adopting the Terraform releases);
4. `platform`: ClusterSecretStores, the ExternalSecrets for Argo CD, Grafana and Alertmanager, the
   dashboards and the alert rules;
5. `monitoring`: kube-prometheus-stack with Prometheus, Alertmanager and Grafana on 20/2/5 GiB gp3
   volumes;
6. `africair-staging` (auto-sync) and `africair-production` (manual sync).

Then:

- **Hand the controllers over to Argo CD** so Terraform stops managing them:
  ```bash
  terraform -chdir=infra/terraform/envs/staging state rm 'module.platform.helm_release.lbc[0]' \
    'module.platform.helm_release.eso[0]' 'module.platform.helm_release.reloader[0]'
  ```
  Then set `install_controllers_with_terraform = false` in `terraform.tfvars`.
- **Production** follows a release tag. Tag the commit you built, give its images the release tag,
  then sync manually:
  ```bash
  git tag v1.0.0 && git push origin v1.0.0       # with CI configured, release.yml re-tags the images itself
  scripts/ci/promote-images.sh "$TAG" v1.0.0     # without CI: add tag v1.0.0 to the same ECR digests
  kubectl -n argocd port-forward svc/argocd-server 8080:80 &
  argocd login localhost:8080 --username admin --insecure --grpc-web
  argocd app sync africair-production            # manual by design; refused at weekends (sync window)
  ```
- The first Argo CD login uses `admin` and `kubectl -n argocd get secret argocd-initial-admin-secret
  -o jsonpath='{.data.password}' | base64 -d`. Once the platform ExternalSecret has synced, the
  password from step 6 applies; then delete `argocd-initial-admin-secret`.

### 11. Access the application and the tools

```bash
STAGING=$(kubectl -n africair-staging get ingress africair -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
PRODUCTION=$(kubectl -n africair-production get ingress africair -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
open "http://$STAGING/"                       # STAGING banner, KES prices, $7 fee
open "http://$STAGING/#/status"               # environment, PostgreSQL storage, secret sources and fingerprints
curl -s "http://$STAGING/api/config" | jq '{appEnv, storage, secrets}'
open "http://$PRODUCTION/"                    # no banner, USD prices, $15 fee
```

| What | How |
|---|---|
| Admin page | `http://$STAGING/#/admin`, token: `aws secretsmanager get-secret-value --secret-id africair/staging/app --query SecretString --output text \| jq -r .ADMIN_TOKEN` |
| Argo CD | `kubectl -n argocd port-forward svc/argocd-server 8080:80` → http://localhost:8080 (or `https://argocd.<domain>`) |
| Grafana | `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80` → http://localhost:3000 (user/password from `africair/platform/grafana`); dashboard **AfricAir — Service overview** |
| Prometheus | `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090` → *Status → Targets*: both `africair-api` jobs UP |
| Alertmanager | `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093` |
| Project 1 static site | `terraform output static_site` (CloudFront URL), published with `scripts/ops/publish-s3.sh` |
| Project 3 hosts | `terraform output container_hosts` (filled by the CI deploys) |

With `domain_name` set, point `staging.`, `argocd.` and `grafana.<domain>` at the ALB (a Route 53
alias, or ExternalDNS) and use HTTPS.

### 12. Turn on CI/CD

Both pipelines authenticate to AWS with **OIDC**: no access keys are stored anywhere. The roles exist
since step 4 (`terraform output ci_role_arns`).

**GitHub Actions** (`.github/workflows/`):

1. *Settings → Secrets and variables → Actions → **Variables***:

   | Variable | Value |
   |---|---|
   | `AWS_REGION` | `eu-west-1` |
   | `AWS_CI_ROLE_ARN` | `ci_role_arns["github-ci"]` |
   | `AWS_PRODUCTION_ROLE_ARN` | `ci_role_arns["github-production"]` |
   | `GITOPS_ENABLED` | `true`, so CI commits each new image tag to `gitops/values/africair-staging.yaml` and Argo CD deploys it |
   | `GITOPS_APP_ID` | The App ID of a GitHub App you create with *Contents: read & write* on the repo |

   And under ***Secrets***: `GITOPS_APP_PRIVATE_KEY`, the App's private key (the only secret needed:
   it lets the GitOps commit bypass branch protection).
2. *Settings → Environments*:
   - `staging`: no rules.
   - `production`: required reviewers, *Deployment branches and tags → selected tags* `v*`, and
     *Prevent self-review*.
3. *Settings → Rules → Rulesets* on `main`: require a pull request with 1 approval and the status
   checks `verify (types, audit, lint)`, `manifests (Terraform, Helm, alert rules)`,
   `unit + API tests (node 20)`, `unit + API tests (node 22)`, the `e2e (…)` jobs and
   `images (build, scan)`. Add the GitHub App to the bypass list.
4. Push or merge to `main`: tests, image build, scan, push of `:<sha>` to ECR, deploy to the staging
   host, smoke test, and the GitOps bump. Tag `vX.Y.Z`: images are re-tagged by digest (no rebuild),
   then the production deploy waits for approval, then a GitHub Release is created.

**CircleCI** (`.circleci/config.yml`), as an alternative or alongside:

1. Log in at circleci.com with GitHub and *Set up project* for the repo, using the existing
   `.circleci/config.yml`.
2. Copy the organisation ID (*Organization Settings → Overview*) and project ID (*Project Settings →
   Overview*) into `terraform.tfvars` (`circleci_org_id`, `circleci_project_id`), then `make tf-apply`.
   This creates the CircleCI OIDC provider and the `africair-circleci-*` roles.
3. *Organization Settings → Contexts*:
   - `africair-staging` with `AWS_ROLE_ARN` = `ci_role_arns["circleci-staging"]` and `AWS_REGION`;
   - `africair-production` with `AWS_ROLE_ARN` = `ci_role_arns["circleci-production"]`, restricted to
     a security group (the people allowed to approve production).
4. *Project Settings → Advanced*: turn on **Auto-cancel redundant workflows**; allow uncertified orbs
   if your org requires it (`eddiewebb/queue`).
5. Validate locally with `circleci config validate`. Pushes run the `ci` workflow; tags `vX.Y.Z` run
   `release`, which waits at the `hold` approval.

To use CircleCI only, don't set the GitHub variables: the GitHub jobs that need AWS then fail at the
OIDC step. Or disable GitHub Actions under *Settings → Actions*.

### 13. Tear down

```bash
make destroy    # deletes the root app and every Ingress/PVC, waits until the ALBs are gone, then terraform destroy
```

The state bucket from step 2 stays (`prevent_destroy`). Delete it by hand if you're done for good.
Check that nothing is left:
`aws elbv2 describe-load-balancers`, `aws ec2 describe-nat-gateways --filter Name=state,Values=available`
and `aws rds describe-db-instances`.

## Project structure

```text
src/
  App.tsx                 # Routing, booking state, guards
  i18n.ts                 # English and French strings
  context.ts              # Language, currency and formatting context
  components/             # Header, SearchForm, AirportCombobox, Results, Travellers, Review, Trips, Destinations, Home
  data/airports.json      # Generated airport dataset (do not edit by hand)
  data/airports.ts        # Airport lookup, search, country names
  data/currencies.ts
  lib/flights.ts          # Itinerary generation and pricing
  lib/validation.ts       # Search, passenger and contact rules
  lib/pdf.ts              # PDF itinerary
  lib/bookings.ts         # Local storage persistence, references, e-ticket numbers
  lib/router.ts           # Hash routing and search URL encoding
  lib/api.ts              # API client; falls back to static defaults when /api is missing
server/                     # API: runtime config, secrets, bookings, admin, metrics (Node 22, PostgreSQL)
  src/  migrations/  .env.example
scripts/build-airports.mjs  # Regenerates airports.json: `pnpm data:airports`
e2e/booking.spec.ts         # End-to-end tests
```

## DevOps bootcamp projects

AfricAir doubles as the sample application for a five-part DevOps bootcamp. The API's environment variables and secrets **visibly change the site** (banner, announcement, maintenance mode, promo codes, admin page, database storage), and `/#/status` shows what each deployment received, so students can see whether their configuration and secret delivery actually work. Each project has its own brief, acceptance checks, knowledge questions and grading rubric:

| # | Project | Domains |
|---|---|---|
| 1 | [Linux, scripting, the build process & AWS hosting](projects/01-linux-scripting-build-aws/README.md) | Bash, systemd (env files, `LoadCredential`), nginx, PostgreSQL, EC2, IAM, S3 + CloudFront |
| 2 | [Containerise AfricAir with Docker](projects/02-docker/README.md) | Two multi-stage images, Compose with PostgreSQL and migrations, Compose secrets, hardening, scanning, ECR |
| 3 | [CI/CD with GitHub Actions and CircleCI](projects/03-cicd-github-actions-circleci/README.md) | Pipelines, service containers, caching, OIDC, build-once/promote, approvals |
| 4 | [EKS with Terraform, Helm, RDS, External Secrets & Ingress](projects/04-kubernetes-eks-terraform/README.md) | Exact EKS/RDS spec in Terraform, Helm chart, ESO + Secrets Manager with live rotation, ALB Ingress |
| 5 | [GitOps with Argo CD, plus Prometheus & Grafana](projects/05-gitops-argocd-observability/README.md) | Argo CD app-of-apps, kube-prometheus-stack, ServiceMonitor, dashboards and alerts as code, incident drills |

### Solutions in this repository

| # | Implementation | Answers |
|---|---|---|
| 1 | `scripts/ops/`, `deploy/{nginx,systemd,logrotate,config,iam}/`, Terraform `modules/foundation` (EC2, S3 + CloudFront) | [ANSWERS](projects/01-linux-scripting-build-aws/ANSWERS.md) |
| 2 | `Dockerfile.web`, `Dockerfile.api`, `.dockerignore`, `compose.yaml`, `config/`, `secrets.example/`, `deploy/docker/`, `deploy/nginx/templates/`, [docs/docker.md](docs/docker.md), Terraform `modules/ecr` | [ANSWERS](projects/02-docker/ANSWERS.md) |
| 3 | `.github/`, `.circleci/config.yml`, `scripts/ci/`, `deploy/ec2/`, `deploy/iam/*-oidc-trust.json`, [docs/ci-comparison.md](docs/ci-comparison.md), Terraform `modules/ci-oidc` | [ANSWERS](projects/03-cicd-github-actions-circleci/ANSWERS.md) |
| 4 | [`infra/terraform/`](infra/terraform/README.md), `deploy/helm/africair/`, `deploy/k8s/`, `Makefile`, [runbook](docs/runbook.md), [architecture](docs/architecture.md), [spec evidence](docs/cluster-spec-evidence.md) | [ANSWERS](projects/04-kubernetes-eks-terraform/ANSWERS.md) |
| 5 | `gitops/` (app-of-apps, values, platform chart with dashboards and tested alert rules) | [ANSWERS](projects/05-gitops-argocd-observability/ANSWERS.md) |

Quick local run of the full stack: `scripts/docker/make-secrets.sh && docker compose up -d --build`, then open http://localhost:8080.
