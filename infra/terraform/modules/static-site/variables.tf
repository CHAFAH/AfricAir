variable "name" {
  type = string
}

variable "bucket_name" {
  type = string
}

variable "deployer_policy_template" {
  description = "Path to deploy/iam/deployer-policy.json (rendered with bucket_name, account_id, distribution_id)."
  type        = string
}

variable "deployer_trusted_principal_arns" {
  description = "Who may assume the deployer role (e.g. your admin role) to run publish-s3.sh."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
