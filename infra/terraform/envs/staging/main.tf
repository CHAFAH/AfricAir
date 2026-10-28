# AfricAir staging on EKS (Project 4), plus the Project 5 additions (platform node group, Argo CD
# bootstrap, secret containers for Argo CD, Grafana and Alertmanager, the production app secret).

data "aws_caller_identity" "current" {}

locals {
  name = "africair-${var.team}-staging"
  tags = {
    Project   = "africair"
    Team      = var.team
    Env       = "staging"
    ManagedBy = "terraform"
  }

  node_groups = merge(
    {
      general = {
        instance_types = ["t3.large"]
        min_size       = 2
        desired_size   = 2
        max_size       = 4
        disk_size_gib  = 30
        labels         = { workload = "general" }
      }
    },
    # Project 5: Argo CD and kube-prometheus-stack get their own tainted nodes, so a noisy platform
    # component can't starve the app (and the app can't evict Prometheus).
    var.enable_platform_node_group ? {
      platform = {
        instance_types = ["t3.large"]
        min_size       = 1
        desired_size   = 2
        max_size       = 3
        disk_size_gib  = 30
        labels         = { workload = "platform" }
        taints         = [{ key = "dedicated", value = "platform", effect = "NO_SCHEDULE" }]
      }
    } : {},
  )
}

module "network" {
  source       = "../../modules/network"
  name         = local.name
  cluster_name = local.name
  tags         = local.tags
}

module "eks" {
  source               = "../../modules/eks"
  name                 = local.name
  kubernetes_version   = var.kubernetes_version
  private_subnet_ids   = module.network.private_subnet_ids
  public_access_cidrs  = var.team_cidrs
  admin_principal_arns = var.admin_principal_arns
  ci_role_arn          = var.ci_role_arn
  ci_namespaces        = ["africair-staging"]
  node_groups          = local.node_groups
  tags                 = local.tags
}

module "database" {
  source                     = "../../modules/database"
  name                       = local.name
  vpc_id                     = module.network.vpc_id
  database_subnet_ids        = module.network.database_subnet_ids
  allowed_security_group_ids = [module.eks.cluster_security_group_id]
  kms_key_arn                = module.eks.kms_key_arn
  ssm_prefix                 = "/africair/staging/db"
  tags                       = local.tags
}

module "platform" {
  source                = "../../modules/platform"
  cluster_name          = module.eks.cluster_name
  vpc_id                = module.network.vpc_id
  kms_key_arn           = module.eks.kms_key_arn
  rds_master_secret_arn = module.database.master_secret_arn
  ssm_db_prefix         = "/africair/staging/db"
  app_environments      = var.enable_production_namespace ? ["staging", "production"] : ["staging"]
  platform_secrets      = var.enable_argocd ? ["argocd", "grafana", "alertmanager"] : []
  backup_bucket_name    = "${local.name}-backups-${data.aws_caller_identity.current.account_id}"
  backup_environment    = "staging"
  install_controllers   = var.install_controllers_with_terraform
  argocd = {
    enabled     = var.enable_argocd
    values_file = "${path.root}/../../../../gitops/values/argocd.yaml"
  }
  tags = local.tags

  depends_on = [module.eks] # add-ons (EBS CSI, Pod Identity agent) before anything in the cluster
}

# --- TLS for the ALB (only with a domain) ----------------------------------------------------------
resource "aws_acm_certificate" "ingress" {
  count                     = var.domain_name == null ? 0 : 1
  domain_name               = "staging.${var.domain_name}"
  subject_alternative_names = ["argocd.${var.domain_name}", "grafana.${var.domain_name}", var.domain_name]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "acm_validation" {
  for_each = var.domain_name == null ? {} : {
    for o in aws_acm_certificate.ingress[0].domain_validation_options : o.domain_name => o
  }
  zone_id         = var.hosted_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "ingress" {
  count                   = var.domain_name == null ? 0 : 1
  certificate_arn         = aws_acm_certificate.ingress[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

data "aws_ecr_repository" "app" {
  for_each = toset(["africair-web", "africair-api"]) # created by envs/shared (Project 2)
  name     = each.value
}
