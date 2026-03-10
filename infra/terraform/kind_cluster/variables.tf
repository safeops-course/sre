variable "flux_git_repository_url" {
  description = "Git repository URL to sync with Flux. Leave empty to skip GitOps bootstrap."
  type        = string
  default     = ""
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
  description = "Version of the Flux Operator Helm chart to install."
  type        = string
  default     = "0.30.0"
}

variable "flux_version" {
  description = "Version of Flux to install (e.g., '2.x', '2.4.x', 'v2.4.0'). Using '2.x' will install the latest 2.x version."
  type        = string
  default     = "2.x"
}

variable "github_app_id" {
  description = "GitHub App ID for Flux authentication. Leave empty to skip GitHub App secret creation."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_app_installation_id" {
  description = "GitHub App Installation ID for Flux authentication."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_app_private_key_file" {
  description = "Path to GitHub App private key PEM file."
  type        = string
  default     = ""
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
  description = "Whether to create GHCR imagePullSecrets (must be true when ghcr_token is set)."
  type        = bool
  default     = true
}

variable "flux_git_token" {
  description = "GitHub Personal Access Token for ImageUpdateAutomation git push operations (requires Contents:Write scope)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sops_age_key" {
  description = "Age private key contents for SOPS decryption in Flux. Leave empty to skip sops-age secret creation."
  type        = string
  default     = ""
  sensitive   = true
}

variable "r2_access_key_id" {
  description = "Cloudflare R2 access key ID for CNPG backup storage."
  type        = string
  default     = ""
  sensitive   = true
}

variable "r2_secret_access_key" {
  description = "Cloudflare R2 secret access key for CNPG backup storage."
  type        = string
  default     = ""
  sensitive   = true
}

variable "r2_bucket" {
  description = "R2 bucket name for CNPG backups."
  type        = string
  default     = "sre"
}

variable "r2_endpoint" {
  description = "R2 S3-compatible endpoint URL."
  type        = string
  default     = "https://99c9887cccb1cb265d748f267999af47.r2.cloudflarestorage.com"
}

variable "r2_region" {
  description = "R2 region for backup storage."
  type        = string
  default     = "auto"
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
