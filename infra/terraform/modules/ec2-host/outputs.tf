output "instance_id" {
  value = aws_instance.this.id
}

output "instance_arn" {
  value = aws_instance.this.arn
}

output "public_dns" {
  value = aws_instance.this.public_dns
}

output "public_ip" {
  value = aws_instance.this.public_ip
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

output "ssm_command" {
  value = "aws ssm start-session --target ${aws_instance.this.id}"
}
