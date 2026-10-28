output "app_secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}

output "platform_secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.platform : k => s.arn }
}

output "backup_bucket" {
  value = aws_s3_bucket.backup.id
}

output "role_arns" {
  value = {
    external_secrets             = aws_iam_role.eso.arn
    aws_load_balancer_controller = aws_iam_role.lbc.arn
    backup                       = aws_iam_role.backup.arn
  }
}
