# AfricAir Terraform

```text
bootstrap/            S3 state bucket (versioned, KMS-encrypted, Block Public Access, TLS only). Local state, run once.
modules/
  network/            VPC 10.40.0.0/16: public, private (/20) and isolated database subnets, 1 NAT, flow logs
  eks/                cluster (access entries, KMS, logs), AL2023 node groups (IMDSv2 hop 1), add-ons, EBS CSI role
  database/           RDS PostgreSQL 16, managed master secret, force_ssl, SG from the cluster SG, SSM discovery
  platform/           Secrets Manager containers, backup bucket, Pod Identity roles, LBC/ESO/Reloader, gp3, Argo CD bootstrap
  static-site/        Project 1: private S3 + CloudFront (OAC, security headers) + least-privilege deployer role
  ec2-host/           Projects 1 and 3: Ubuntu 24.04 hosts managed through SSM
  ecr/                Project 2: immutable repositories, scan on push, lifecycle
  ci-oidc/            Project 3: GitHub and CircleCI OIDC providers and per-environment roles
envs/
  shared/             Projects 1–3 + $10 budget alert        (state key africair/shared/terraform.tfstate)
  staging/            Projects 4–5: network, eks, database, platform  (state key africair/staging/terraform.tfstate)
```

## Order

```bash
terraform -chdir=infra/terraform/bootstrap init && terraform -chdir=infra/terraform/bootstrap apply
for env in shared staging; do
  cp infra/terraform/envs/$env/backend.hcl.example infra/terraform/envs/$env/backend.hcl     # bucket name
  cp infra/terraform/envs/$env/terraform.tfvars.example infra/terraform/envs/$env/terraform.tfvars
done
terraform -chdir=infra/terraform/envs/shared init -backend-config=backend.hcl && terraform -chdir=infra/terraform/envs/shared apply
make tf-plan tf-apply                       # envs/staging (two-phase on the first run)
```

## Conventions

- Terraform `~> 1.13` (≥ 1.10 for `use_lockfile`). Providers: `aws ~> 6.0`, `helm ~> 3.0`,
  `kubernetes ~> 2.38`. Exact versions are in each root's `.terraform.lock.hcl`.
- No community modules: every input is visible and commented in place, as the spec asks
  ("explain every input").
- No secret values anywhere in Terraform. RDS manages its own master password, and every Secrets
  Manager resource is a *container* whose value is written with the CLI.
- Quality gates (`make tf-plan`, and the CI `manifests` job): `terraform fmt -check`, `validate`,
  `tflint` (AWS ruleset), and `trivy config --severity HIGH,CRITICAL --exit-code 1`. Each suppression
  is justified inline next to `#trivy:ignore:`.
- **State locking demo:** run `terraform plan` in two terminals. The second waits on
  `africair/staging/terraform.tfstate.tflock` and fails with "Error acquiring the state lock" after
  `-lock-timeout`.
