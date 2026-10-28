# In-cluster controllers, installed by terraform apply. Both get AWS permissions through EKS Pod Identity.
#   AWS Load Balancer Controller  creates the ALB for the app's Ingress
#   External Secrets Operator     copies the Secrets Manager secrets into Kubernetes Secrets

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# --- AWS Load Balancer Controller ---------------------------------------------------------------
resource "aws_iam_role" "lb_controller" {
  name               = "${local.name}-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_policy" "lb_controller" {
  name   = "${local.name}-lb-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller.json") # upstream policy, v3.6.2
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.6.2"
  values = [yamlencode({
    clusterName    = aws_eks_cluster.this.name
    region         = var.region
    vpcId          = aws_vpc.this.id
    serviceAccount = { create = true, name = "aws-load-balancer-controller" }
  })]
  depends_on = [aws_eks_node_group.this, aws_eks_addon.others, aws_eks_pod_identity_association.lb_controller]
}

# --- External Secrets Operator ------------------------------------------------------------------
data "aws_iam_policy_document" "eso" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.app.arn, aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_role" "eso" {
  name               = "${local.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy" "eso" {
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso.json
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}

resource "helm_release" "eso" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.14.0"
  values = [yamlencode({
    installCRDs    = true
    serviceAccount = { create = true, name = "external-secrets" }
  })]
  depends_on = [aws_eks_node_group.this, aws_eks_addon.others, aws_eks_pod_identity_association.eso]
}

# The ClusterSecretStore needs ESO's CRDs, so it is a small local chart installed after ESO.
resource "helm_release" "secret_store" {
  name       = "cluster-secret-store"
  namespace  = "external-secrets"
  chart      = "${path.module}/charts/cluster-secret-store"
  values     = [yamlencode({ region = var.region })]
  depends_on = [helm_release.eso]
}
