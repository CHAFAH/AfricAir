variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "team" {
  description = "Team name used in resource names and the Team tag."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.team))
    error_message = "Lower-case letters, digits and dashes, 2-20 characters."
  }
}

variable "kubernetes_version" {
  description = "Newest EKS version in STANDARD support (record the choice in docs/cluster-spec-evidence.md)."
  type        = string
}

variable "team_cidrs" {
  description = "Your team's public IP CIDRs: the only sources allowed on the public API endpoint."
  type        = list(string)
}

variable "admin_principal_arns" {
  description = "Team IAM role(s) granted cluster admin through access entries."
  type        = list(string)
}

variable "ci_role_arn" {
  description = "Project 3 CI role (envs/shared output github_ci_role_arn): edit rights in africair-staging."
  type        = string
  default     = null
}

variable "domain_name" {
  description = "Optional domain with a Route 53 zone: ACM certificate for staging., argocd. and grafana. hosts."
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = "Route 53 zone for domain_name (DNS validation of the certificate)."
  type        = string
  default     = null
}

variable "install_controllers_with_terraform" {
  description = "Project 4: true. Project 5: false once Argo CD manages ESO, LBC and Reloader (gitops/apps)."
  type        = bool
  default     = true
}

variable "enable_platform_node_group" {
  description = "Project 5: tainted platform node group for Argo CD and monitoring."
  type        = bool
  default     = false
}

variable "enable_argocd" {
  description = "Project 5: bootstrap Argo CD and create the platform secret containers."
  type        = bool
  default     = false
}

variable "enable_production_namespace" {
  description = "Project 5: create the africair/production/app secret container for the production Application."
  type        = bool
  default     = false
}
