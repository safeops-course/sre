# Inputs of the kind module. Every variable has a default, so terraform apply works without
# any; override one with TF_VAR_<name> (export TF_VAR_flux_git_repository_url=...) or a
# terraform.tfvars file (git-ignored). sensitive = true hides a value in plan and apply output;
# ephemeral = true keeps it out of the saved plan and the state as well. A validation block
# stops the plan with a clear message when a combination makes no sense.
# https://developer.hashicorp.com/terraform/language/values/variables

# ─── Flux: what the cluster follows ─────────────────────────────────────────

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
  description = "Path within the Git repository to reconcile. ./flux/bootstrap/profiles/local is the kind profile (no cloud dependencies); ./flux/bootstrap/profiles/hetzner is the full platform used on Hetzner."
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
  # renovate: datasource=github-releases depName=controlplaneio-fluxcd/flux-operator
  default = "0.61.0"
}

variable "flux_version" {
  description = "Flux version the FluxInstance installs. Pinned, so a rebuild gets the same Flux."
  type        = string
  # renovate: datasource=github-releases depName=fluxcd/flux2
  default = "2.9.6"
}

# ─── Credentials (all optional for the public course repository) ────────────

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
  description = "Bump after rotating sops_age_key: the key is write-only, so Terraform re-sends it only when this number changes. Not needed for the local profile key file - a new age.agekey changes the revision by itself (see main.tf)."
  type        = number
  default     = 1
}

# ─── Backups: only for local_profile = false (MinIO is used otherwise) ────────

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

# ─── Platform settings ───────────────────────────────────────────────────────

variable "uptrace_dsn" {
  description = "Uptrace Cloud DSN for OpenTelemetry. Leave empty to skip. Sign up at https://uptrace.dev"
  type        = string
  default     = ""
  sensitive   = true
}

variable "guardian_llm_provider" {
  description = "LLM provider of the Guardian (k8s-ai-monitor, Chapter 14) on kind: gemini (cheapest), anthropic or openai."
  type        = string
  default     = "gemini"

  validation {
    condition     = contains(["gemini", "anthropic", "openai"], var.guardian_llm_provider)
    error_message = "guardian_llm_provider must be gemini, anthropic or openai."
  }
}

variable "guardian_llm_api_key" {
  description = "API key for guardian_llm_provider - your own. Empty: the Guardian still detects and tracks incidents, without the LLM analysis."
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

  # *.agekey is git-ignored; any other name inside the repository could be committed.
  # Only checked for the local profile - without it the file is never written or read.
  validation {
    condition     = !var.local_profile || endswith(var.age_key_file, ".agekey")
    error_message = "age_key_file must end in .agekey when local_profile = true - that suffix is git-ignored, so the private key cannot be committed by accident."
  }
}

# ─── Pinned versions: a rebuild gets the same cluster ────────────────────────

# The platform's Kubernetes version: Hetzner pins the same (k3s_version in hcloud_cluster), a managed
# cloud runs its provider's patch of this minor (scripts/cluster-conformance.sh, C1). Move every
# cluster together. 1.37 waits for kind: it drops kubeadm's v1beta3 config, kind writes v1beta4 from
# v0.32 on, and the tehcyx/kind provider (0.11.0, the newest) embeds kind v0.31 - a 1.37 node fails at
# "kubeadm init" (seen 2026-10-11).
variable "kind_node_image" {
  description = "kindest/node image, pinned by digest. Kubernetes v1.36.4 - the same as k3s on Hetzner (see above)."
  type        = string
  # renovate: datasource=docker depName=kindest/node
  default = "kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
}

variable "cilium_version" {
  description = "Cilium Helm chart version - the CNI. Keep it equal to kube-hetzner's cilium_version (hcloud_cluster), so kind proves what Hetzner runs."
  type        = string
  # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io/
  default = "1.20.3"
}

variable "metrics_server_chart_version" {
  description = "metrics-server Helm chart version."
  type        = string
  # renovate: datasource=helm depName=metrics-server registryUrl=https://kubernetes-sigs.github.io/metrics-server/
  default = "3.14.0"
}
