output "region" {
  value = var.region
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}${var.aws_profile == null ? "" : " --profile ${var.aws_profile}"}"
}

output "ecr_registry" {
  value = split("/", aws_ecr_repository.app["africair-api"].repository_url)[0]
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "rds_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "secrets" {
  description = "Secrets Manager secrets (names only; read values with aws secretsmanager get-secret-value)."
  value = {
    app = aws_secretsmanager_secret.app.name
    db  = aws_secretsmanager_secret.db.name
  }
}

output "ci_role_arn" {
  description = "GitHub variable AWS_ROLE_ARN / CircleCI context variable AWS_ROLE_ARN."
  value       = try(aws_iam_role.ci[0].arn, null)
}
