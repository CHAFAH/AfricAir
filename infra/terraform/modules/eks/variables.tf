variable "name" {
  description = "Cluster name, e.g. africair-team1-staging."
  type        = string
}

variable "kubernetes_version" {
  description = "Newest version in STANDARD support when you start: aws eks describe-cluster-versions --status STANDARD_SUPPORT --query 'clusterVersions[].clusterVersion'"
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets for the control-plane ENIs and the nodes."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (your team's IPs). Never 0.0.0.0/0."
  type        = list(string)
  validation {
    condition     = length(var.public_access_cidrs) > 0 && !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Restrict the public endpoint to your team's CIDRs."
  }
}

variable "admin_principal_arns" {
  description = "IAM roles/users that get AmazonEKSClusterAdminPolicy (your team role)."
  type        = list(string)
}

variable "ci_role_arn" {
  description = "Project 3 CI role: AmazonEKSEditPolicy on ci_namespaces only. null to skip."
  type        = string
  default     = null
}

variable "ci_namespaces" {
  type    = list(string)
  default = ["africair-staging"]
}

variable "node_groups" {
  description = "Managed node groups. Project 4: general; Project 5 adds platform (tainted)."
  type = map(object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
    disk_size_gib  = optional(number, 30)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
