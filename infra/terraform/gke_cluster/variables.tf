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

# ─── Flux ─────────────────────────────────────────────────────────────────────
# The same inputs as the Hetzner cluster's (infra/terraform/hcloud_cluster/variables.tf).

variable "flux_operator_version" {
  description = "Flux Operator release to install (install.yaml from its GitHub release)."
  type        = string
  # renovate: datasource=github-releases depName=controlplaneio-fluxcd/flux-operator
  default = "0.61.0"
}

variable "flux_version" {
  description = "Flux version the FluxInstance installs. Pinned, so a rebuild gets the same Flux."
  type        = string
  # renovate: datasource=github-releases depName=fluxcd/flux2
  default = "2.9.6"
}

variable "flux_git_repository_url" {
  description = "Git repository Flux follows (https://github.com/<owner>/<repo>.git)."
  type        = string
}

variable "flux_git_repository_branch" {
  description = "Git branch Flux follows. Not in terraform.tfvars on purpose: a cycle that tests a branch sets TF_VAR_flux_git_repository_branch, and a tfvars value would win over it."
  type        = string
  default     = "main"
}

variable "flux_kustomization_path" {
  description = "The Flux profile this cluster reconciles (./flux/bootstrap/profiles/gke)."
  type        = string
}

variable "sops_age_key" {
  description = "age private key for SOPS decryption in Flux: the key line or the whole age key file. Ephemeral: needed for every plan and apply, never stored in the plan or the state. The Makefile reads it from SOPS_AGE_KEY_FILE."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = strcontains(var.sops_age_key, "AGE-SECRET-KEY-")
    error_message = "sops_age_key must contain an age private key (AGE-SECRET-KEY-...): Flux cannot decrypt flux/secrets/** without it."
  }
}

variable "sops_age_key_revision" {
  description = "Bump after rotating sops_age_key: the key is write-only, so Terraform re-sends it only when this number changes."
  type        = number
  default     = 1
}

variable "logging_components" {
  description = <<-EOT
    What GKE sends to Cloud Logging. SYSTEM_COMPONENTS: kube-system and GKE's own agents on the nodes - the
    only record of what Google runs for you. WORKLOADS: every container's stdout/stderr, a second copy next
    to Uptrace (the OpenTelemetry collector reads the same lines), kept in Google Cloud 30 days. Billed per GiB
    ingested beyond the free monthly allotment of each project.
  EOT
  type        = list(string)
  default     = ["SYSTEM_COMPONENTS", "WORKLOADS"]
}

variable "flow_logs" {
  description = <<-EOF
    VPC Flow Logs on the nodes' subnet and intranode visibility on the cluster: sampled connection records
    (source, destination, port, bytes; half of the flows, so a short connection may be missing), also Pod to
    Pod on one node - what answers "who talked to what" after an incident. Not a record of what a
    NetworkPolicy denied: that is GKE's network policy logging (Dataplane V2). Sent to Cloud Logging and
    billed per GiB from the first byte (network telemetry pricing; not part of Cloud Logging's free allotment).
  EOF
  type        = bool
  default     = true
}

variable "uptrace_dsn" {
  description = "Uptrace DSN the OpenTelemetry collectors send logs, traces and metrics to (cluster-secrets)."
  type        = string
  sensitive   = true

  # Required, not optional: the OpenTelemetry collector runs on this cluster whatever the value, and with
  # no DSN every log, trace and metric it reads is dropped, with nothing but an error in its own log.
  validation {
    condition     = var.uptrace_dsn != ""
    error_message = "uptrace_dsn is empty - it is required: the Uptrace project's DSN (https://<token>@api.uptrace.dev...). Uptrace Cloud has a free plan: https://uptrace.dev. Destroying without one: any https:// value passes."
  }
  validation {
    condition     = var.uptrace_dsn == "" || startswith(var.uptrace_dsn, "https://")
    error_message = "uptrace_dsn is set but does not start with https:// - a DSN looks like https://<token>@api.uptrace.dev... (no quotes or spaces around it)."
  }
}

variable "image_registry" {
  description = "Container image registry prefix of the platform's images (cluster-config)."
  type        = string
}

variable "git_owner" {
  description = "GitHub organization or user that owns the repositories (cluster-config; image automation, signature checks)."
  type        = string
}

# CNPG backups: every cluster, of every provider, backs up to Cloudflare R2 - a bucket of its own, never
# the state bucket, with a token scoped to that bucket.
variable "backup_s3_endpoint" {
  description = "S3 endpoint of the CNPG backups (ConfigMap backup-s3), e.g. https://<account>.r2.cloudflarestorage.com."
  type        = string

  # The CNPG ObjectStore rejects an empty endpointURL, and Flux then refuses the whole cnpg-cluster-<env>
  # Kustomization - no database at all (seen 2026-10-15). Fail the plan instead.
  validation {
    condition     = startswith(var.backup_s3_endpoint, "https://")
    error_message = "backup_s3_endpoint is \"${var.backup_s3_endpoint}\"; set the https:// endpoint of the backup bucket - an empty one leaves the cluster without databases."
  }
}

variable "backup_s3_bucket" {
  description = "Bucket of the CNPG backups (ConfigMap backup-s3, Secret cnpg-backup-s3). Set TF_VAR_backup_s3_bucket."
  type        = string
}

variable "backup_s3_region" {
  description = "Region of the backup bucket (\"auto\" for R2)."
  type        = string
}

variable "backup_s3_access_key_id" {
  description = "Access key of the backup bucket (Secret cnpg-backup-s3). Set TF_VAR_backup_s3_access_key_id."
  type        = string
  sensitive   = true
}

variable "backup_s3_secret_access_key" {
  description = "Secret key of the backup bucket (Secret cnpg-backup-s3). Set TF_VAR_backup_s3_secret_access_key."
  type        = string
  sensitive   = true
}
