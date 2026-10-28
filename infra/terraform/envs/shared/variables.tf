variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "owner" {
  description = "Owner tag (Project 1 B1)."
  type        = string
}

variable "ssh_cidrs" {
  description = "Your IP/32 for SSH to the Project 1 server; [] = SSM only."
  type        = list(string)
  default     = []
}

variable "github_repository" {
  type    = string
  default = "CHAFAH/AfricAir"
}

variable "circleci_org_id" {
  type    = string
  default = null
}

variable "circleci_project_id" {
  type    = string
  default = null
}

variable "monthly_budget_usd" {
  type    = string
  default = "10"
}

variable "budget_email" {
  type = string
}
