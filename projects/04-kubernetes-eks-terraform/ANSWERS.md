# Project 4 — Answers

| Deliverable | Where |
|---|---|
| Terraform (bootstrap, modules network/eks/database/platform, envs/staging) | `infra/terraform/` (see its README) |
| Helm chart | `deploy/helm/africair/` (+ `values.schema.json`) |
| ClusterSecretStores | `deploy/k8s/cluster-secret-stores.yaml` |
| Makefile (`tf-plan`, `tf-apply`, `helm-install`, `destroy`) | `Makefile` |
| Runbook (deploy, roll back, rotate, restore, scale, drills) | `docs/runbook.md` |
| Spec evidence (commands + expected output) | `docs/cluster-spec-evidence.md` |
| Architecture diagram | `docs/architecture.md` (Mermaid) |

> **Evidence status.** Validated locally:
> - `terraform fmt -check` and `validate` (Terraform 1.13.4, AWS provider 6.70, Helm 3.3, Kubernetes 2.38);
> - `tflint` with the AWS ruleset: clean;
> - `trivy config --severity HIGH,CRITICAL`: clean, with 6 justified inline suppressions;
> - `helm lint`, and `helm template | kubeconform -strict` against Kubernetes 1.33 and the CRD schemas:
>   47/47 resources valid in Helm and GitOps mode;
> - the values schema rejects `ANNOUNCEMENT_LEVEL=loud`.
>
> Nothing has been applied to AWS. `helm install --dry-run=server`, the CLI evidence and the seven
> browser proofs need the running cluster.

## Design decisions to know

- **Plain resources instead of `terraform-aws-modules`.** The spec asks you to explain every input.
  With resources, every input sits in the code with a comment.
- **Two-phase first apply** (`make tf-apply`). The Helm and Kubernetes providers are configured from
  the cluster this configuration creates, so the cluster must exist before Terraform can plan anything
  inside it.
- **Kubernetes version.** 1.33 is no longer in standard support (released May 2025, 14 months of
  standard support), so the version is a required variable checked against
  `describe-cluster-versions --status STANDARD_SUPPORT`. `upgrade_policy.support_type = STANDARD`
  prevents silent extended-support charges.
- **ESO hooks.** The migration Job is a `pre-install`/`pre-upgrade` hook, so it runs before normal
  resources exist. The ExternalSecrets are therefore hooks too, at weight -10, with
  `creationPolicy: Orphan`, so re-creating the hook never deletes the Secret the pods use. The Job's
  `backoffLimit: 3` covers the seconds ESO needs to sync.
- **Pod Identity trust policies** match the session tags EKS adds
  (`aws:RequestTag/eks-cluster-name`, `kubernetes-namespace`, `kubernetes-service-account`). Each role
  works only for its one service account, even if someone creates a second association.
- **`DATABASE_URL`** is rendered by ESO's template (`{{ .password | urlquery }}`) and includes
  `sslmode=require` for `pg_dump`. The API strips `sslmode` and uses `DB_SSL=require` itself.
- **Zero-downtime numbers.** `SHUTDOWN_DELAY_MS=15000` (the pod keeps serving while the target
  deregisters), ALB `deregistration_delay=20s`, `terminationGracePeriodSeconds=45` (> 15 s delay +
  10 s drain). Readiness gates are injected by the controller (namespace label), so a rollout waits
  until new pods are healthy *in the ALB*. Verify with `hey -z 60s https://<host>/api/config` during
  `kubectl rollout restart deploy/africair-api`: the expected result is 0 non-2xx.

## Prove it in the browser (capture on the cluster)

| # | What to capture | Notes |
|---|---|---|
| 1 | `/#/status`: staging, PostgreSQL, DB *Connected* (source env), admin and promo *mounted file* with fingerprints | The API reports `secrets.database.source = env` because `DATABASE_URL` is an env var. |
| 2 | Amber STAGING banner with version/commit, the announcement, "AfricAir Staging", KES | `APP_VERSION` defaults to the image tag (ConfigMap). |
| 3 | `SAVE10` booking, then `/#/admin`, then `kubectl -n africair-staging run psql --rm -it --image=postgres:16-alpine --env DATABASE_URL=… -- psql "$DATABASE_URL" -c 'select reference,promo_code from bookings'` | The admin token: `aws secretsmanager get-secret-value --secret-id africair/staging/app --query SecretString` (only on your own terminal, never in evidence). |
| 4 | `MAINTENANCE_MODE: "true"` in values, `helm upgrade` → pods roll | The `checksum/config` annotation changes, so the pod template changes. |
| 5 | Rotate `ADMIN_TOKEN` → the fingerprint changes, no restart (`kubectl get pods` shows the same AGE) | Timeline: ESO `refreshInterval: 1m` + kubelet volume sync (≤ ~60–90 s: sync period plus cache TTL) + app `SECRET_REFRESH_SECONDS: 15` ⇒ ≤ ~2.5 min. |
| 6 | `rotate-secret` on the RDS secret: ESO updates `africair-db` (`resourceVersion` changes), Reloader restarts the API | Without Reloader the old env var stays and `/api/readyz` goes 503 once the old password stops working. |
| 7 | Remove the ESO permission: `SecretSyncedError`, the app keeps working | Good: a Secrets Manager or IAM outage doesn't take the app down. Dangerous: rotations silently stop applying and nobody notices unless the ExternalSecret status is alerted on (Project 5's health check makes the app Degraded). |

## Knowledge check

**1. Readiness, liveness and startup probes.**
- **Startup** gives a slow first start time (60 s here) and holds the other two probes off until it
  passes.
- **Liveness** asks "is the process wedged?". A failure restarts the container.
- **Readiness** asks "should this pod get traffic?". A failure removes it from Services and from the
  ALB target group.

Liveness must not depend on the database. If RDS has a hiccup, a DB-aware liveness probe would
restart *every* pod at once: a restart can't fix the database, and it turns a dependency outage into a
crash loop with cold starts. The API's `/api/readyz` runs a `SELECT 1`. When RDS is down it returns
**503** `{"status":"not-ready","db":"error"}`, so pods drop out of the load balancer but stay alive and
recover by themselves. `/api/healthz` stays 200.

**2. Pod Identity vs IRSA.**
- **IRSA:** the pod gets a projected service-account token (a JWT from the cluster's OIDC issuer) and
  the SDK calls `AssumeRoleWithWebIdentity`. The role's trust policy names the cluster's OIDC provider
  and matches `sub = system:serviceaccount:<ns>:<sa>`. It needs an IAM OIDC provider per cluster and a
  trust policy per cluster.
- **Pod Identity:** the `eks-pod-identity-agent` DaemonSet serves credentials on 169.254.170.23. EKS
  assumes the role (principal `pods.eks.amazonaws.com`) for the pod's service account as configured by
  an *association* (cluster, namespace, SA → role), and adds session tags. The same trust policy works
  for any cluster.
- **Scoping to one SA:** with IRSA, through the `sub` condition. With Pod Identity, through the
  association plus (as here) trust conditions on `aws:RequestTag/kubernetes-namespace` and
  `kubernetes-service-account`.

**3. Why ESO, and the trade-offs.**
- **Terraform `kubernetes_secret`** puts the value in Terraform **state** (plaintext JSON in S3) and
  in plans, and only changes when someone runs `apply`.
- **Sealed Secrets** puts ciphertext in Git, tied to one cluster's key. Rotation means re-sealing and
  committing, there's no audit trail of reads, and losing the key loses everything.
- **ESO** keeps one source of truth (Secrets Manager: audited in CloudTrail, KMS-encrypted, rotation
  built in), refreshes automatically, and works for any number of clusters.

The trade-offs: a controller to run and upgrade, a runtime dependency on AWS APIs (cached in
Kubernetes Secrets, which then hold plaintext in etcd, mitigated by KMS envelope encryption), and
IAM to get right (troubleshooting drill 4).

**4. Propagation paths.**
- **Env var:** Secrets Manager → (ESO `refreshInterval`, 1 h for the DB secret) → K8s Secret →
  *nothing*, because env vars are fixed when the container starts → a restart is needed (Reloader
  watches the Secret and patches the Deployment → rolling restart, roughly a minute).
- **Mounted file:** Secrets Manager → ESO (1 m) → K8s Secret → kubelet periodic sync updates the
  projected file through an atomic symlink swap (kubelet sync period ~60 s + ConfigMap/Secret cache
  TTL) → the app re-reads it every `SECRET_REFRESH_SECONDS` (15 s). End to end about 1–2.5 min, with
  no restart.

**5. IMDSv2 hop limit 1.** IMDS answers only if the request's IP TTL survives the hops. A pod's traffic
crosses one extra hop (the pod network namespace), so with hop limit 1 pods can't read the node's
metadata, and in particular can't steal the **node role's credentials** (ECR pull, CNI, EC2 APIs). That
blocks SSRF-to-credentials attacks from any pod. It broke anything that relied on IMDS for discovery:
the AWS Load Balancer Controller can't find its region and VPC, so `region` and `vpcId` are passed
explicitly. Every AWS call from a pod has to use Pod Identity, which is the point.

**6. `target-type: ip` vs `instance`.**
- **`instance`:** ALB → NodePort on every node → kube-proxy (iptables) → maybe another node → pod.
  There's an extra hop, cross-AZ hairpinning, and source IPs are SNATed. The node SG must allow the
  NodePort range from the ALB SG, and a NetworkPolicy sees traffic from *nodes*.
- **`ip`:** the ALB targets pod IPs directly (VPC CNI gives pods VPC addresses). There's one hop, the
  ALB health check hits the actual pod, and readiness gates work. The pod's (node's) SG must allow the
  ALB SG on the container ports, which the controller manages. The NetworkPolicy must allow the ALB's
  ENI addresses, i.e. the **VPC CIDR** (or the public subnet CIDRs), which is why `albSourceCidrs`
  is the VPC CIDR.

**7. Terraform vs in-cluster controllers.** The load balancer controller creates the ALB, target
groups and security groups (and the EBS CSI driver creates volumes) from Kubernetes objects. Terraform
never created them, so they aren't in its state. `terraform destroy` removes the controller (or the
cluster) first, and the orphaned ALB keeps ENIs and an SG in the VPC, so subnet and VPC deletion fail
with `DependencyViolation`. The design: delete the Kubernetes objects first and let the controllers
clean up (`make destroy` deletes Ingresses and PVCs, then waits until no ALB remains in the VPC),
**then** run Terraform. In Project 5, deleting the root Application with cascade does the same.
Tagging lets you find leftovers.

**8. Daily cost estimate (eu-west-1, on-demand, approximate).**

| Item | $/day |
|---|---|
| EKS control plane ($0.10/h) | 2.40 |
| 2 × t3.large (~$0.091/h each) | 4.37 |
| NAT gateway ($0.048/h + data) | ~1.20 |
| ALB ($0.0252/h + LCU) | ~0.65 |
| RDS db.t4g.micro + 20 GiB gp3 | ~0.45 |
| 2 × 30 GiB gp3 node volumes, KMS key, Secrets Manager (4), CloudWatch logs | ~0.30 |
| **Total** | **≈ $9–10/day** (more with Project 5's platform nodes: +2 × t3.large ≈ +$4.4/day) |

The three biggest items are the **nodes**, the **EKS control plane** and the **NAT gateway**.
