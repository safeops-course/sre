# The course's AKS cluster: created for a test cycle, then destroyed. Not here (public repository):
# subscription_id, tenant_id, expected_principal_object_id - TF_VAR_* from .env.azure.

location     = "swedencentral" # the foundation's location
cluster_name = "sre"

# The platform's minor (kind and Hetzner pin 1.36.4). AKS picks the patch.
kubernetes_version = "1.36"

# Free tier, no automatic upgrades ONLY because this cluster lives for a test cycle: no SLA is needed for
# an hour, and an upgrade must not start in the middle of a check. A cluster that matters keeps the
# defaults (Standard tier; patch upgrades and weekly node images inside the maintenance window).
sku_tier                  = "Free"
automatic_upgrade_channel = "none"
node_os_upgrade_channel   = "None"

# Pods and Services: clear of GKE's ranges (10.100-10.111), EKS's VPC (10.112.0.0/16) and AKS's own node
# network (10.224.0.0/12). The IPv6 ranges are AKS's documented defaults (unique local addresses).
pod_cidrs     = ["10.120.0.0/16", "fd12:3456:789a::/64"]
service_cidrs = ["10.121.0.0/16", "fd12:3456:789a:1::/108"]

# x86, 2 vCPU / 8 GiB each, on-demand: 4 vCPU in all, under a new subscription's 10 vCPU regional quota
# with room for one surge node. D2as_v7 because a new subscription gets no quota for the v5 families
# (DASv5: 0, 2026-10-21). On kind (2026-10-21) the platform requests 0.56 cores and 3.3Gi, the apps 0.54
# cores and 1.2Gi; AKS adds its own pods (CoreDNS, Cilium, the CSI drivers, metrics-server).
platform_pool = {
  vm_size      = "Standard_D2as_v7"
  node_count   = 1
  disk_size_gb = 64
}

apps_pool = {
  vm_size      = "Standard_D2as_v7"
  node_count   = 1
  disk_size_gb = 64
}

# Control-plane logs are off ONLY in these test cycles - a saving while the course is built, not a
# recommendation: a cluster that matters keeps the default (kube-apiserver, kube-audit-admin, guard).
control_plane_log_categories = []

# Flux follows the platform repository and reconciles the AKS profile - the same platform as everywhere.
flux_git_repository_url = "https://github.com/safeops-course/sre.git"
flux_kustomization_path = "./flux/bootstrap/profiles/aks"
image_registry          = "ghcr.io/safeops-course"
git_owner               = "safeops-course"
# CNPG backups to Cloudflare R2 (the account's S3 endpoint; the bucket and its keys come from .env.azure).
backup_s3_endpoint = "https://99c9887cccb1cb265d748f267999af47.r2.cloudflarestorage.com"
backup_s3_region   = "auto"
