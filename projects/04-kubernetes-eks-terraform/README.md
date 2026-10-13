# Project 4 — Kubernetes on Amazon EKS with Terraform, RDS, External Secrets & Ingress

> **Domains assessed:** Kubernetes workloads, probes, scaling, disruption & network policy · Helm · Ingress (ingress-nginx and AWS Load Balancer Controller) · External Secrets Operator · Terraform (remote state, modules, IAM) · Amazon EKS · Amazon RDS for PostgreSQL · IAM for pods (IRSA / EKS Pod Identity) · troubleshooting
> **Suggested duration:** 2 weeks · **Team size:** 2–3 · **Builds on:** Project 2 (image in ECR) and Project 3 (pipeline)

## Scenario

AfricAir is moving to Kubernetes. Over the next quarter, the product team will add a **bookings API** backed by PostgreSQL. Before then, the platform team must deliver:

- an EKS cluster and a private RDS PostgreSQL database, **fully in Terraform**;
- the front end running on the cluster behind an ALB Ingress, highly available and autoscaled;
- database credentials that **never appear in Git, Terraform outputs or CI logs**. They live in AWS Secrets Manager and are synced into the cluster by the **External Secrets Operator (ESO)**;
- a migrated database schema and nightly backups to S3, run **from inside the cluster**, proving connectivity, secrets and IAM-for-pods all work.

> The current app is static and does not read the database yet. That is deliberate: you are building and proving the platform the API will land on. The schema and the jobs below are your proof.

## Know the application

| Fact | Detail |
|---|---|
| Image | Your Project 2 image (`nginx-unprivileged`, port **8080**, UID 101, `/healthz`, `/version.json`), in ECR |
| Config | `APP_ENV` env var → `X-Environment` response header (from Project 2) |
| State | None server-side, so pods are freely scalable and disposable |
| E2E | `BASE_URL=https://<ingress-host> pnpm test:e2e` |

---

## Part A — Kubernetes fundamentals locally (kind)

Use **kind**, which is free and fast, before spending money on EKS.

1. Create a 3-node kind cluster (1 control plane, 2 workers) with port mappings for ingress. Install **ingress-nginx** and **metrics-server**.
2. Write a **Helm chart** at `deploy/helm/africair/` with:

   | Resource | Requirements |
   |---|---|
   | `Deployment` | 3 replicas; `RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1`; `readinessProbe` and `livenessProbe` on `/healthz` (different timings, and explain why); `startupProbe`; CPU/memory **requests and limits**; `securityContext`: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`; `emptyDir` volumes where nginx needs to write; `topologySpreadConstraints` across nodes |
   | `Service` | `ClusterIP`, port 80 → targetPort 8080 |
   | `ConfigMap` | Holds the nginx server config; a checksum annotation on the pod template forces a **rollout** when it changes |
   | `Ingress` | `ingressClassName` from values; host from values |
   | `HorizontalPodAutoscaler` | `autoscaling/v2`, 2–10 replicas, 60% CPU |
   | `PodDisruptionBudget` | `minAvailable: 2` |
   | `NetworkPolicy` | Default-deny ingress in the namespace, plus allow **only** from the ingress controller's namespace on 8080 |
   | `ServiceAccount` | Dedicated; `automountServiceAccountToken: false` |

   Ship `values.yaml` (defaults), `values-kind.yaml` and `values-eks.yaml`. Running `helm lint` and `helm template | kubeconform -strict` must pass.
3. Deploy to namespaces `africair-dev` and `africair-staging` with different `APP_ENV` values and hosts (`dev.africair.localtest.me`, `staging.africair.localtest.me`). Both hosts must work through **one** ingress controller.
4. **Rollouts:**
   - deploy a new image tag and watch `kubectl rollout status`;
   - deploy a **broken** tag (e.g. readiness path `/nope`) and show that the old pods keep serving, with **zero failed requests**: run `while true; do curl -s -o /dev/null -w '%{http_code}\n' ...; done` during the rollout;
   - recover with `helm rollback`.
5. **Autoscaling:** generate load (`hey`, `k6` or a `busybox` loop) and show the HPA scaling up and back down.
6. **Disruption:** `kubectl drain` a worker node and show the PDB keeping 2 pods available.
7. **NetworkPolicy:** prove that a pod in `default` **cannot** reach the Service, while traffic through the ingress works. kind's default CNI enforces NetworkPolicy from kind v0.24; otherwise install Calico.

---

## Part B — Infrastructure with Terraform

### B1. Layout and state

```text
infra/terraform/
  bootstrap/               # S3 state bucket (versioned, encrypted, Block Public Access)
  modules/
    network/               # VPC, subnets, NAT
    eks/                   # cluster, node group, add-ons, access entries
    database/              # RDS PostgreSQL + security groups + parameter group
    platform-iam/          # roles for LB Controller, ESO, backup job
  envs/staging/            # composes modules; backend "s3" with use_lockfile = true
```

- Remote state in S3 with **state locking**: S3 native locking (`use_lockfile = true`, Terraform ≥ 1.10) or a DynamoDB table. Demonstrate the lock by running two `plan`s at once.
- Pin Terraform, provider and module versions (`required_version`, `required_providers`, module `version`). You may use `terraform-aws-modules/vpc` and `terraform-aws-modules/eks`, but **you must explain every input you set**.
- `terraform fmt -check`, `terraform validate`, `tflint` and `trivy config infra/` (or `checkov`) must pass. Justify any suppressions inline.

### B2. Network

- One VPC across **3 AZs**, with **public**, **private** (nodes) and **database** subnets.
- A single NAT gateway for staging (explain the HA trade-off for production).
- Tag subnets for the AWS Load Balancer Controller: `kubernetes.io/role/elb` (public) and `kubernetes.io/role/internal-elb` (private).

### B3. EKS

- A currently supported Kubernetes version. Check with `aws eks describe-cluster-versions`.
- A managed node group in **private** subnets: 2–4 × `t3.medium`. **Stretch:** a Spot capacity node group.
- Cluster access through **EKS access entries**: your team's IAM role gets admin, and the CI role from Project 3 gets namespace-scoped deploy rights only.
- Add-ons:
  - `vpc-cni` with **network policy enabled**;
  - `coredns`, `kube-proxy`;
  - `eks-pod-identity-agent` (if you use Pod Identity);
  - `metrics-server`.
- Install the **AWS Load Balancer Controller** and **External Secrets Operator** with the Terraform `helm` provider, or with Helm in a documented script. Give each controller its own IAM role through **IRSA or EKS Pod Identity**. No node-role permissions.

### B4. RDS PostgreSQL

- PostgreSQL 16+, `db.t4g.micro`, in the **database subnets**, `publicly_accessible = false`, storage encrypted, backup retention 7 days, Performance Insights optional.
- **Security group:** port 5432 allowed **only** from the EKS node or cluster security group. No CIDR rules.
- `manage_master_user_password = true`. RDS stores and rotates the master credentials in **Secrets Manager**, so **no password appears in Terraform code, variables or state outputs**. Explain what *does* still end up in state, and how you protect the state bucket.
- Store the endpoint and database name in **SSM Parameter Store**: `/africair/staging/db/host` and `/africair/staging/db/name`.
- A parameter group that forces SSL (`rds.force_ssl = 1`).

### B5. IAM for workloads (least privilege)

| Role | Allowed |
|---|---|
| External Secrets Operator | `secretsmanager:GetSecretValue` and `DescribeSecret` on **only** the RDS master secret ARN; `ssm:GetParameter*` on `/africair/staging/db/*` only |
| Backup job | `s3:PutObject` on `arn:aws:s3:::<backup-bucket>/africair/*` only |
| AWS Load Balancer Controller | The upstream-recommended policy |

Commit `terraform plan` output (with secrets redacted) to the PR.

---

## Part C — Deploy to EKS

### C1. Ingress with the AWS Load Balancer Controller

Deploy the Helm chart with `values-eks.yaml`:

- `ingressClassName: alb`;
- annotations:
  - `alb.ingress.kubernetes.io/scheme: internet-facing`
  - `target-type: ip`
  - `healthcheck-path: /healthz`
  - `group.name: africair`
- **staging** and **production** namespaces share **one ALB** via `group.name`, routed by **host**. Without a domain, use path rules or the ALB DNS name and explain the limitation;
- **with a domain:** an ACM certificate (DNS-validated, in Terraform), `listen-ports` for HTTP and HTTPS, and `ssl-redirect: '443'`. **Stretch:** ExternalDNS creates the Route 53 records;
- run the full e2e suite against the ingress URL: `BASE_URL=https://staging.<domain> pnpm test:e2e`.

### C2. External Secrets Operator

1. A `ClusterSecretStore` named `aws-secrets-manager` (provider `aws`, service `SecretsManager`, your region), authenticated with the ESO service account's IAM role.
2. A second store for `ParameterStore`.
3. An `ExternalSecret` named `africair-db` in `africair-staging` that:
   - reads `username` and `password` from the RDS-managed secret, and `host` and `name` from SSM;
   - uses `target.template` to produce **one** Kubernetes Secret with keys `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE=require`, and a URL-encoded `DATABASE_URL`;
   - sets `refreshInterval: 1m`.
4. Show `kubectl get externalsecret -n africair-staging` → `SecretSynced` / `Ready=True`. **Never** print the secret values in your evidence; show `kubectl get secret africair-db -o jsonpath='{.data}' | jq 'keys'` instead.

### C3. Schema migration Job

Create a Kubernetes **Job** (a Helm hook, `pre-install,pre-upgrade`, is a bonus) using a pinned `postgres:16-alpine` image. It runs `psql -v ON_ERROR_STOP=1 -f /sql/001_schema.sql` with `envFrom: secretRef: africair-db`, and the SQL mounted from a ConfigMap:

```sql
-- 001_schema.sql — schema for the upcoming bookings API (mirrors src/lib/types.ts → Booking)
CREATE TABLE IF NOT EXISTS bookings (
  reference      char(6)      PRIMARY KEY,
  created_at     timestamptz  NOT NULL DEFAULT now(),
  status         text         NOT NULL CHECK (status IN ('confirmed', 'cancelled')),
  origin         char(3)      NOT NULL,
  destination    char(3)      NOT NULL,
  depart_date    date         NOT NULL,
  return_date    date,
  cabin          text         NOT NULL CHECK (cabin IN ('economy', 'premium', 'business', 'first')),
  total_usd      numeric(10,2) NOT NULL,
  currency       char(3)      NOT NULL
);
CREATE TABLE IF NOT EXISTS passengers (
  id             bigserial    PRIMARY KEY,
  booking_ref    char(6)      NOT NULL REFERENCES bookings(reference) ON DELETE CASCADE,
  passenger_type text         NOT NULL CHECK (passenger_type IN ('adult', 'child', 'infant')),
  first_name     text         NOT NULL,
  last_name      text         NOT NULL,
  ticket_number  text         NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz DEFAULT now());
INSERT INTO schema_migrations (version) VALUES ('001') ON CONFLICT DO NOTHING;
```

- The Job must be **idempotent**: running it twice succeeds.
- Use `backoffLimit: 2` and `ttlSecondsAfterFinished`.
- Prove the result with a throwaway pod: `kubectl run psql --rm -it --image=postgres:16-alpine --overrides=<envFrom africair-db> -- psql -c '\dt'`.

### C4. Nightly backup CronJob

A **CronJob** that runs at `02:00` UTC:

- `concurrencyPolicy: Forbid`, history limits set;
- runs `pg_dump | gzip` and uploads to `s3://<backup-bucket>/africair/staging/<date>.sql.gz`, using **only** its pod IAM role. No keys anywhere;
- hint: an init container with `postgres` writes the dump to a shared `emptyDir`, then the main container with `amazon/aws-cli` uploads it. Or build your own small image (good Docker practice);
- trigger it manually (`kubectl create job --from=cronjob/...`) and show the object in S3.

### C5. Secret rotation drill

1. Rotate the RDS master password: `aws secretsmanager rotate-secret --secret-id <arn>`.
2. Show that ESO updates the Kubernetes Secret within `refreshInterval` (compare `resourceVersion`).
3. Show that the **running** throwaway pod with env vars still has the **old** value. Explain why.
4. Describe two ways to roll workloads on secret change: a checksum annotation, or a tool such as **Reloader**. **Stretch:** implement one.

---

## Troubleshooting drills (the instructor injects these; you diagnose them)

For each one, record the symptom, the commands you used (`kubectl describe`, `events`, `logs`, controller logs, `aws` CLI), the root cause and the fix.

1. Pods stuck in `ImagePullBackOff` (wrong tag, or the node role can't pull from ECR).
2. Ingress created, but there is **no ALB** and no `ADDRESS`. Hint: IngressClass, controller logs, subnet tags.
3. ALB returns **502/503**. Hint: target-group health check path vs `/healthz`, readiness, security groups.
4. `ExternalSecret` shows `SecretSyncedError`. Hint: IAM policy resource ARN, region, service-account annotation or pod-identity association.
5. Migration Job fails with `timeout expired`. Hint: RDS security group, subnets, `PGSSLMODE`.
6. HPA shows `<unknown>/60%`. Hint: metrics-server, missing CPU **requests**.
7. A node drain hangs forever. Hint: PDB vs replica count.
8. `terraform destroy` fails with `DependencyViolation` on the VPC. Hint: the ALB was created **by the controller**, not Terraform. Fix the teardown order and document it.

## Acceptance checks (the instructor will run these)

```bash
terraform -chdir=infra/terraform/envs/staging plan -detailed-exitcode   # 0 = no drift
kubectl get nodes -o wide                                               # private IPs only
kubectl -n africair-staging get deploy,po,svc,ing,hpa,pdb,networkpolicy,externalsecret
kubectl -n africair-staging get pods -o jsonpath='{..securityContext}' | jq .
curl -sI https://staging.<domain>/ | grep -i x-environment              # staging
curl -s  https://staging.<domain>/version.json | jq .commit             # matches the deployed image
BASE_URL=https://staging.<domain> pnpm test:e2e                         # all pass
aws rds describe-db-instances --query 'DBInstances[].PubliclyAccessible' # [false]
git grep -niE 'password\s*=|PGPASSWORD=' -- infra deploy                # nothing
kubectl -n africair-staging get job,cronjob
aws s3 ls s3://<backup-bucket>/africair/staging/                        # at least one dump
```

## Knowledge check (`ANSWERS.md`)

1. Readiness vs liveness vs startup probes: what goes wrong if a liveness probe checks the database?
2. Why `maxUnavailable: 0` together with a PDB? What does each protect against (rollout vs voluntary disruption)?
3. IRSA vs EKS Pod Identity: how does each deliver credentials to the pod, and how do you scope a role to one service account?
4. Why use ESO instead of Terraform writing a `kubernetes_secret`, or a Sealed Secret in Git? What are the trade-offs?
5. With `manage_master_user_password`, who rotates the password, and what does an application need to tolerate rotation?
6. `target-type: ip` vs `instance` for the ALB: what changes in the network path and the security groups?
7. Why can't Terraform cleanly destroy resources created by in-cluster controllers, and how do you design for that?
8. Estimate the daily cost of this environment and name the three biggest line items.

## Deliverables

Pull request containing:

- `infra/terraform/**`, `deploy/helm/africair/**` (including the ESO manifests, Jobs and CronJob), `deploy/kind/cluster.yaml`
- a `Makefile` or `scripts/` with `make kind-up`, `make deploy-kind`, `make tf-plan`, `make tf-apply`, `make deploy-eks` and **`make destroy`**, which deletes Ingresses first, waits for the ALBs to disappear, then runs `terraform destroy`
- **Stretch:** extend the Project 3 pipeline: `terraform plan` as a PR comment, and `helm upgrade --atomic` to staging on merge
- `docs/runbook.md`: deploy, roll back, rotate a secret, restore a backup, scale, and the troubleshooting drills
- `ANSWERS.md` with evidence and the knowledge-check answers
- an architecture diagram (VPC/subnets, ALB, EKS, RDS, Secrets Manager, ESO, S3)

## Grading rubric (100 pts)

| Area | Points |
|---|---|
| Helm chart quality: probes, security context, HPA, PDB, NetworkPolicy, rollouts on kind | 15 |
| Terraform: structure, remote state/locking, pinned versions, linting | 15 |
| EKS and add-ons with least-privilege workload IAM | 15 |
| RDS: private, SSL, managed secret, SG scoped to cluster | 10 |
| Ingress with ALB (shared group, TLS if domain), e2e green | 10 |
| ESO: stores, templated secret, rotation drill | 15 |
| Migration Job and backup CronJob working via pod IAM | 10 |
| Troubleshooting drills, runbook, clean teardown | 10 |

## Cost and cleanup ⚠️

EKS is **not** free. The control plane, NAT gateway, nodes, RDS and ALB together typically cost **several US dollars per day**; check the AWS Pricing Calculator for your region.

- Create an **AWS Budget** with an alert before `terraform apply`.
- Do Part A on kind, and only apply EKS when you're ready to test.
- Run `make destroy` at the end of **every** working session, and confirm no load balancers, NAT gateways or RDS instances remain:

  ```bash
  aws elbv2 describe-load-balancers
  aws ec2 describe-nat-gateways --filter Name=state,Values=available
  aws rds describe-db-instances
  ```
