variable "cluster_name" {
  type    = string
  default = "mke4k-lab"
}

# Owner name for the Owner tag on all resources; empty = no tag
variable "owner" {
  type    = string
  default = ""
}

# Auto-delete the whole lab this many days after creation (0 = never).
# Drives the self-contained expiry reaper in expiry.tf.
variable "expiry_days" {
  type    = number
  default = 3
}

# When true, the reaper Lambda logs what it would delete but deletes nothing.
variable "expiry_dry_run" {
  type    = bool
  default = false
}

# Anchor for the expiry countdown (RFC3339). Empty = use the lab's creation
# time (normal deploys). 't expiry <N>' sets this to "now" so the new deadline
# is now + expiry_days rather than creation + expiry_days.
variable "expiry_base" {
  type    = string
  default = ""
}

variable "controller_count" {
  type    = number
  default = 1
}

variable "worker_count" {
  type    = number
  default = 1
}

variable "controller_flavor" {
  type    = string
  default = "m5a.xlarge"
}

variable "worker_flavor" {
  type    = string
  default = "m5a.large"
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

variable "os_name" {
  type        = string
  default     = "ubuntu"
  description = "Cluster node OS: ubuntu or redhat (bastion/NFS server always run Ubuntu)"
  validation {
    condition     = contains(["ubuntu", "redhat"], var.os_name)
    error_message = "os_name must be 'ubuntu' or 'redhat'."
  }
}

variable "os_version" {
  type        = string
  default     = "22.04"
  description = "Cluster node OS version, e.g. 22.04/24.04 (ubuntu) or 9.6/8.10 (redhat)"
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.os_version))
    error_message = "os_version must look like '22.04' or '9.6'."
  }
}

variable "mke3_enabled" {
  type        = bool
  default     = false
  description = "When true, provision a second NLB for MKE3 alongside the MKE4k NLB"
}

variable "airgap_enabled" {
  type        = bool
  default     = false
  description = "When true, create bastion/registry host and private subnet for cluster nodes"
}

variable "airgap_registry_flavor" {
  type        = string
  default     = "t3.xlarge"
  description = "EC2 instance type for the bastion/registry host"
}

variable "airgap_registry_disk_gb" {
  type        = number
  default     = 100
  description = "Root volume size in GB for the bastion/registry host"
}

variable "nfs_enabled" {
  type        = bool
  default     = false
  description = "When true, provision a dedicated NFS server EC2 instance"
}

variable "nfs_flavor" {
  type        = string
  default     = "t3.small"
  description = "EC2 instance type for the NFS server"
}

variable "nfs_disk_gb" {
  type        = number
  default     = 50
  description = "Root volume size in GB for the NFS server"
}

variable "kof_grafana_gateway_enabled" {
  type        = bool
  default     = false
  description = "When true, add an NLB listener + target group forwarding to the KOF Grafana Envoy gateway NodePort"
}

variable "kof_grafana_nodeport" {
  type        = number
  default     = 33002
  description = "NodePort the KOF Grafana Envoy gateway is pinned to (opened in the cluster SG; NLB forwards here)"
}

variable "kof_grafana_lb_port" {
  type        = number
  default     = 8443
  description = "NLB listener port for KOF Grafana (TCP pass-through; the gateway terminates TLS)"
}

variable "k0rdent_ui_enabled" {
  type        = bool
  default     = false
  description = "When true, add an NLB listener + target group forwarding to the k0rdent UI Envoy gateway NodePort"
}

variable "k0rdent_ui_nodeport" {
  type        = number
  default     = 33003
  description = "NodePort the k0rdent UI Envoy gateway is pinned to (opened in the cluster SG; NLB forwards here)"
}

variable "k0rdent_ui_lb_port" {
  type        = number
  default     = 8445
  description = "NLB listener port for the k0rdent UI (TCP pass-through; the gateway terminates TLS)"
}
