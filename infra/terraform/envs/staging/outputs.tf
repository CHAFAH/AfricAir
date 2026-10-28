output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "oidc_issuer_url" {
  value = module.eks.oidc_issuer_url
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "account_id" {
  value = module.foundation.account_id
}

output "ecr_registry" {
  value = "${module.foundation.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = module.foundation.ecr_repository_urls
}

output "rds_endpoint" {
  value = module.database.endpoint
}

output "rds_master_secret_arn" {
  description = "ARN only: the value stays in Secrets Manager."
  value       = module.database.master_secret_arn
}

output "app_secret_arns" {
  value = module.platform.app_secret_arns
}

output "platform_secret_arns" {
  value = module.platform.platform_secret_arns
}

output "backup_bucket" {
  value = module.platform.backup_bucket
}

output "pod_identity_role_arns" {
  value = module.platform.role_arns
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  description = "Allowed by the NetworkPolicy as the ALB source range (target-type: ip)."
  value       = module.network.vpc_cidr
}

output "database_subnet_cidrs" {
  description = "Egress destinations for the API NetworkPolicy (5432)."
  value       = module.network.database_subnet_cidrs
}

output "acm_certificate_arn" {
  value = var.domain_name == null ? null : aws_acm_certificate_validation.ingress[0].certificate_arn
}

# --- Projects 1-3 ---------------------------------------------------------------------------------
output "ci_role_arns" {
  description = "GitHub: AWS_CI_ROLE_ARN = github-ci, AWS_PRODUCTION_ROLE_ARN = github-production. CircleCI contexts: circleci-*."
  value       = module.foundation.ci_role_arns
}

output "deploy_bucket" {
  value = module.foundation.deploy_bucket
}

output "container_hosts" {
  description = "Project 3 staging/production hosts (deployed by CI)."
  value       = module.foundation.container_hosts
}

output "web_server" {
  description = "Project 1 nginx server."
  value       = module.foundation.web_server
}

output "static_site" {
  description = "Project 1 S3 + CloudFront site."
  value       = module.foundation.static_site
}

output "static_deployer_role_arn" {
  value = module.foundation.static_deployer_role_arn
}
