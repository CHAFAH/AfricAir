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

## Deploy to AWS (staging)

One environment, kept small: an EKS cluster with **2 x t3.medium** nodes, **one Application Load
Balancer**, a **db.t4g.micro PostgreSQL** database, and two ECR repositories. Terraform also generates
the app's secrets and stores them in AWS Secrets Manager.

### Prerequisites

| Tool      | Version  | Install                                   |
| --------- | -------- | ----------------------------------------- |
| Docker    | 24+      | https://docs.docker.com/get-docker        |
| AWS CLI   | 2.x      | https://aws.amazon.com/cli                |
| Terraform | >= 1.5.0 | https://developer.hashicorp.com/terraform |
| kubectl   | 1.32+    | https://kubernetes.io/docs/tasks/tools    |
| Helm      | 3.x      | https://helm.sh/docs/intro/install        |

---

### 1. AWS profile setup

```bash
aws configure --profile africair
```

You will be prompted for:
- AWS Access Key ID
- AWS Secret Access Key
- Default region: `eu-west-1`
- Default output format: `json`

Use the profile in this shell and check that it works:

```bash
export AWS_PROFILE=africair
aws sts get-caller-identity
```

---

### 2. Provision the infrastructure with Terraform

#### What gets created

| Resource                     | Details                                                                  |
| ---------------------------- | ------------------------------------------------------------------------ |
| VPC                          | `10.40.0.0/16`, 2 public subnets (nodes + ALB), 2 private subnets (RDS) |
| EKS cluster                  | `africair-stg-cluster`, add-ons: VPC CNI, CoreDNS, kube-proxy, Pod Identity agent, metrics-server |
| Node group                   | 2 x `t3.medium`                                                          |
| AWS Load Balancer Controller | IAM role and Pod Identity association (Helm install: step 4)             |
| External Secrets Operator    | IAM role and Pod Identity association (Helm install: step 4)             |
| RDS                          | PostgreSQL 16, `db.t4g.micro`, 20 GB, private, TLS only                 |
| Secrets Manager              | `africair/stg/app` (ADMIN_TOKEN, PROMO_CODES) and `africair/stg/db` (DATABASE_URL), generated by Terraform |
| ECR                          | `africair-web` and `africair-api`                                        |
| CI role                      | OIDC role for GitHub Actions (and CircleCI if configured): push to ECR, deploy to cluster |

The settings live in `terraform/stg.tfvars`. Restrict `api_allowed_cidrs` to your IP if you can.

#### Initialize

```bash
cd terraform
terraform init -var-file=stg.tfvars
```

#### Plan

```bash
terraform plan -var-file=stg.tfvars
```

#### Apply

```bash
terraform apply -var-file=stg.tfvars
```

Type `yes` when prompted. It takes about 15-20 minutes.

The state is **local** (`terraform/terraform.tfstate`). It contains the generated secrets, so it is
git-ignored: keep it safe and don't delete it.

#### Outputs after apply

```
cluster_name        = "africair-stg-cluster"
kubeconfig_command  = "aws eks update-kubeconfig --name africair-stg-cluster --region eu-west-1"
ecr_registry        = "<account>.dkr.ecr.eu-west-1.amazonaws.com"
ecr_repository_urls = { africair-api = ".../africair-api", africair-web = ".../africair-web" }
rds_endpoint        = "africair-stg.xxxx.eu-west-1.rds.amazonaws.com:5432"
secrets             = { app = "africair/stg/app", db = "africair/stg/db" }
ci_role_arn         = "arn:aws:iam::<account>:role/africair-stg-ci"
```

---

### 3. Access the cluster and install controllers

```bash
aws eks update-kubeconfig --name africair-stg-cluster --region eu-west-1
kubectl get nodes
```

Terraform created the IAM roles but does not install the controllers. Run these once from the repo root:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
```

#### External Secrets Operator

```bash
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --wait \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(cd terraform && terraform output -raw eso_role_arn)
```

#### AWS Load Balancer Controller

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --wait \
  --set clusterName=africair-stg-cluster \
  --set region=eu-west-1 \
  --set vpcId=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=africair" --query "Vpcs[0].VpcId" --output text --region eu-west-1) \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(cd terraform && terraform output -raw lb_controller_role_arn)
```

Verify:

```bash
kubectl get deployment aws-load-balancer-controller -n kube-system
kubectl get deployment external-secrets -n external-secrets
```

Expected: both `2/2` (or `1/1`) Ready.

---

### 4. Connect to GitHub Actions and deploy

The pipeline authenticates to AWS using access keys stored as GitHub Secrets.

#### Get the access keys

```bash
aws iam create-access-key --user-name landmark-eks --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
```

#### Add GitHub Secrets and Variables

Go to your GitHub repository → **Settings → Secrets and variables → Actions**.

Under the **Secrets** tab → **New repository secret** for each:

| Secret | Value |
| ------ | ----- |
| `AWS_ACCESS_KEY_ID` | Access key ID from the command above |
| `AWS_SECRET_ACCESS_KEY` | Secret access key from the command above |

Under the **Variables** tab → **New repository variable**:

| Variable | Value |
| -------- | ----- |
| `AWS_REGION` | `eu-west-1` |

#### Trigger the pipeline

```bash
git add .
git commit -m "trigger: deploy to staging"
git push origin main
```

Go to **Actions** in your GitHub repository. You will see the `CI` workflow running jobs in order:

1. `test` — runs type checks and unit tests with a PostgreSQL service container
2. `images` — builds both Docker images, pushes `:<sha>` and `:latest` to ECR
3. `deploy` — creates k8s secrets from Secrets Manager, then runs `helm upgrade --install`
4. `gitops-bump` — commits the new image SHA to `gitops/values/africair-staging.yaml` so Argo CD picks it up

The pipeline builds and pushes the images — you do not need to build or push Docker images manually.

---

### 5. Install Argo CD and bootstrap GitOps

#### Install Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
  -n argocd --create-namespace --wait \
  --set configs.params.server.insecure=true
```

#### Bootstrap the app-of-apps

This single command hands everything over to Argo CD:

```bash
kubectl apply -n argocd -f gitops/bootstrap/root-app.yaml
```

Argo CD will now create and sync the `africair` AppProject and the `africair-staging` Application automatically.

#### Access the Argo CD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open http://localhost:8080. Login with:

```bash
# username: admin
# password:
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

#### How GitOps deploys work after this

Every push to `main`:
1. CI builds and pushes images to ECR
2. CI commits the new SHA to `gitops/values/africair-staging.yaml`
3. Argo CD detects the commit and syncs the Helm release automatically

You can also trigger a manual sync from the UI or CLI:

```bash
argocd app sync africair-staging
```

---

### 6. Access the application

The ALB address appears on the Ingress after 1-3 minutes:

```bash
kubectl get ingress africair
URL=http://$(kubectl get ingress africair -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $URL
```

| Page                             | URL                |
| -------------------------------- | ------------------ |
| Site                             | `$URL/`            |
| Status (config + secret sources) | `$URL/#/status`    |
| Admin                            | `$URL/#/admin`     |
| API config                       | `$URL/api/config`  |

The admin token is in Secrets Manager:

```bash
aws secretsmanager get-secret-value --secret-id africair/stg/app --query SecretString --output text
```

---

### 7. Manual deploy with Helm (optional — skip if using the pipeline)

If you want to deploy without the pipeline, build and push the images first:

```bash
ECR=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-west-1.amazonaws.com
aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin $ECR

docker build --platform linux/amd64 -f Dockerfile.web -t $ECR/africair-web:v1.0 .
docker build --platform linux/amd64 -f Dockerfile.api -t $ECR/africair-api:v1.0 .
docker push $ECR/africair-web:v1.0
docker push $ECR/africair-api:v1.0
```

Then patch the values and install:

```bash
sed -i "s|REGISTRY_PLACEHOLDER|$ECR|" deploy/helm/africair/values-staging.yaml
sed -i "s|TAG_PLACEHOLDER|v1.0|" deploy/helm/africair/values-staging.yaml

helm upgrade --install africair deploy/helm/africair \
  -f deploy/helm/africair/values-staging.yaml
```

Check it:

```bash
kubectl get jobs,pods,ingress
```

The `africair-migrate` job completes, then one `web` and one `api` pod become `Running`.

---

### 8. Destroy the infrastructure

Delete the app first so the Load Balancer Controller removes the ALB that Terraform did not create:

```bash
# If using Argo CD, delete the root app (cascades to all managed apps)
kubectl delete app root -n argocd
kubectl get ingress -A          # wait until nothing is left

# If using Helm directly
helm uninstall africair
kubectl get ingress -A          # wait until nothing is left

cd terraform
terraform destroy -var-file=stg.tfvars
```

---

### Troubleshooting

| Symptom | Resolution |
| ------- | ---------- |
| `NoCredentialProviders` / `ExpiredToken` | `export AWS_PROFILE=africair` and check with `aws sts get-caller-identity` |
| `kubectl` returns `Unauthorized` | Re-run `aws eks update-kubeconfig ...` with the same profile that ran `terraform apply` |
| Pods `ImagePullBackOff` | The tag doesn't exist in ECR: `aws ecr describe-images --repository-name africair-api` |
| ExternalSecret `SecretSyncedError` | `kubectl describe externalsecret africair-db` and `kubectl logs -n external-secrets deploy/external-secrets` |
| Argo CD app stuck `OutOfSync` | `argocd app sync africair-staging --force` or check `kubectl logs -n argocd deploy/argocd-repo-server` |
| Argo CD can't pull repo | Ensure the repo is public or add credentials: `argocd repo add https://github.com/CHAFAH/AfricAir.git` |
| Ingress has no ADDRESS | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| `/api/readyz` returns 503 | The API can't reach RDS: check the `africair-db` secret and `kubectl logs deploy/africair-api` |
| `terraform destroy` fails on the VPC | An ALB still exists: delete the Ingress (step 7), wait, retry |

> Staging shortcuts, by design: nodes in public subnets (no NAT gateway), a public EKS endpoint (limit
> it with `api_allowed_cidrs`), mutable image tags, and secrets in the local Terraform state.

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

The AWS infrastructure was later simplified to one small staging environment (`terraform/`, see
[Deploy to AWS](#deploy-to-aws-staging)). The project answers describe the fuller designs from the
briefs; where they mention removed Terraform (EC2 hosts, CloudFront, a production environment), the
note at the top of each ANSWERS file says so.

| # | Implementation | Answers |
|---|---|---|
| 1 | `scripts/ops/`, `deploy/{nginx,systemd,logrotate,config,iam}/` | [ANSWERS](projects/01-linux-scripting-build-aws/ANSWERS.md) |
| 2 | `Dockerfile.web`, `Dockerfile.api`, `.dockerignore`, `compose.yaml`, `config/`, `secrets.example/`, `deploy/docker/`, `deploy/nginx/templates/`, [docs/docker.md](docs/docker.md), `terraform/ecr.tf` | [ANSWERS](projects/02-docker/ANSWERS.md) |
| 3 | `.github/workflows/ci.yml`, `.circleci/config.yml`, `scripts/ci/smoke.sh`, `deploy/iam/`, [docs/ci-comparison.md](docs/ci-comparison.md), `terraform/ci.tf` | [ANSWERS](projects/03-cicd-github-actions-circleci/ANSWERS.md) |
| 4 | `terraform/`, `deploy/helm/africair/`, [runbook](docs/runbook.md), [architecture](docs/architecture.md) | [ANSWERS](projects/04-kubernetes-eks-terraform/ANSWERS.md) |
| 5 | `gitops/` (app-of-apps, values, platform chart with dashboards and tested alert rules), optional | [ANSWERS](projects/05-gitops-argocd-observability/ANSWERS.md) |

Quick local run of the full stack: `scripts/docker/make-secrets.sh && docker compose up -d --build`, then open http://localhost:8080.
