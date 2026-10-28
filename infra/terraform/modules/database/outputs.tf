output "endpoint" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "engine_version" {
  value = aws_db_instance.this.engine_version_actual
}

output "master_secret_arn" {
  description = "ARN of the RDS-managed master secret (never its value)."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "ssm_parameter_arns" {
  value = { for k, p in aws_ssm_parameter.db : k => p.arn }
}
