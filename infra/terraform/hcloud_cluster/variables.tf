# ─── Secrets (set via TF_VAR_* from load-env.sh) ─────────────────────────────

variable "hcloud_token" {
  description = "Hetzner Cloud API token (HCLOUD_TOKEN)."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for cluster nodes (ed25519)."
  type        = string
}

# No ssh_private_key: Terraform reaches the nodes through ssh-agent (ssh-add the key that
# matches ssh_public_key before plan/apply), so the private key is never a Terraform value.

variable "flux_git_token" {
  description = "Optional token for private repo sync. For GitHub, a fine-grained token with Contents:Read (or classic token with repo scope). Leave empty for public repos."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ghcr_username" {
  description = "Optional GHCR username for pulling private images."
  type        = string
  default     = ""
}

variable "ghcr_token" {
  description = "Optional GHCR token for pulling private images (read:packages). Leave empty if images are public."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_ghcr" {
  description = "Whether to create GHCR imagePullSecrets (must be true when ghcr_token is set)."
  type        = bool
  default     = false
}

variable "sops_age_key" {
  description = "age private key (AGE-SECRET-KEY-...) for SOPS decryption in Flux. Ephemeral: needed for every plan and apply, never stored in the plan or the state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = startswith(var.sops_age_key, "AGE-SECRET-KEY-")
    error_message = "sops_age_key must be an age private key (AGE-SECRET-KEY-...): Flux cannot decrypt flux/secrets/** without it."
  }
}

variable "sops_age_key_revision" {
  description = "Bump after rotating sops_age_key: the key is write-only, so Terraform re-sends it only when this number changes."
  type        = number
  default     = 1
}

variable "backup_s3_access_key_id" {
  description = "Optional S3 access key for CNPG and etcd backups (Hetzner Object Storage, BACKUP_S3). Set together with backup_s3_secret_access_key and backup_s3_bucket."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_s3_secret_access_key" {
  description = "Optional S3 secret key for CNPG and etcd backups (Hetzner Object Storage, BACKUP_S3). Set together with backup_s3_access_key_id and backup_s3_bucket."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_s3_bucket" {
  description = "Optional bucket for CNPG and etcd backups, for example safeops-sre-backups. Set together with backup_s3_access_key_id and backup_s3_secret_access_key."
  type        = string
  default     = ""
}

variable "backup_s3_endpoint" {
  description = "Optional S3 endpoint, for example https://nbg1.your-objectstorage.com."
  type        = string
  default     = ""
}

variable "backup_s3_region" {
  description = "Optional S3 region, for example nbg1."
  type        = string
  default     = ""
}

# ─── Cluster Identity ────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Cluster name (used for resources and kubeconfig context)."
  type        = string
  default     = "sre"
}

variable "location" {
  description = "Hetzner location for servers and load balancer (e.g. nbg1, fsn1, hel1)."
  type        = string
  default     = "nbg1"
}

variable "load_balancer_type" {
  description = "Hetzner load balancer type (e.g. lb11)."
  type        = string
  default     = "lb11"
}

# ─── Server Types ────────────────────────────────────────────────────────────

variable "control_plane_server_type" {
  description = "Hetzner server type for the control plane."
  type        = string
  default     = "cx23"
}

variable "control_plane_count" {
  description = "Number of control plane nodes (1 for non-HA, 3 for HA)."
  type        = number
  default     = 1
}

variable "allow_scheduling_on_control_plane" {
  description = "Allow workloads on control plane nodes (set true for single-node test clusters)."
  type        = bool
  default     = false
}

variable "workers_server_type" {
  description = "Hetzner server type for worker nodes."
  type        = string
  default     = "cx23"
}

variable "workers_count" {
  description = "Number of static worker nodes (ignored when autoscaling is enabled)."
  type        = number
  default     = 1
}

# ─── Autoscaling ─────────────────────────────────────────────────────────────

variable "autoscaling_enabled" {
  description = "Enable cluster autoscaler for the workers pool. When true, workers_count is ignored and min/max nodes apply instead."
  type        = bool
  default     = false
}

variable "autoscaling_min_nodes" {
  description = "Minimum number of autoscaled worker nodes."
  type        = number
  default     = 0
}

variable "autoscaling_max_nodes" {
  description = "Maximum number of autoscaled worker nodes."
  type        = number
  default     = 5
}

# ─── K3s & OS Upgrades ──────────────────────────────────────────────────────

variable "k3s_channel" {
  description = "K3s release channel (e.g. v1.34, stable). Used when k3s_version is empty."
  type        = string
  default     = "stable"
}

variable "k3s_version" {
  description = "Pin an exact K3s version (e.g. v1.34.0+k3s1). Overrides k3s_channel when set."
  type        = string
  default     = "v1.36.4+k3s1"
}

variable "auto_upgrade_k3s" {
  description = "Automatically upgrade K3s when a new patch appears on the selected channel."
  type        = bool
  default     = true
}

variable "auto_upgrade_os" {
  description = "Automatically apply OS security updates (requires kured for reboots). Disable for single-node clusters."
  type        = bool
  default     = true
}

# ─── Kured (Kubernetes Reboot Daemon) ───────────────────────────────────────

variable "kured_enabled" {
  description = "Enable kured for coordinated node reboots after OS updates."
  type        = bool
  default     = true
}

variable "kured_reboot_days" {
  description = "Days when kured is allowed to reboot nodes (comma-separated, e.g. sat,sun)."
  type        = string
  default     = "sat,sun"
}

variable "kured_start_time" {
  description = "Start of the kured reboot window (24h format, e.g. 02:00)."
  type        = string
  default     = "02:00"
}

variable "kured_end_time" {
  description = "End of the kured reboot window (24h format, e.g. 05:00)."
  type        = string
  default     = "05:00"
}

# ─── Ingress ─────────────────────────────────────────────────────────────────

variable "ingress_controller" {
  description = "Ingress controller to deploy (traefik, nginx, haproxy, none)."
  type        = string
  default     = "traefik"
}

variable "traefik_redirect_to_https" {
  description = "Redirect HTTP to HTTPS in traefik."
  type        = bool
  default     = true
}

variable "traefik_autoscaling" {
  description = "Enable HPA for traefik pods."
  type        = bool
  default     = true
}

# ─── Flux ────────────────────────────────────────────────────────────────────

variable "flux_operator_version" {
  description = "Flux Operator release to install (install.yaml from its GitHub release)."
  type        = string
  default     = "0.60.0"
}

variable "flux_version" {
  description = "Flux version the FluxInstance installs. Pinned, so a rebuild gets the same Flux."
  type        = string
  default     = "2.9.5"
}

variable "flux_git_repository_url" {
  description = "Git repository URL Flux should sync (e.g. https://github.com/<owner>/<repo>.git)."
  type        = string
}

variable "flux_git_repository_branch" {
  description = "Git branch Flux should track."
  type        = string
  default     = "main"
}

variable "flux_kustomization_path" {
  description = "Path within the Git repository to reconcile (relative to repository root)."
  type        = string
  default     = "./flux/bootstrap/flux-system"
}

# ─── OIDC / Authentication ─────────────────────────────────────────────────────

variable "oidc_issuer_url" {
  description = "OIDC issuer the kube-apiserver trusts (Dex). Empty disables OIDC login for kubectl and Headlamp."
  type        = string
  default     = "https://dex.safeops.work"
}

variable "oidc_audiences" {
  description = "Dex client IDs whose ID tokens the kube-apiserver accepts (must match staticClients in flux/infrastructure/security/dex)."
  type        = list(string)
  default     = ["kubernetes", "headlamp"]
}

variable "k3s_exec_server_args" {
  description = "Extra arguments passed to k3s server. OIDC uses oidc_issuer_url instead."
  type        = string
  default     = ""
}

# ─── Image Registry ────────────────────────────────────────────────────────────

variable "uptrace_dsn" {
  description = "Uptrace Cloud DSN for OpenTelemetry. Leave empty to skip. Sign up at https://uptrace.dev"
  type        = string
  default     = ""
  sensitive   = true
}

variable "image_registry" {
  description = "Container image registry prefix (e.g., ghcr.io/safeops-course). Change this if you fork the repos."
  type        = string
  default     = "ghcr.io/safeops-course"
}

variable "git_owner" {
  description = "GitHub org or user that owns the repos (e.g., safeops-course). Used by image automation."
  type        = string
  default     = "safeops-course"
}
