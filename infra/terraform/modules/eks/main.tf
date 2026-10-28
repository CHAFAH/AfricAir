# EKS cluster to the AfricAir spec: access entries (no aws-auth ConfigMap), KMS envelope encryption of
# Secrets, control-plane logs, AL2023 managed node groups with IMDSv2 (hop limit 1), VPC CNI with prefix
# delegation and network policy, and the managed add-ons (EBS CSI through Pod Identity).

terraform {
  required_version = "~> 1.13"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition
}

# --- KMS key for envelope encryption of Kubernetes Secrets --------------------------------------
resource "aws_kms_key" "eks" {
  description             = "${var.name}: EKS secrets envelope encryption"
  enable_key_rotation     = true # yearly automatic rotation of the key material
  deletion_window_in_days = 7
  tags                    = var.tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# --- control-plane logs: created before the cluster so the 7-day retention applies from the start --
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster" # the exact name EKS writes to
  retention_in_days = 7
  tags              = var.tags
}

# --- cluster IAM role -----------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- the cluster ------------------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids # control-plane ENIs in the private subnets
    endpoint_private_access = true                   # nodes talk to the API server inside the VPC
    # Required by the spec (kubectl from laptops); restricted to var.public_access_cidrs, never 0.0.0.0/0.
    #trivy:ignore:AVD-AWS-0040
    endpoint_public_access = true # kubectl from the team's IPs only:
    public_access_cidrs    = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API" # access entries only; the aws-auth ConfigMap is ignored
    bootstrap_cluster_creator_admin_permissions = false # admins are granted explicitly below
  }

  encryption_config {
    resources = ["secrets"]
    provider { key_arn = aws_kms_key.eks.arn }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Standard support only: a version that falls out of it is upgraded instead of billed as extended support.
  upgrade_policy { support_type = "STANDARD" }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]
}

# --- access entries ---------------------------------------------------------------------------------
resource "aws_eks_access_entry" "admin" {
  for_each      = toset(var.admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = toset(var.admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.admin]
}

# The Project 3 CI role may edit (not administer) resources in the app namespaces only.
resource "aws_eks_access_entry" "ci" {
  count         = var.ci_role_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.ci_role_arn
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "ci" {
  count         = var.ci_role_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.ci_role_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
  access_scope {
    type       = "namespace"
    namespaces = var.ci_namespaces
  }
  depends_on = [aws_eks_access_entry.ci]
}

# --- node IAM role ----------------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",          # kubelet registration
    "AmazonEC2ContainerRegistryReadOnly", # image pulls from ECR (troubleshooting drill 1)
    "AmazonEKS_CNI_Policy",               # VPC CNI manages ENIs and prefixes from the node role
    "AmazonSSMManagedInstanceCore",       # Session Manager access to nodes, no SSH keys
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# --- launch templates: disk, IMDSv2, tags (the AMI is chosen by EKS from ami_type) -------------------
resource "aws_launch_template" "node" {
  for_each    = var.node_groups
  name_prefix = "${var.name}-${each.key}-"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.disk_size_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # a pod (one extra hop) cannot reach the node's credentials
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-${each.key}" })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-${each.key}" })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "this" {
  for_each        = var.node_groups
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = each.value.instance_types
  labels          = each.value.labels

  scaling_config {
    min_size     = each.value.min_size
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
  }

  update_config { max_unavailable = 1 }

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  tags = var.tags

  # The VPC CNI add-on (prefix delegation) must exist before the first node joins, so that EKS
  # computes max-pods for prefix mode.
  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.vpc_cni]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # the HPA/cluster autoscaler may move it
  }
}

# --- add-ons ------------------------------------------------------------------------------------
data "aws_eks_addon_version" "this" {
  for_each           = toset(["vpc-cni", "coredns", "kube-proxy", "eks-pod-identity-agent", "aws-ebs-csi-driver", "metrics-server"])
  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.this["vpc-cni"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true" # /28 prefixes per ENI slot: ~110 pods per t3.large instead of 35
      WARM_PREFIX_TARGET       = "1"
    }
    enableNetworkPolicy = "true" # the node agent enforces Kubernetes NetworkPolicy (eBPF)
  })
  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.this["kube-proxy"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = data.aws_eks_addon_version.this["eks-pod-identity-agent"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

# CoreDNS, EBS CSI and metrics-server are Deployments: they need nodes to become ACTIVE.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.this["coredns"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
  depends_on                  = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "metrics-server"
  addon_version               = data.aws_eks_addon_version.this["metrics-server"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
  depends_on                  = [aws_eks_node_group.this]
}

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }
  tags       = var.tags
  depends_on = [aws_eks_node_group.this, aws_eks_addon.pod_identity_agent, aws_iam_role_policy_attachment.ebs_csi]
}
