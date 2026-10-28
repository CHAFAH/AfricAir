variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  description = "Passed to the Load Balancer Controller (it cannot reach IMDS with hop limit 1)."
  type        = string
}

variable "kms_key_arn" {
  description = "Environment key: Secrets Manager secrets, RDS secret, backup bucket."
  type        = string
}

variable "rds_master_secret_arn" {
  description = "Full ARN (with the -xxxxxx suffix) of the RDS-managed master secret."
  type        = string
}

variable "ssm_db_prefix" {
  description = "e.g. /africair/staging/db"
  type        = string
}

variable "app_environments" {
  description = "One africair/<env>/app secret container per environment (staging, production)."
  type        = list(string)
  default     = ["staging"]
}

variable "platform_secrets" {
  description = "africair/platform/<name> containers (Project 5: argocd, grafana, alertmanager)."
  type        = list(string)
  default     = []
}

variable "backup_bucket_name" {
  type = string
}

variable "backup_environment" {
  type    = string
  default = "staging"
}

variable "install_controllers" {
  description = "Install LBC, ESO and Reloader with Terraform (Project 4). false once Argo CD manages them (Project 5)."
  type        = bool
  default     = true
}

variable "chart_versions" {
  type = object({
    aws_load_balancer_controller = string
    external_secrets             = string
    reloader                     = string
  })
  default = {
    aws_load_balancer_controller = "3.6.2"
    external_secrets             = "2.14.0"
    reloader                     = "2.2.19"
  }
}

variable "argocd" {
  description = "Project 5 bootstrap install of Argo CD."
  type = object({
    enabled       = bool
    chart_version = optional(string, "10.11.6")
    values_file   = optional(string, "")
  })
  default = { enabled = false }
}

variable "tags" {
  type    = map(string)
  default = {}
}
