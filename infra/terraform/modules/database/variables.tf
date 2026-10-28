variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "database_subnet_ids" {
  description = "The isolated database subnets."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed on 5432 (the EKS cluster security group)."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "Key for storage encryption and the RDS-managed master secret."
  type        = string
}

variable "engine_major_version" {
  type    = string
  default = "16"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_name" {
  type    = string
  default = "africair"
}

variable "master_username" {
  type    = string
  default = "africair"
}

variable "ssm_prefix" {
  description = "SSM path for host/port/name, e.g. /africair/staging/db."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
