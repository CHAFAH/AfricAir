# CI access without stored keys: GitHub Actions (main branch of var.github_repository) and, optionally,
# CircleCI get an OIDC role that can push to ECR and deploy the Helm release in africair-staging.

locals {
  circleci_issuer = var.circleci_org_id == null ? null : "oidc.circleci.com/org/${var.circleci_org_id}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.github_repository == null ? 0 : 1
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_openid_connect_provider" "circleci" {
  count          = local.circleci_issuer == null ? 0 : 1
  url            = "https://${local.circleci_issuer}"
  client_id_list = [var.circleci_org_id]
}

data "aws_iam_policy_document" "ci_assume" {
  dynamic "statement" {
    for_each = aws_iam_openid_connect_provider.github
    content {
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [statement.value.arn]
      }
      condition {
        test     = "StringEquals"
        variable = "token.actions.githubusercontent.com:aud"
        values   = ["sts.amazonaws.com"]
      }
      condition {
        test     = "StringLike"
        variable = "token.actions.githubusercontent.com:sub"
        values   = ["repo:${var.github_repository}:*"]
      }
    }
  }
  dynamic "statement" {
    for_each = aws_iam_openid_connect_provider.circleci
    content {
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [statement.value.arn]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.circleci_issuer}:aud"
        values   = [var.circleci_org_id]
      }
      condition {
        test     = "StringLike"
        variable = "${local.circleci_issuer}:sub"
        values   = ["org/${var.circleci_org_id}/project/${var.circleci_project_id}/user/*/vcs-origin/*/vcs-ref/refs/heads/main"]
      }
    }
  }
}

resource "aws_iam_role" "ci" {
  count              = var.github_repository == null && local.circleci_issuer == null ? 0 : 1
  name               = "${local.name}-ci"
  assume_role_policy = data.aws_iam_policy_document.ci_assume.json
}

data "aws_iam_policy_document" "ci" {
  statement {
    actions   = ["ecr:GetAuthorizationToken", "eks:DescribeCluster"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }
}

resource "aws_iam_role_policy" "ci" {
  count  = length(aws_iam_role.ci)
  role   = aws_iam_role.ci[0].id
  policy = data.aws_iam_policy_document.ci.json
}

# Kubernetes rights: edit inside africair-staging only (Helm release, Deployments, ExternalSecrets...).
resource "aws_eks_access_entry" "ci" {
  count         = length(aws_iam_role.ci)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.ci[0].arn
}

resource "aws_eks_access_policy_association" "ci" {
  count         = length(aws_iam_role.ci)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.ci[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
  access_scope {
    type       = "namespace"
    namespaces = ["africair-staging"]
  }
  depends_on = [aws_eks_access_entry.ci]
}
