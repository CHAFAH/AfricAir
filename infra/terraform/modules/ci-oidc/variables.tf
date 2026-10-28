variable "github_repository" {
  description = "owner/name, e.g. CHAFAH/AfricAir. Tokens from forks carry a different sub and are rejected."
  type        = string
}

variable "circleci_org_id" {
  description = "CircleCI organisation ID (Organization Settings → Overview). null = no CircleCI roles."
  type        = string
  default     = null
}

variable "circleci_project_id" {
  description = "CircleCI project ID (Project Settings → Overview)."
  type        = string
  default     = null
}

variable "ecr_repository_arns" {
  type = list(string)
}

variable "deploy_bucket_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
