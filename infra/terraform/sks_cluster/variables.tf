# Inputs of the SKS cluster. Production-shaped defaults; the course's ephemeral choices are values in
# terraform.tfvars, not baked into the module. Values that identify a person or an organization have no
# default and are not in terraform.tfvars (the repository is public): TF_VAR_* from .env.sks.

variable "expected_default_security_group_id" {
  description = "Id of the organization's default security group (exo compute security-group show default) - it tells the organization the API key belongs to, which a compute-only key cannot read from IAM. Any other organization fails the plan. Set TF_VAR_expected_default_security_group_id."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.expected_default_security_group_id))
    error_message = "expected_default_security_group_id must be a UUID (exo compute security-group show default)."
  }
}

variable "cluster_name" {
  description = "Name of the cluster; also names its security group (<cluster_name>-sks-nodes), the nodes (<cluster_name>-platform-..., <cluster_name>-apps-...) and the kubeconfig context sks-<cluster_name>-control-plane."
  type        = string
}

variable "zone" {
  description = "Exoscale zone of the cluster and its nodes (e.g. bg-sof-1; exo zone list)."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes release of the control plane at creation (e.g. 1.36.5) - one SKS offers (exo compute sks versions; make access checks it). The platform's minor, as on kind and Hetzner."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version is a release like 1.36.5 (exo compute sks versions)."
  }
}

variable "service_level" {
  description = "Control plane service level: pro (highly available, an SLA) or starter (free, no SLA). Set at creation; starter can be upgraded to pro later, never the reverse."
  type        = string
  default     = "pro"

  validation {
    condition     = contains(["pro", "starter"], var.service_level)
    error_message = "service_level is pro or starter."
  }
}

variable "auto_upgrade" {
  description = "Exoscale upgrades the control plane to new patch releases of its minor by itself. false: only what a person asks for (exo compute sks upgrade)."
  type        = bool
  default     = true
}

# Two pools by role, as on the other clouds: one for the platform, one for the applications.
variable "platform_pool" {
  description = "The node pool for the platform's own components (Flux, Kyverno, the database operator, monitoring) and SKS's (Cilium, CoreDNS, the CSI driver). disk_size in GiB."
  type = object({
    instance_type = string
    size          = number
    disk_size     = number
  })
}

variable "apps_pool" {
  description = "The node pool for the applications. disk_size in GiB."
  type = object({
    instance_type = string
    size          = number
    disk_size     = number
  })
}

variable "exo" {
  description = "exo (github.com/exoscale/cli), which kubectl and Terraform get the cluster's client certificate from: a name in PATH or a full path. The Makefile sets it from EXO."
  type        = string
  default     = "exo"
}

variable "exo_config" {
  description = "Full path of exo's config file with the API key - EXOSCALE_CONFIG; the kubeconfig's exec names it, so no other exo config is read. The Makefile sets it."
  type        = string

  validation {
    condition     = startswith(var.exo_config, "/")
    error_message = "exo_config must be a full path (it is written into kubeconfig.yaml)."
  }
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
  description = "The Flux profile this cluster reconciles (./flux/bootstrap/profiles/sks)."
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
