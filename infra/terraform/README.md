# AfricAir Terraform

One root module, `envs/staging`, creates **everything** in a single `terraform apply`. The only thing
created beforehand is the state bucket (`bootstrap/`), because Terraform can't keep its state in a
bucket it hasn't created yet. The full walkthrough is in the root [README](../../README.md#run-it-on-aws).

```text
bootstrap/            S3 state bucket (versioned, KMS-encrypted, Block Public Access, TLS only). Local state, run once.
envs/staging/         THE root module (state key africair/staging/terraform.tfstate)
modules/
  foundation/         Projects 1-3: ECR, CI OIDC roles, S3 + CloudFront, EC2 hosts, deploy bucket, budget
    ec2-host/  static-site/  ecr/  ci-oidc/      (used by foundation)
  network/            VPC 10.40.0.0/16: public, private (/20) and isolated database subnets, 1 NAT, flow logs
  eks/                cluster (access entries, KMS, logs), AL2023 node groups (IMDSv2 hop 1), add-ons, EBS CSI role
  database/           RDS PostgreSQL 16, managed master secret, force_ssl, SG from the cluster SG, SSM discovery
  platform/           Secrets Manager containers, backup bucket, Pod Identity roles, LBC/ESO/Reloader, gp3, optional Argo CD
```

```bash
terraform -chdir=infra/terraform/bootstrap init && terraform -chdir=infra/terraform/bootstrap apply   # once
cp infra/terraform/envs/staging/backend.hcl.example infra/terraform/envs/staging/backend.hcl          # bucket name
cp infra/terraform/envs/staging/terraform.tfvars.example infra/terraform/envs/staging/terraform.tfvars
make tf-plan tf-apply
make configure          # outputs → gitops/values/cluster.yaml and aws-load-balancer-controller.yaml
```

## Conventions

- Terraform `~> 1.13` (≥ 1.10 for `use_lockfile`). Providers: `aws ~> 6.0`, `helm ~> 3.0`,
  `kubernetes ~> 2.38`. Exact versions are in `.terraform.lock.hcl`.
- No community modules: every input is visible and commented in place, as the spec asks
  ("explain every input").
- The Helm and Kubernetes providers are configured from the cluster created in the same run. Their
  resources are only *created* on the first apply, which doesn't contact the cluster during plan.
  If a provider ever complains during plan that the cluster is unreachable (for example after the
  cluster was deleted outside Terraform), run `terraform apply -target=module.eks` once, then
  apply normally.
- No secret values anywhere in Terraform. RDS manages its own master password, and every Secrets
  Manager resource is a *container* whose value is written with the CLI.
- Quality gates (`make tf-plan` and the CI `manifests` job): `terraform fmt -check`, `validate`,
  `tflint` (AWS ruleset) and `trivy config --severity HIGH,CRITICAL --exit-code 1`. Each suppression
  is justified inline next to `#trivy:ignore:`.
- **State locking demo:** run `terraform plan` in two terminals. The second fails with "Error
  acquiring the state lock" on `africair/staging/terraform.tfstate.tflock`.
