# RDS for PostgreSQL 16 (latest minor), private, TLS-only, master password managed by RDS in
# Secrets Manager: no password in code, variables, state or outputs.

terraform {
  required_version = "~> 1.13"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"
  version = var.engine_major_version
  latest  = true # newest 16.x minor available in the region
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.database_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "PostgreSQL from the EKS cluster security group only"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-db" })
}

# Only security-group references, no CIDR rules: a pod is allowed because it runs on a node in the
# EKS cluster security group (VPC CNI pods use the node's security group).
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from ${each.value}"
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-pg${var.engine_major_version}"
  family = data.aws_rds_engine_version.postgres.parameter_group_family
  parameter {
    name  = "rds.force_ssl"
    value = "1" # plaintext connections are refused (troubleshooting drill 5: DB_SSL must be require/verify)
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  tags = var.tags
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = data.aws_rds_engine_version.postgres.version
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_name  = var.db_name
  username = var.master_username
  # RDS generates the password, stores it in Secrets Manager (encrypted with kms_key_arn) and rotates it.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = false # staging; production: true
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period             = 7
  copy_tags_to_snapshot               = true
  deletion_protection                 = false # staging only
  skip_final_snapshot                 = true  # staging only
  auto_minor_version_upgrade          = true
  apply_immediately                   = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  tags = var.tags
}

# Discovery for the ExternalSecret that builds DATABASE_URL (host/port/name are not secrets).
resource "aws_ssm_parameter" "db" {
  for_each = {
    host = aws_db_instance.this.address
    port = tostring(aws_db_instance.this.port)
    name = var.db_name
  }
  name  = "${var.ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value
  tags  = var.tags
}
