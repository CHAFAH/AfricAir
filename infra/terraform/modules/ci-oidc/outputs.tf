output "role_arns" {
  value = { for k, r in aws_iam_role.this : k => r.arn }
}

output "github_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
