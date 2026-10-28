# Small PostgreSQL 16 instance in the private subnets, reachable only from the EKS cluster.

resource "random_password" "db" {
  length  = 32
  special = false # safe inside DATABASE_URL without URL-encoding
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "PostgreSQL from the EKS cluster"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "PostgreSQL from the EKS nodes and pods"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }
}

resource "aws_db_parameter_group" "this" {
  name   = "${local.name}-pg16"
  family = "postgres16"
  parameter {
    name  = "rds.force_ssl"
    value = "1" # TLS only (the app uses DB_SSL=require)
  }
}

resource "aws_db_instance" "this" {
  identifier              = local.name
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp3"
  storage_encrypted       = true
  db_name                 = "africair"
  username                = "africair"
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  parameter_group_name    = aws_db_parameter_group.this.name
  publicly_accessible     = false
  multi_az                = false
  backup_retention_period = 7
  skip_final_snapshot     = true # staging
  deletion_protection     = false
  apply_immediately       = true
}
