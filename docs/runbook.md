# AfricAir runbook (EKS staging)

`NS=africair-staging`. Deploying from scratch is in the [README](../README.md#deploy-to-aws-staging).
Get cluster access with `aws eks update-kubeconfig --name africair-stg-cluster --region eu-west-1`.

## Roll back

- **Helm (Project 4):** `helm -n $NS history africair`, then `helm -n $NS rollback africair <rev>`.
  Migrations are forward-only. Roll back only to a release whose code works with the current schema
  (the app only ever *adds* columns and tables).
- **GitOps (Project 5):** `git revert <bad-commit> && git push`. Argo CD syncs staging; production needs
  `argocd app sync africair-production`. Don't roll back in the Argo CD UI: the next sync from Git would
  undo it, and Git would no longer describe what runs.

## Rotate secrets

| Secret | How | Propagation |
|---|---|---|
| `ADMIN_TOKEN`, `PROMO_CODES` | `terraform apply -var-file=stg.tfvars -replace=random_password.admin_token` (or change `promo_codes`) | ESO refresh (≤ 1 min) → kubelet updates the mounted file (≤ ~1 min, its sync period plus cache TTL) → app re-reads (`SECRET_REFRESH_SECONDS` = 15 s). **No restart.** Check: the fingerprint on `/#/status`. |
| Database password | `terraform apply -var-file=stg.tfvars -replace=random_password.db` (updates RDS and `africair/stg/db`) | ESO refresh (`dbRefreshInterval` 1 h; force it with `kubectl annotate externalsecret africair-db force-sync=$(date +%s) --overwrite`) → Secret updated → then `kubectl rollout restart deploy/africair-api -n africair-staging` (env var: only a restart picks it up). |
| Argo CD admin password | New bcrypt hash + new `adminPasswordMtime` in `africair/platform/argocd` | ESO (5 min) merges it into `argocd-secret`; existing sessions are invalidated. |
| Grafana / Alertmanager | Update `africair/platform/{grafana,alertmanager}` | Alertmanager: the operator reloads the config. Grafana: restart (`kubectl -n monitoring rollout restart deploy/monitoring-grafana`). |

## Restore a backup

```bash
aws s3 ls s3://<backup-bucket>/africair/staging/
aws s3 cp s3://<backup-bucket>/africair/staging/<ts>.sql.gz /tmp/restore.sql.gz
kubectl -n $NS run psql --rm -it --image=postgres:16-alpine --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"psql","image":"postgres:16-alpine","stdin":true,"tty":true,
    "envFrom":[{"secretRef":{"name":"africair-db"}}],"command":["sh"]}]}}'
# in the pod (NetworkPolicy: label it app.kubernetes.io/name=migrate to reach RDS):
#   kubectl cp /tmp/restore.sql.gz $NS/psql:/tmp/  ;  gunzip -c /tmp/restore.sql.gz | psql "$DATABASE_URL"
```

Restore into a fresh database (`createdb africair_restore`) first and switch only after checking the data.

## Scale

- App: the HPA scales 2–6 replicas at 60% CPU. For a known peak raise `autoscaling.minReplicas` in values (Git).
- Nodes: 2 × t3.medium (`node_count` in `terraform/stg.tfvars`); the HPA can only use what the nodes have.

## Troubleshooting drills

| # | Symptom | Commands | Usual root cause → fix |
|---|---|---|---|
| 1 | `ImagePullBackOff` | `kubectl -n $NS describe pod <p>` (Events) | Wrong tag (`aws ecr describe-images --repository-name africair-api`) → fix `image.tag`. Or the node role lacks `AmazonEC2ContainerRegistryReadOnly` (Terraform `modules/eks`). |
| 2 | Ingress has no ADDRESS | `kubectl describe ingress`, `kubectl -n kube-system logs deploy/aws-load-balancer-controller` | No `alb` IngressClass (controller not installed); public subnets missing `kubernetes.io/role/elb=1`; controller can't find the VPC because IMDS hop limit 1 hides metadata → `vpcId` and `region` must be set in its values. |
| 3 | ALB 502/504 | `aws elbv2 describe-target-health --target-group-arn …` | Health-check path wrong (the Service annotation must be `/healthz` for web and `/api/readyz` for api), or the NetworkPolicy doesn't allow the VPC CIDR on 8080/4000 (target-type ip: the source is the ALB's ENI). |
| 4 | `SecretSyncedError` | `kubectl -n $NS describe externalsecret africair-db`, `kubectl -n external-secrets logs deploy/external-secrets` | `AccessDenied`: the IAM resource ARN lacks the `-xxxxxx` suffix of the secret, `kms:Decrypt` is missing for the customer key, or the Pod Identity association/trust names the wrong namespace or service account (`external-secrets/external-secrets`). |
| 5 | Migration hook times out | `kubectl -n $NS logs job/africair-migrate` | RDS SG doesn't allow the cluster SG; `DB_SSL=disable` while `rds.force_ssl=1` ("no pg_hba.conf entry … no encryption"); or `africair-db` not synced yet (backoff retries). |
| 6 | `/api/readyz` 503 on every pod, `healthz` 200 | `curl …/api/config \| jq .secrets.database` | The RDS password was rotated and pods still have the old env var → Reloader (or `rollout restart`). |
| 7 | HPA `<unknown>/60%` | `kubectl get apiservice v1beta1.metrics.k8s.io`, `kubectl top pods` | metrics-server add-on missing, or the container has no CPU **request**. |
| 8 | `terraform destroy` → `DependencyViolation` | `aws elbv2 describe-load-balancers`, `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=…` | The controller-created ALB and its SGs/ENIs still exist. `helm uninstall africair -n africair-staging`, wait until `kubectl get ingress -A` is empty, then `terraform destroy -var-file=stg.tfvars` again. |

## Alerts

### AfricairApiDown
**Meaning:** Prometheus has no `up == 1` target for `africair-api` in a namespace for 2 minutes. Users
get errors on everything that needs the API (bookings, admin, promo).
**First checks:** `kubectl -n $NS get pods -l app.kubernetes.io/name=api`, `kubectl describe` (crash loop?
OOM? `ImagePullBackOff`?); Prometheus *Status → Targets* (scrape error vs pod gone); was the NetworkPolicy
changed (9464 from `monitoring`)?
**Mitigation:** roll back the last change (`git revert`); scale up if pods are pending.

### AfricairDatabaseDown
**Meaning:** a pod's last database check failed for 2 minutes; `/api/readyz` is 503, so the ALB stops
routing to it.
**First checks:** `aws rds describe-db-instances` (status, maintenance), recent RDS password rotation
(drill 6), SG rule for the cluster SG, `kubectl -n $NS logs deploy/africair-api | grep -i database`.
**Mitigation:** restart pods after a rotation; restore the SG rule (Terraform); fail over or restore from backup.

### AfricairHighErrorRate
**Meaning:** > 5% of API requests (health checks excluded) return 5xx for 5 minutes.
**First checks:** the error-ratio panel by route, the deployment annotation (just deployed?), API logs
(`"level":"error"`), DB status.
**Mitigation:** roll back a bad deploy; if one route only, consider maintenance mode.

### AfricairHighLatency
**Meaning:** p95 API latency > 500 ms for 10 minutes.
**First checks:** CPU throttling and HPA (`kubectl get hpa`), event-loop lag panel, RDS CPU/connections,
noisy neighbours on the node.
**Mitigation:** raise `minReplicas`, raise CPU limits, look at slow queries (RDS Performance Insights).

### AfricairNoBookings
**Meaning:** production served traffic for 30 minutes but no booking was created.
**First checks:** is `MAINTENANCE_MODE` on? Errors on `POST /api/bookings`? Did a front-end deploy break
the booking flow (run the e2e smoke against production)?
**Mitigation:** roll back; turn maintenance mode off if it was left on.

### AfricairPromoAbuse
**Meaning:** > 1 rate-limited promo validation per second: someone is guessing codes.
**First checks:** access logs for the client IPs (`X-Forwarded-For`); is it one IP or many?
**Mitigation:** block at the ALB (WAF rate rule); rotate `PROMO_CODES` if a code was found.

### AfricairAdminBruteForce
**Meaning:** > 0.2 denied admin requests per second for 5 minutes.
**First checks:** API logs for `invalid admin token` and the source IPs.
**Mitigation:** rotate `ADMIN_TOKEN` (no restart needed), block the source, consider moving `/api/admin`
behind the VPN or an IP allow-list on the ALB.

### AfricairMaintenanceModeOn
**Meaning:** production has had `MAINTENANCE_MODE=true` for 15 minutes (informational).
**First checks:** is it planned? `git log -p gitops/values/africair-production.yaml`.
**Mitigation:** commit `MAINTENANCE_MODE: "false"` and sync production.

### AfricairErrorBudgetBurn
**Meaning:** the 99.5% availability SLO's error budget is being consumed too fast (fast: 14.4× budget rate
over 1 h and 5 min, critical; slow: 6× over 6 h and 30 min, warning).
**First checks / mitigation:** as for AfricairHighErrorRate; the fast burn pages because the monthly
budget would be gone in about two days.
