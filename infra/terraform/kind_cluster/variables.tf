variable "flux_git_repository_url" {
  description = "Git repository URL to sync with Flux. Defaults to the SafeOps course repo; point it at your fork once you start committing (GitOps chapter onward). Set to \"\" to skip GitOps bootstrap."
  type        = string
  default     = "https://github.com/safeops-course/sre.git"
}

variable "flux_git_repository_branch" {
  description = "Git branch Flux should track."
  type        = string
  default     = "main"
}

variable "flux_kustomization_path" {
  description = "Path within the Git repository to reconcile. ./flux/bootstrap/profiles/local is the kind profile (no cloud dependencies); ./flux/bootstrap/flux-system is the full platform used on Hetzner."
  type        = string
  default     = "./flux/bootstrap/profiles/local"
}

variable "flux_sync_interval" {
  description = "Interval at which Flux reconciles sources and kustomizations."
  type        = string
  default     = "1m"
}

variable "flux_kustomization_name" {
  description = "Name for the primary Flux Kustomization resource."
  type        = string
  default     = "cluster-sync"
}

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

variable "ghcr_token" {
  description = "GitHub Personal Access Token for pulling images from GitHub Container Registry (GHCR)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ghcr_username" {
  description = "GitHub username for authenticating to GHCR (used for pull secrets and Helm OCI auth)."
  type        = string
  default     = ""
}

variable "enable_ghcr" {
  description = "Create GHCR imagePullSecrets. Only meaningful together with ghcr_token; with an empty token no secret is created and public images are pulled anonymously."
  type        = bool
  default     = true
}

variable "flux_git_token" {
  description = "GitHub Personal Access Token. Needed for ImageUpdateAutomation git push (Contents:Write) on the platform profile, or to let Flux read a private fork; not needed for the public course repository."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sops_age_key" {
  description = "age private key (AGE-SECRET-KEY-...) for SOPS decryption in Flux. Ephemeral: never stored in the plan or the state. Empty = the key generated for the local profile, which is read from a file and therefore IS in the state."
  type        = string
  default     = ""
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = var.sops_age_key != "" || var.local_profile
    error_message = "sops_age_key is required when local_profile = false: only the local profile generates its own age key."
  }
}

variable "sops_age_key_revision" {
  description = "Bump after rotating sops_age_key: the key is write-only, so Terraform re-sends it only when this number changes."
  type        = number
  default     = 1
}

variable "backup_s3_access_key_id" {
  description = "S3 access key for CNPG backups (Hetzner Object Storage, BACKUP_S3). Only for local_profile = false."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_s3_secret_access_key" {
  description = "S3 secret key for CNPG backups (Hetzner Object Storage, BACKUP_S3). Only for local_profile = false."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_s3_bucket" {
  description = "Bucket for CNPG backups, for example safeops-sre-backups."
  type        = string
  default     = ""
}

variable "backup_s3_endpoint" {
  description = "S3 endpoint for CNPG backups, for example https://nbg1.your-objectstorage.com."
  type        = string
  default     = ""
}

variable "backup_s3_region" {
  description = "S3 region for CNPG backups, for example nbg1."
  type        = string
  default     = ""
}

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

variable "local_profile" {
  description = "Create the runtime secrets the local Flux profile expects (JWT, Postgres owner, MinIO credentials, sops-age from a generated age key). Set to false when reconciling the full platform profile."
  type        = bool
  default     = true
}

variable "age_key_file" {
  description = "Path to the age private key used for SOPS (generated with age-keygen if missing when local_profile is true). Never committed."
  type        = string
  default     = "../../../age.agekey"
}

variable "kind_node_image" {
  description = "kindest/node image, pinned by digest. Kubernetes v1.36.4, the same minor as k3s on the Hetzner track."
  type        = string
  default     = "kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
}

variable "traefik_chart_version" {
  description = "Traefik Helm chart version."
  type        = string
  default     = "41.6.0"
}

variable "metrics_server_chart_version" {
  description = "metrics-server Helm chart version."
  type        = string
  default     = "3.14.0"
}
