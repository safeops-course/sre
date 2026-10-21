# Inputs of the EKS cluster. Production-shaped defaults; the course's ephemeral choices are values in
# terraform.tfvars, not baked into the module. Values that identify a person or an account have no default
# and are not in terraform.tfvars (the repository is public): TF_VAR_* from .env.aws.

variable "region" {
  description = "The region of the cluster - the foundation's region (its account defaults are regional)."
  type        = string
}

variable "account_id" {
  description = "The AWS account of the platform (12 digits). The provider refuses every other account. Set TF_VAR_account_id."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12-digit AWS account id (aws sts get-caller-identity --query Account)."
  }
}

variable "aws_profile" {
  description = "The AWS CLI profile Terraform and kubectl sign in with (a profile of `aws login`). Set TF_VAR_aws_profile."
  type        = string
}

variable "expected_principal_arn" {
  description = "The identity that may run this module (arn:aws:iam::ACCOUNT:user/NAME); it becomes the cluster's admin. Any other identity fails the plan. Set TF_VAR_expected_principal_arn."
  type        = string
}

variable "cluster_name" {
  description = "Name of the cluster and its VPC - the foundation's cluster_name (its IAM roles start with it)."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the control plane and the node groups (e.g. 1.36) - the platform's minor, as on kind and Hetzner."
  type        = string
}

variable "availability_zones" {
  description = "The two zones of the VPC's subnets: EKS needs two for its API server, a node group spreads over them. Named, not looked up - a lookup changes its answer when AWS adds a zone."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "availability_zones must name exactly two zones of var.region (e.g. eu-central-1a and eu-central-1b)."
  }
}

variable "vpc_cidr" {
  description = "The VPC's IPv4 range (a /16): a /19 per zone for nodes and pods, a /24 per zone for the load balancer and NAT. Must not overlap the other clusters' ranges."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a /16 (e.g. 10.112.0.0/16): main.tf cuts the subnets out of it."
  }
}

variable "single_nat_gateway" {
  description = "One NAT gateway for both zones (cheaper) instead of one per zone. One gateway is a single point of failure: when its zone goes down, the nodes of the other zone lose the internet too."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "Who may reach the API server's public endpoint. IAM decides who gets in; this list narrows from where (callers with fixed addresses). GitHub-hosted runners have changing addresses."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Two groups by role. spot: Spot instances are 60-90 % cheaper, but AWS may reclaim one with two
# minutes' notice - fine for a test cluster that is destroyed anyway, not a recommendation: a cluster
# that matters runs both groups on-demand (spot = false). Several instance types of the same size give
# Spot more pools to choose from.
variable "platform_pool" {
  description = "Node group for the platform's own components: Flux, Kyverno, the database operator, monitoring."
  type = object({
    instance_types = list(string)
    node_count     = number
    disk_size_gb   = number
    spot           = bool
  })
}

variable "apps_pool" {
  description = "Node group for the applications."
  type = object({
    instance_types = list(string)
    node_count     = number
    disk_size_gb   = number
    spot           = bool
  })
}

variable "control_plane_log_types" {
  description = <<-EOT
    Control-plane logs EKS sends to CloudWatch Logs: api, audit (who did what - the only record of it on
    EKS), authenticator (who signed in as whom), controllerManager, scheduler. Billed per GiB ingested and
    stored. [] turns them off - and creates no log group.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator"]

  validation {
    condition     = alltrue([for t in var.control_plane_log_types : contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)])
    error_message = "control_plane_log_types: only api, audit, authenticator, controllerManager and scheduler."
  }
}

variable "flow_logs" {
  description = <<-EOT
    VPC Flow Logs to CloudWatch Logs: every accepted and rejected connection of the VPC (source,
    destination, port, bytes) - what answers "who talked to what" after an incident. Not a record of what
    a NetworkPolicy denied. Billed per GiB ingested and stored. Needs the foundation's
    <cluster_name>-vpc-flow-logs role.
  EOT
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "How long CloudWatch Logs keeps the control-plane logs and the flow logs."
  type        = number
  default     = 90
}

variable "aws_lbc_chart_version" {
  description = "AWS Load Balancer Controller Helm chart. When it moves, check its iam_policy.json against the foundation's aws_lbc_role (aws_foundation/main.tf)."
  type        = string
  # renovate: datasource=helm registryUrl=https://aws.github.io/eks-charts depName=aws-load-balancer-controller
  default = "3.6.0"
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
  description = "The Flux profile this cluster reconciles (./flux/bootstrap/profiles/eks)."
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
