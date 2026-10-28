# Project 3: AWS access for GitHub Actions and CircleCI through OIDC. No access keys exist.
#   github-ci           main pushes, the staging environment and v* tags: push/promote images, deploy staging
#   github-production   only jobs in the GitHub "production" environment: deploy production
#   circleci-staging    main and v* tags of this project: push/promote images, deploy staging
#   circleci-production v* tags of this project: deploy production
# deploy/iam/*.json documents the rendered trust policies.

terraform {
  required_version = "~> 1.13"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account  = data.aws_caller_identity.current.account_id
  region   = data.aws_region.current.region
  gh_sub   = "token.actions.githubusercontent.com:sub"
  circleci = var.circleci_org_id == null ? null : "oidc.circleci.com/org/${var.circleci_org_id}"
  cci_ref  = var.circleci_org_id == null ? null : "org/${var.circleci_org_id}/project/${var.circleci_project_id}/user/*/vcs-origin/github.com/${var.github_repository}/vcs-ref"
}

# --- identity providers -----------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate chain itself; the thumbprint is no longer used but still accepted.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}

resource "aws_iam_openid_connect_provider" "circleci" {
  count          = local.circleci == null ? 0 : 1
  url            = "https://${local.circleci}"
  client_id_list = [var.circleci_org_id] # CircleCI tokens use the organisation ID as audience
  tags           = var.tags
}

# --- trust policies ---------------------------------------------------------------------------------
data "aws_iam_policy_document" "github_trust" {
  for_each = {
    ci = [
      "repo:${var.github_repository}:ref:refs/heads/main",
      "repo:${var.github_repository}:environment:staging",
      "repo:${var.github_repository}:ref:refs/tags/v*",
    ]
    production = ["repo:${var.github_repository}:environment:production"]
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = local.gh_sub
      values   = each.value
    }
  }
}

data "aws_iam_policy_document" "circleci_trust" {
  for_each = local.circleci == null ? {} : {
    staging    = ["${local.cci_ref}/refs/heads/main", "${local.cci_ref}/refs/tags/v*"]
    production = ["${local.cci_ref}/refs/tags/v*"]
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.circleci[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.circleci}:aud"
      values   = [var.circleci_org_id]
    }
    condition {
      test     = "StringLike"
      variable = "${local.circleci}:sub"
      values   = each.value
    }
  }
}

# --- permissions --------------------------------------------------------------------------------------
data "aws_iam_policy_document" "deploy" {
  for_each = toset(["staging", "production"])

  statement {
    sid       = "FindTheHost"
    actions   = ["ec2:DescribeInstances", "sts:GetCallerIdentity"]
    resources = ["*"]
  }
  statement {
    sid       = "UploadTheBundle"
    actions   = ["s3:PutObject"]
    resources = ["${var.deploy_bucket_arn}/${each.value}/*"]
  }
  statement {
    sid       = "UseTheShellDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${local.region}::document/AWS-RunShellScript"]
  }
  statement {
    sid       = "RunOnThisEnvironmentsHostOnly"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${local.region}:${local.account}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Env"
      values   = [each.value]
    }
  }
  statement {
    sid       = "ReadCommandResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "images" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushAndPromote"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }
}

locals {
  roles = merge(
    {
      "github-ci"         = { trust = data.aws_iam_policy_document.github_trust["ci"].json, env = "staging", images = true }
      "github-production" = { trust = data.aws_iam_policy_document.github_trust["production"].json, env = "production", images = false }
    },
    local.circleci == null ? {} : {
      "circleci-staging"    = { trust = data.aws_iam_policy_document.circleci_trust["staging"].json, env = "staging", images = true }
      "circleci-production" = { trust = data.aws_iam_policy_document.circleci_trust["production"].json, env = "production", images = false }
    },
  )
}

resource "aws_iam_role" "this" {
  for_each             = local.roles
  name                 = "africair-${each.key}"
  assume_role_policy   = each.value.trust
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy" "deploy" {
  for_each = local.roles
  name     = "deploy-${each.value.env}"
  role     = aws_iam_role.this[each.key].id
  policy   = data.aws_iam_policy_document.deploy[each.value.env].json
}

# Production roles deploy an existing digest: they can't push or re-tag images.
resource "aws_iam_role_policy" "images" {
  for_each = { for k, v in local.roles : k => v if v.images }
  name     = "ecr-push-and-promote"
  role     = aws_iam_role.this[each.key].id
  policy   = data.aws_iam_policy_document.images.json
}
