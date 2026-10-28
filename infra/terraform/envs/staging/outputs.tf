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

output "ecr_repository_urls" {
  value = { for k, r in data.aws_ecr_repository.app : k => r.repository_url }
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
