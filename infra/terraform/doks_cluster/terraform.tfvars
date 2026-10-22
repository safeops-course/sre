# The course's DOKS cluster: created for a test cycle, then destroyed. Not here (public repository):
# expected_account_uuid and the token - TF_VAR_* and DIGITALOCEAN_CONFIG from .env.doks.

cluster_name = "sre"
region       = "fra1" # Frankfurt: in the EU, closest to the course's own location

# The platform's minor (kind and Hetzner pin 1.36.4). DOKS picks the patch.
kubernetes_version = "1.36"

# No HA control plane, no automatic upgrades, and the cluster's load balancers and volumes deleted with it
# ONLY because this cluster lives for a test cycle: no SLA is needed for an hour ($40 a month saved), an
# upgrade must not start in the middle of a check, and a cycle's volumes hold nothing to keep. A cluster
# that matters keeps the defaults (HA; patch upgrades in the maintenance window; volumes kept).
ha                               = false
auto_upgrade                     = false
destroy_all_associated_resources = true

# Clear of GKE's ranges (10.100-10.111), EKS's VPC (10.112.0.0/16) and AKS's (10.120-10.121, 10.224.0.0/12),
# and of one another. DigitalOcean refuses a range that overlaps another VPC of the team - its default VPC
# in fra1 included (docs/digitalocean.md, troubleshooting).
vpc_cidr       = "10.130.0.0/20"
cluster_subnet = "10.131.0.0/16"
service_subnet = "10.132.0.0/19"

# Shared 4 vCPU / 8 GiB each ($0.0714 an hour): memory, not CPU, is what the platform needs - on AKS
# (2 vCPU / 8 GiB) memory was 75-84 % used, CPU requests 1.1-1.5 of 1.9 cores (2026-10-21).
platform_pool = {
  size       = "s-4vcpu-8gb"
  node_count = 1
}

apps_pool = {
  size       = "s-4vcpu-8gb"
  node_count = 1
}

# Flux follows the platform repository and reconciles the DOKS profile - the same platform as everywhere.
flux_git_repository_url = "https://github.com/safeops-course/sre.git"
flux_kustomization_path = "./flux/bootstrap/profiles/doks"
image_registry          = "ghcr.io/safeops-course"
git_owner               = "safeops-course"
# CNPG backups to Cloudflare R2 (the account's S3 endpoint; the bucket and its keys come from .env.doks).
backup_s3_endpoint = "https://99c9887cccb1cb265d748f267999af47.r2.cloudflarestorage.com"
backup_s3_region   = "auto"
