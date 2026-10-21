# Inputs of the AKS cluster. Production-shaped defaults; the course's ephemeral choices are values in
# terraform.tfvars, not baked into the module. Values that identify a person, a tenant or a subscription
# have no default and are not in terraform.tfvars (the repository is public): TF_VAR_* from .env.azure.

variable "location" {
  description = "The Azure region of the cluster - the foundation's location (its resource group is there)."
  type        = string
}

variable "subscription_id" {
  description = "The Azure subscription of the platform (a GUID). Every call goes to it. Set TF_VAR_subscription_id."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.subscription_id))
    error_message = "subscription_id must be the subscription's GUID (az account show --query id -o tsv)."
  }
}

variable "tenant_id" {
  description = "The Microsoft Entra tenant of the subscription (a GUID); the cluster accepts tokens of this tenant only. Set TF_VAR_tenant_id."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.tenant_id))
    error_message = "tenant_id must be the tenant's GUID (az account show --query tenantId -o tsv)."
  }
}

variable "expected_principal_object_id" {
  description = "Object id of the identity that may run this module - the person the foundation made Kubernetes admin. Any other identity fails the plan. Set TF_VAR_expected_principal_object_id."
  type        = string
}

variable "cluster_name" {
  description = "Name of the cluster - the foundation's cluster_name: the cluster is built in its resource group <cluster_name>-aks."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the control plane and the node pools (e.g. 1.36) - the platform's minor, as on kind and Hetzner. AKS picks the patch."
  type        = string
}

variable "sku_tier" {
  description = "The control plane's tier. Standard: an uptime SLA and a control plane that scales with the cluster ($0.10 an hour). Free: no SLA, meant for clusters under 10 nodes. Premium adds long-term support."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "automatic_upgrade_channel" {
  description = "How AKS upgrades Kubernetes by itself, inside the maintenance window. patch: the newest patch of the pinned minor - the minor changes only with kubernetes_version (stable or rapid would move the minor away from it). none: only what Terraform asks for."
  type        = string
  default     = "patch"

  validation {
    condition     = contains(["none", "patch"], var.automatic_upgrade_channel)
    error_message = "automatic_upgrade_channel must be patch or none: the minor version is kubernetes_version's."
  }
}

variable "node_os_upgrade_channel" {
  description = "How the nodes' operating system gets security updates. NodeImage: a new node image every week, rolled out node by node inside the maintenance window (no reboot daemon needed). None: the image the node started with."
  type        = string
  default     = "NodeImage"

  validation {
    condition     = contains(["None", "Unmanaged", "SecurityPatch", "NodeImage"], var.node_os_upgrade_channel)
    error_message = "node_os_upgrade_channel must be None, Unmanaged, SecurityPatch or NodeImage."
  }
}

variable "maintenance_window" {
  description = "When AKS may upgrade (both channels): a weekly window, UTC. At least 4 hours, as AKS requires."
  type = object({
    day_of_week    = string
    start_time     = string
    duration_hours = number
  })
  default = {
    day_of_week    = "Sunday"
    start_time     = "02:00"
    duration_hours = 4
  }
}

variable "pod_cidrs" {
  description = "Pod address ranges, IPv4 and IPv6 (Azure CNI Overlay: pods are not in the node network). Must not overlap the service ranges or AKS's managed node network (10.224.0.0/12)."
  type        = list(string)

  validation {
    condition     = length(var.pod_cidrs) == 2 && can(cidrhost(var.pod_cidrs[0], 0)) && strcontains(var.pod_cidrs[1], ":")
    error_message = "pod_cidrs must be [IPv4 range, IPv6 range] - the cluster is dual-stack."
  }
}

variable "service_cidrs" {
  description = "Service address ranges, IPv4 and IPv6 (the IPv6 one /108 or smaller). The DNS service gets the 10th address of the IPv4 range."
  type        = list(string)

  validation {
    condition     = length(var.service_cidrs) == 2 && can(cidrhost(var.service_cidrs[0], 10)) && strcontains(var.service_cidrs[1], ":")
    error_message = "service_cidrs must be [IPv4 range, IPv6 range] - the cluster is dual-stack."
  }
}

# Two pools by role, both on-demand. Spot is possible only for the apps pool (never the system pool),
# and AKS taints Spot nodes, so every app pod would need a toleration - not done here.
variable "platform_pool" {
  description = "The system node pool, for the platform's own components (Flux, Kyverno, the database operator, monitoring) and AKS's (CoreDNS, the CSI drivers, Cilium)."
  type = object({
    vm_size      = string
    node_count   = number
    disk_size_gb = number
  })
}

variable "apps_pool" {
  description = "The user node pool for the applications."
  type = object({
    vm_size      = string
    node_count   = number
    disk_size_gb = number
  })
}

variable "control_plane_log_categories" {
  description = <<-EOT
    Control-plane logs AKS sends to a Log Analytics workspace: kube-apiserver, kube-audit (every request -
    large), kube-audit-admin (the audit log without get and list: who changed what - the only record of it
    on AKS), guard (Microsoft Entra and Azure RBAC sign-ins), kube-controller-manager, kube-scheduler,
    cluster-autoscaler. Billed per GiB ingested and stored. [] turns them off - and creates no workspace.
  EOT
  type        = list(string)
  default     = ["kube-apiserver", "kube-audit-admin", "guard"]

  validation {
    condition     = alltrue([for c in var.control_plane_log_categories : contains(["kube-apiserver", "kube-audit", "kube-audit-admin", "guard", "kube-controller-manager", "kube-scheduler", "cluster-autoscaler"], c)])
    error_message = "control_plane_log_categories: only kube-apiserver, kube-audit, kube-audit-admin, guard, kube-controller-manager, kube-scheduler and cluster-autoscaler."
  }
}

variable "log_retention_days" {
  description = "How long the Log Analytics workspace keeps the control-plane logs (30-730 days)."
  type        = number
  default     = 90
}

variable "kubelogin" {
  description = "Azure kubelogin (github.com/Azure/kubelogin), which kubectl and Terraform get the cluster's Entra token from: a name in PATH or a full path. A full path when another `kubelogin` comes first - Homebrew's kubelogin is int128's OIDC plugin, a different tool. The Makefile sets it from AZURE_KUBELOGIN."
  type        = string
  default     = "kubelogin"
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
  description = "The Flux profile this cluster reconciles (./flux/bootstrap/profiles/aks)."
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
