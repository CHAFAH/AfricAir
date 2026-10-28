variable "name" {
  description = "Name prefix, e.g. africair-team1-staging."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, for the kubernetes.io/cluster/<name> subnet tags."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.40.0.0/16"
}

variable "public_subnets" {
  description = "Three /24s for the ALB and the NAT gateway, one per AZ."
  type        = list(string)
  default     = ["10.40.0.0/24", "10.40.1.0/24", "10.40.2.0/24"]
  validation {
    condition     = length(var.public_subnets) == 3
    error_message = "Exactly three public subnets (one per AZ)."
  }
}

variable "private_subnets" {
  description = "Three /20s for nodes and pods (4,091 usable IPs each)."
  type        = list(string)
  default     = ["10.40.16.0/20", "10.40.32.0/20", "10.40.48.0/20"]
  validation {
    condition     = length(var.private_subnets) == 3
    error_message = "Exactly three private subnets (one per AZ)."
  }
}

variable "database_subnets" {
  description = "Three /24s for RDS, with no route to the internet."
  type        = list(string)
  default     = ["10.40.100.0/24", "10.40.101.0/24", "10.40.102.0/24"]
  validation {
    condition     = length(var.database_subnets) == 3
    error_message = "Exactly three database subnets (one per AZ)."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
