# Inputs of the GKE cluster. Production-shaped defaults; the course's ephemeral choices are values
# in terraform.tfvars, not baked into the module.

variable "project_id" {
  description = "The Google Cloud project (its foundation applied: infra/terraform/gcp_foundation)."
  type        = string
}

variable "region" {
  description = "Region of the VPC subnet, Cloud Router and Cloud NAT."
  type        = string
}

variable "zone" {
  description = "Zone of the cluster. A zonal cluster: one control plane, covered by GKE's free tier credit (one zonal cluster per billing account). A regional one survives a zone outage and costs the cluster fee."
  type        = string
}

variable "expected_principal" {
  description = "The identity that may run this module: a person's e-mail locally, the deployer service account in CI. Any other identity fails the plan. Set TF_VAR_expected_principal."
  type        = string
}

variable "cluster_name" {
  description = "Name of the cluster; also the prefix of its network resources."
  type        = string
}

variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR or STABLE. The channel picks the version; GKE upgrades within it."
  type        = string

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel is ${var.release_channel}; use RAPID, REGULAR or STABLE (EXTENDED costs extra, \"no channel\" ends 2027-06-14)."
  }
}

variable "nodes_cidr" {
  description = "Primary range of the subnet: node IPs (and the internal load balancers)."
  type        = string
}

variable "pods_cidr" {
  description = "Secondary range for Pod IPs (VPC-native cluster)."
  type        = string
}

variable "services_cidr" {
  description = "Secondary range for Service ClusterIPs."
  type        = string
}

# Two pools by role. spot: Spot VMs are 60-91 % cheaper, but Google may reclaim one with 30 seconds'
# notice - fine for a test cluster that is destroyed anyway, not a recommendation: a cluster that
# matters runs both pools on-demand (spot = false).
variable "platform_pool" {
  description = "Node pool for the platform's own components: Flux, Kyverno, the database operator, monitoring. A fixed size."
  type = object({
    machine_type = string
    node_count   = number
    disk_size_gb = number
    spot         = bool
  })
}

variable "apps_pool" {
  description = "Node pool for the applications; grows and shrinks with demand (cluster autoscaler)."
  type = object({
    machine_type   = string
    min_node_count = number
    max_node_count = number
    disk_size_gb   = number
    spot           = bool
  })
}

variable "nat_min_ports_per_vm" {
  description = "Cloud NAT dynamic port allocation: ports a node starts with."
  type        = number
}

variable "nat_max_ports_per_vm" {
  description = "Cloud NAT dynamic port allocation: the most ports one node may take (connections to one destination IP and port)."
  type        = number
}

variable "alert_channel_display_name" {
  description = "Display name of the notification channel the foundation created (its e-mail gets the Cloud NAT alerts)."
  type        = string
}

variable "deletion_protection" {
  description = "Refuse terraform destroy of the cluster. Keep true for a cluster that matters; the course's per-cycle cluster sets false."
  type        = bool
}
