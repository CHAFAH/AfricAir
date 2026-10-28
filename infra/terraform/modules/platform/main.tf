# Everything between the cluster and the app: secret containers, the backup bucket, Pod Identity roles
# (least privilege), the in-cluster controllers, the default StorageClass and (Project 5) Argo CD.

terraform {
  required_version = "~> 1.13"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition
}

# --- Secrets Manager: containers only. Values are written with the CLI and never enter state. ------
resource "aws_secretsmanager_secret" "app" {
  for_each                = toset(var.app_environments)
  name                    = "africair/${each.value}/app" # {"ADMIN_TOKEN": "...", "PROMO_CODES": "..."}
  description             = "AfricAir ${each.value}: ADMIN_TOKEN and PROMO_CODES (value set out of band)"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret" "platform" {
  for_each                = toset(var.platform_secrets)
  name                    = "africair/platform/${each.value}"
  description             = "AfricAir platform: ${each.value} credentials (value set out of band)"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
  tags                    = var.tags
}

# --- backup bucket ------------------------------------------------------------------------------
resource "aws_s3_bucket" "backup" {
  bucket        = var.backup_bucket_name
  force_destroy = true # staging: `make destroy` must not leave a bucket full of dumps behind
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    id     = "expire-dumps"
    status = "Enabled"
    filter { prefix = "africair/" }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

data "aws_iam_policy_document" "backup_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id
  policy = data.aws_iam_policy_document.backup_bucket.json
}

# --- Pod Identity roles ---------------------------------------------------------------------------
# EKS Pod Identity assumes the role with session tags describing the pod (hence sts:TagSession).
# Matching them in the trust policy scopes each role to one cluster, namespace and service account,
# even if someone creates a second association for it.
locals {
  workloads = {
    eso    = { namespace = "external-secrets", service_account = "external-secrets" }
    lbc    = { namespace = "kube-system", service_account = "aws-load-balancer-controller" }
    backup = { namespace = "africair-${var.backup_environment}", service_account = "africair-backup" }
  }
}

data "aws_iam_policy_document" "pod_identity_assume" {
  for_each = local.workloads
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [each.value.namespace]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}

# External Secrets Operator: read exactly the secrets and parameters the cluster needs.
data "aws_iam_policy_document" "eso" {
  statement {
    sid     = "ReadAppAndDatabaseSecrets"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = concat(
      [var.rds_master_secret_arn],
      [for s in aws_secretsmanager_secret.app : s.arn],
      [for s in aws_secretsmanager_secret.platform : s.arn],
    )
  }
  statement {
    sid       = "DecryptWithTheEnvironmentKey"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "ReadDatabaseDiscoveryParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account}:parameter${var.ssm_db_prefix}/*"]
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume["eso"].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "eso" {
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso.json
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = var.cluster_name
  namespace       = local.workloads.eso.namespace
  service_account = local.workloads.eso.service_account
  role_arn        = aws_iam_role.eso.arn
  tags            = var.tags
}

# AWS Load Balancer Controller: the upstream policy, vendored at the chart's app version.
resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume["lbc"].json
  tags               = var.tags
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-aws-load-balancer-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller-v3.6.2.json")
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = var.cluster_name
  namespace       = local.workloads.lbc.namespace
  service_account = local.workloads.lbc.service_account
  role_arn        = aws_iam_role.lbc.arn
  tags            = var.tags
}

# Backup CronJob: write dumps under africair/<env>/ only.
data "aws_iam_policy_document" "backup" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backup.arn}/africair/${var.backup_environment}/*"]
  }
  statement {
    actions   = ["kms:GenerateDataKey", "kms:Encrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.cluster_name}-backup"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume["backup"].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "backup" {
  role   = aws_iam_role.backup.id
  policy = data.aws_iam_policy_document.backup.json
}

resource "aws_eks_pod_identity_association" "backup" {
  cluster_name    = var.cluster_name
  namespace       = local.workloads.backup.namespace
  service_account = local.workloads.backup.service_account
  role_arn        = aws_iam_role.backup.arn
  tags            = var.tags
}

# --- default StorageClass (Prometheus, Alertmanager and Grafana PVCs in Project 5) ----------------------
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer" # create the volume in the AZ where the pod is scheduled
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }
}

# --- controllers (Project 5 hands these over to Argo CD: set install_controllers = false) ----------
resource "helm_release" "lbc" {
  count      = var.install_controllers ? 1 : 0
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_load_balancer_controller
  values = [yamlencode({
    clusterName  = var.cluster_name
    region       = local.region # IMDS hop limit 1: the controller cannot discover these from the node
    vpcId        = var.vpc_id
    replicaCount = 2
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller" # matches the Pod Identity association
    }
  })]
  depends_on = [aws_eks_pod_identity_association.lbc, aws_iam_role_policy_attachment.lbc]
}

resource "helm_release" "eso" {
  count            = var.install_controllers ? 1 : 0
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_versions.external_secrets
  values = [yamlencode({
    installCRDs    = true
    serviceAccount = { create = true, name = "external-secrets" }
  })]
  depends_on = [aws_eks_pod_identity_association.eso]
}

# Stakater Reloader: rolls the API when the env-var DB secret changes (Project 4, Part D #6).
resource "helm_release" "reloader" {
  count      = var.install_controllers ? 1 : 0
  name       = "reloader"
  namespace  = "kube-system"
  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
  version    = var.chart_versions.reloader
  values = [yamlencode({
    reloader = { reloadOnCreate = false, watchGlobally = true }
  })]
}

# --- Project 5: Argo CD bootstrap. Installed once; afterwards gitops/apps/argocd.yaml owns the release. --
resource "helm_release" "argocd" {
  count            = var.argocd.enabled ? 1 : 0
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd.chart_version
  values           = [file(var.argocd.values_file)] # the same file Argo CD uses to manage itself
  lifecycle {
    ignore_changes = all # Argo CD is self-managed after the first install: Terraform must not fight it
  }
}
