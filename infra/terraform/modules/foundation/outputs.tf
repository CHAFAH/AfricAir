output "web_server" {
  value = {
    instance_id = module.web_server.instance_id
    public_dns  = module.web_server.public_dns
    ssm         = module.web_server.ssm_command
  }
}

output "static_site" {
  value = {
    bucket          = module.static_site.bucket
    distribution_id = module.static_site.distribution_id
    url             = "https://${module.static_site.distribution_domain}"
  }
}

output "static_deployer_role_arn" {
  value = module.static_site.deployer_role_arn
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "deploy_bucket" {
  value = aws_s3_bucket.deploy.id
}

output "ci_role_arns" {
  description = "Set AWS_CI_ROLE_ARN / AWS_PRODUCTION_ROLE_ARN (GitHub) and the CircleCI contexts from these."
  value       = module.ci_oidc.role_arns
}

output "container_hosts" {
  value = { for env, h in module.container_host : env => "http://${h.public_dns}" }
}

output "account_id" {
  value = local.account
}

output "ecr_repository_arns" {
  value = module.ecr.repository_arns
}

output "github_ci_role_arn" {
  value = module.ci_oidc.role_arns["github-ci"]
}
