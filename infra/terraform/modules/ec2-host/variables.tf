variable "name" {
  type = string
}

variable "role" {
  description = "web-server (Project 1) or container-host (Project 3)."
  type        = string
  validation {
    condition     = contains(["web-server", "container-host"], var.role)
    error_message = "role must be web-server or container-host."
  }
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "root_volume_gib" {
  type    = number
  default = 20
}

variable "ssh_cidrs" {
  description = "Your IP for port 22 (Project 1 B1). Empty = no SSH, Session Manager only (the stretch goal)."
  type        = list(string)
  default     = []
}

variable "extra_policy_json" {
  description = "Additional inline policy for the instance role."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
