# The course's SKS cluster: created for a test cycle, then destroyed. Not here (public repository):
# expected_default_security_group_id and the API key - TF_VAR_* and EXOSCALE_CONFIG from .env.sks.

cluster_name = "sre"
# Sofia: in the EU; SKS 1.36 and Block Storage are offered there (exo compute sks versions, 2026-10-23).
zone = "bg-sof-1"

# The platform's minor (kind and Hetzner pin 1.36.4); the newest 1.36 release SKS offers
# (exo compute sks versions, 2026-10-23). make access fails when SKS no longer offers it.
kubernetes_version = "1.36.5"

# A free control plane without an SLA and no automatic upgrades ONLY because this cluster lives for a test
# cycle: no SLA is needed for an hour, and an upgrade must not start in the middle of a check. A cluster
# that matters keeps the defaults (pro; patch upgrades by Exoscale).
service_level = "starter"
auto_upgrade  = false

# 4 vCPU / 8 GiB each (EUR 0.0933 an hour): memory, not CPU, is what the platform needs - on AKS (2 vCPU /
# 8 GiB) memory was 75-84 % used, CPU requests 1.1-1.5 of 1.9 cores (2026-10-21). 50 GiB is Exoscale's
# default disk.
platform_pool = {
  instance_type = "standard.large"
  size          = 1
  disk_size     = 50
}

apps_pool = {
  instance_type = "standard.large"
  size          = 1
  disk_size     = 50
}

# Flux follows the platform repository and reconciles the SKS profile - the same platform as everywhere.
flux_git_repository_url = "https://github.com/safeops-course/sre.git"
flux_kustomization_path = "./flux/bootstrap/profiles/sks"
image_registry          = "ghcr.io/safeops-course"
git_owner               = "safeops-course"
# CNPG backups to Cloudflare R2 (the account's S3 endpoint; the bucket and its keys come from .env.sks).
backup_s3_endpoint = "https://99c9887cccb1cb265d748f267999af47.r2.cloudflarestorage.com"
backup_s3_region   = "auto"
