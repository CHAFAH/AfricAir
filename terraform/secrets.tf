# Terraform generates the secrets and stores them in Secrets Manager. External Secrets Operator copies
# them into the cluster (deploy/helm/africair: ExternalSecrets africair-db and africair-app).
# The values are also in terraform.tfstate, which is why the state file is git-ignored.

resource "random_password" "admin_token" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project}/${var.environment}/app"
  recovery_window_in_days = 0 # delete immediately on destroy, so a new apply can reuse the name
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    ADMIN_TOKEN = random_password.admin_token.result
    PROMO_CODES = var.promo_codes
  })
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project}/${var.environment}/db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql://${aws_db_instance.this.username}:${random_password.db.result}@${aws_db_instance.this.endpoint}/${aws_db_instance.this.db_name}?sslmode=require"
    username     = aws_db_instance.this.username
    password     = random_password.db.result
    host         = aws_db_instance.this.address
    port         = aws_db_instance.this.port
    dbname       = aws_db_instance.this.db_name
  })
}
