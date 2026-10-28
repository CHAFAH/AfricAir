output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "azs" {
  value = local.azs
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  value = aws_subnet.database[*].id
}

output "database_subnet_cidrs" {
  value = aws_subnet.database[*].cidr_block
}

output "nat_public_ip" {
  description = "Egress IP of the cluster (allow-list it where needed)."
  value       = aws_eip.nat.public_ip
}
