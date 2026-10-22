# Inputs of the DOKS cluster. Production-shaped defaults; the course's ephemeral choices are values in
# terraform.tfvars, not baked into the module. Values that identify a person or an account have no default
# and are not in terraform.tfvars (the repository is public): TF_VAR_* from .env.doks.

variable "expected_account_uuid" {
  description = "UUID of the DigitalOcean user the token must belong to (doctl account get --format UUID). Any other account fails the plan. Set TF_VAR_expected_account_uuid."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.expected_account_uuid))
    error_message = "expected_account_uuid must be a UUID (doctl account get --format UUID)."
  }
}

variable "cluster_name" {
  description = "Name of the cluster; also names its VPC (<cluster_name>-doks) and the kubeconfig context doks-<cluster_name>-control-plane."
  type        = string
}

variable "region" {
  description = "DigitalOcean region (slug, e.g. fra1) of the VPC and the cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version (e.g. 1.36) - the platform's minor, as on kind and Hetzner. The newest DOKS release of it is used (data.digitalocean_kubernetes_versions)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version is a minor version like 1.36 - DOKS picks the patch."
  }
}

variable "ha" {
  description = "A highly available control plane (several API server replicas, an SLA; $40 a month). Once on, it cannot be turned off. DOKS turns it on by default from 1.36 - set here, never left to that default."
  type        = bool
  default     = true
}

variable "auto_upgrade" {
  description = "DOKS upgrades the cluster to new patch releases of its minor by itself, inside maintenance_policy. false: only what Terraform asks for."
  type        = bool
  default     = true
}

variable "maintenance_policy" {
  description = "When DOKS may upgrade (auto_upgrade): a day (monday..sunday, or any) and a start time, UTC."
  type = object({
    day        = string
    start_time = string
  })
  default = {
    day        = "sunday"
    start_time = "02:00"
  }

  validation {
    condition = (
      contains(["any", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"], var.maintenance_policy.day)
      && can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.maintenance_policy.start_time))
    )
    error_message = "maintenance_policy: day monday..sunday or any, start_time HH:MM."
  }
}

variable "control_plane_allowed_addresses" {
  description = "Public IPv4 ranges allowed to reach the Kubernetes API (DOKS control plane firewall; the nodes and DigitalOcean's own systems always are). [] leaves the API open to every address - the token still decides who gets in. A laptop's changing address would lock it out."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.control_plane_allowed_addresses : can(cidrhost(a, 0)) && !strcontains(a, ":")])
    error_message = "control_plane_allowed_addresses: IPv4 ranges only (DOKS does not take IPv6 here)."
  }
}

variable "vpc_cidr" {
  description = "The VPC's range: the nodes' private addresses. Must not overlap any other VPC of the team, nor the pod and service ranges."
  type        = string
}

variable "cluster_subnet" {
  description = "Pod range (VPC-native cluster: pods get addresses routable in the VPC; each node takes a /25). Cannot grow later - /16 is DigitalOcean's recommendation."
  type        = string
}

variable "service_subnet" {
  description = "Service range (/19 recommended, /22 at least). Cannot grow later."
  type        = string
}

# Two pools by role, as on the other clouds: the cluster's default pool for the platform, a second one for
# the applications.
variable "platform_pool" {
  description = "The default node pool, for the platform's own components (Flux, Kyverno, the database operator, monitoring) and DOKS's (Cilium, CoreDNS, the CSI driver)."
  type = object({
    size       = string
    node_count = number
  })
}

variable "apps_pool" {
  description = "The node pool for the applications."
  type = object({
    size       = string
    node_count = number
  })
}

variable "destroy_all_associated_resources" {
  description = "Deleting the cluster also deletes its load balancers, volumes and volume snapshots. false keeps them - a production volume is data; flux-pre-destroy.sh and make leftovers handle them either way."
  type        = bool
  default     = false
}

variable "doctl" {
  description = "doctl (github.com/digitalocean/doctl), which kubectl, Terraform and Helm get the cluster's token from: a name in PATH or a full path. The Makefile sets it from DOCTL."
  type        = string
  default     = "doctl"
}

variable "doctl_config" {
  description = "Full path of doctl's config file with the token (its \"default\" context) - DIGITALOCEAN_CONFIG; the kubeconfig's exec names it, so no other doctl config is read. The Makefile sets it."
  type        = string

  validation {
    condition     = startswith(var.doctl_config, "/")
    error_message = "doctl_config must be a full path (it is written into kubeconfig.yaml)."
  }
}

variable "metrics_server_chart_version" {
  description = "metrics-server Helm chart version (DOKS has no metrics-server; kind installs the same chart)."
  type        = string
  # renovate: datasource=helm depName=metrics-server registryUrl=https://kubernetes-sigs.github.io/metrics-server/
  default = "3.14.0"
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
  description = "The Flux profile this cluster reconciles (./flux/bootstrap/profiles/doks)."
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
