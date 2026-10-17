# The course's GKE cluster: created for a test cycle, then destroyed. Not here: expected_principal
# (TF_VAR_expected_principal - a person locally, the deployer service account in CI).

project_id   = "safeops-510221"
region       = "europe-west1"
zone         = "europe-west1-b"
cluster_name = "sre"

# REGULAR runs Kubernetes 1.36 today - the platform's minor (kind and Hetzner pin 1.36.4).
release_channel = "REGULAR"

# Private ranges that overlap neither each other nor the Hetzner (10.0.0.0/8 from kube-hetzner's
# 10.0.0.0/16 network) or kind ranges in use.
nodes_cidr    = "10.100.0.0/20"
pods_cidr     = "10.104.0.0/14"
services_cidr = "10.108.0.0/20"

# spot = true ONLY because this cluster lives for a test cycle and is destroyed after it: a reclaim
# costs a few minutes, Spot saves 60-91 %. Not a recommendation - a cluster that matters sets false.
platform_pool = {
  # 4 vCPU, 16 GB. Measured on GKE 2026-10-16, CPU requests on the platform node: our platform 1.18
  # cores, GKE's per-node DaemonSets 0.5, and GKE's own Deployments the scheduler put there (kube-dns x2,
  # metrics-server, ...) 0.35 - 2.03 cores against the 1.93 an e2-standard-2 allocates: the OTel agent
  # stayed Pending. e2-standard-4 leaves about 1.9 cores to grow. (kind 2026-10-15: the platform 1.33
  # cores and 1.7 GiB, the three app environments 0.54 cores and 1.2 GiB.)
  machine_type = "e2-standard-4"
  node_count   = 1
  disk_size_gb = 50
  spot         = true
}

apps_pool = {
  machine_type   = "e2-standard-2"
  min_node_count = 1
  max_node_count = 3
  disk_size_gb   = 50
  spot           = true
}

# Workload logs go to Uptrace only in these test cycles - a saving while the course is built, not a
# recommendation: a cluster that matters keeps the default (SYSTEM_COMPONENTS and WORKLOADS).
logging_components = ["SYSTEM_COMPONENTS"]

nat_min_ports_per_vm = 64
nat_max_ports_per_vm = 4096

alert_channel_display_name = "Platform alerts (e-mail)"

# Per-cycle cluster: terraform destroy must work. A cluster that matters keeps true.
deletion_protection = false

# Flux follows the platform repository and reconciles the GKE profile - the same platform as Hetzner.
flux_git_repository_url = "https://github.com/safeops-course/sre.git"
flux_kustomization_path = "./flux/bootstrap/profiles/gke"
image_registry          = "ghcr.io/safeops-course"
git_owner               = "safeops-course"
# CNPG backups to Cloudflare R2 (the account's S3 endpoint; the bucket and its keys come from .env.gcp).
backup_s3_endpoint = "https://99c9887cccb1cb265d748f267999af47.r2.cloudflarestorage.com"
backup_s3_region   = "auto"
