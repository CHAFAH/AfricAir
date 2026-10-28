variable "project" {
  type    = string
  default = "africair"
}

variable "environment" {
  type    = string
  default = "stg"
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use (null = default credentials / AWS_PROFILE)."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "kubernetes_version" {
  description = "A version in standard support: aws eks describe-cluster-versions --status STANDARD_SUPPORT"
  type        = string
  default     = "1.35"
}

variable "api_allowed_cidrs" {
  description = "Who may reach the EKS API endpoint. Restrict to your IP (x.x.x.x/32)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "promo_codes" {
  description = "Promo codes stored in Secrets Manager (CODE:percent, comma-separated)."
  type        = string
  default     = "SAVE10:10,AFRICA20:20"
}

variable "github_repository" {
  description = "owner/name whose GitHub Actions (main branch) may push images and deploy. null = no CI role."
  type        = string
  default     = "CHAFAH/AfricAir"
}

variable "circleci_org_id" {
  description = "CircleCI organisation ID to create a CircleCI role. null = none."
  type        = string
  default     = null
}

variable "circleci_project_id" {
  type    = string
  default = null
}
