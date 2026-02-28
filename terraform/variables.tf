variable "cluster_name" {
  type    = string
  default = "mke4k-lab"
}

variable "controller_count" {
  type    = number
  default = 1
}

variable "worker_count" {
  type    = number
  default = 1
}

variable "cluster_flavor" {
  type    = string
  default = "m5.xlarge"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "mke4k_version" {
  type    = string
  default = "v4.1.2"
}

variable "ccm_enabled" {
  type        = bool
  default     = true
  description = "Create IAM role/profile for AWS CCM and enable cloudProvider in mke4.yaml"
}

variable "os_distro" {
  type        = string
  default     = "ubuntu-22.04"
  description = "OS distribution: ubuntu-22.04 or ubuntu-24.04"
  validation {
    condition     = contains(["ubuntu-22.04", "ubuntu-24.04"], var.os_distro)
    error_message = "os_distro must be 'ubuntu-22.04' or 'ubuntu-24.04'."
  }
}
