# Account-level and non-Kubernetes resources for Projects 1-3, called from envs/staging so that one
# `terraform apply` creates everything:
#   Project 1  EC2 web server (nginx + systemd), S3 + CloudFront static site, least-privilege deployer
#   Project 2  ECR repositories
#   Project 3  OIDC providers and CI roles, the deploy bucket, EC2 container hosts for staging/production
# plus a monthly AWS Budget alert.

terraform {
  required_version = "~> 1.13"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  tags      = merge(var.tags, { Owner = var.owner })
  repo_root = "${path.root}/../../../.." # the root module is infra/terraform/envs/<env>
}

# --- Project 1 ----------------------------------------------------------------------------------
module "web_server" {
  source    = "../ec2-host"
  name      = "africair-web-server"
  role      = "web-server"
  ssh_cidrs = var.ssh_cidrs
  tags      = merge(local.tags, { Env = "project1" })
}

module "static_site" {
  source                          = "../static-site"
  name                            = "africair"
  bucket_name                     = "africair-site-${local.account}"
  deployer_policy_template        = "${local.repo_root}/deploy/iam/deployer-policy.json"
  deployer_trusted_principal_arns = ["arn:aws:iam::${local.account}:root"] # any principal you allow to sts:AssumeRole it
  tags                            = local.tags
}

# --- Project 2 ----------------------------------------------------------------------------------
module "ecr" {
  source = "../ecr"
  tags   = local.tags
}

# --- Project 3 ----------------------------------------------------------------------------------
resource "aws_s3_bucket" "deploy" {
  bucket        = "africair-deploy-${local.account}" # scripts/ci/deploy-ec2.sh default
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "deploy" {
  bucket                  = aws_s3_bucket.deploy.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3: the bundles are compose.yaml, deploy.sh and settings files, with no secrets (those come from Secrets Manager).
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "deploy" {
  bucket = aws_s3_bucket.deploy.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_versioning" "deploy" {
  bucket = aws_s3_bucket.deploy.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "deploy" {
  bucket = aws_s3_bucket.deploy.id
  rule {
    id     = "expire-bundles"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

module "ci_oidc" {
  source              = "../ci-oidc"
  github_repository   = var.github_repository
  circleci_org_id     = var.circleci_org_id
  circleci_project_id = var.circleci_project_id
  ecr_repository_arns = values(module.ecr.repository_arns)
  deploy_bucket_arn   = aws_s3_bucket.deploy.arn
  tags                = local.tags
}

# Container hosts: { "ADMIN_TOKEN", "PROMO_CODES", "DB_PASSWORD" } per environment, set with the CLI.
resource "aws_secretsmanager_secret" "host" {
  for_each                = toset(["staging", "production"])
  name                    = "africair/ec2-${each.value}/app"
  recovery_window_in_days = 7
  tags                    = merge(local.tags, { Env = each.value })
}

data "aws_iam_policy_document" "host" {
  for_each = toset(["staging", "production"])
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.host[each.value].arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.deploy.arn}/${each.value}/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.deploy.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.value}/*"]
    }
  }
}

module "container_host" {
  source            = "../ec2-host"
  for_each          = toset(["staging", "production"])
  name              = "africair-${each.value}-host"
  role              = "container-host"
  instance_type     = "t3.small"
  extra_policy_json = data.aws_iam_policy_document.host[each.value].json
  tags              = merge(local.tags, { Env = each.value }) # deploy-ec2.sh and the CI policy select on Env
}

# --- cost guard -----------------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "africair-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
