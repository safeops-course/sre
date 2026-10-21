# The course's EKS cluster: created for a test cycle, then destroyed. Not here (public repository):
# account_id, aws_profile, expected_principal_arn - TF_VAR_* from .env.aws.

region       = "eu-central-1" # Frankfurt - the foundation's region
cluster_name = "sre"

availability_zones = ["eu-central-1a", "eu-central-1b"]

# The platform's minor (kind and Hetzner pin 1.36.4). EKS picks the patch.
kubernetes_version = "1.36"

# Clear of GKE's ranges (10.100-10.111) and kind's. Inside Hetzner's 10.0.0.0/8 (kube-hetzner's network): the
# clusters never run at the same time and are never connected - peering them would need other ranges.
vpc_cidr = "10.112.0.0/16"

# One NAT gateway ONLY because this cluster lives for a test cycle: a second one costs as much again,
# for a zone outage the cycle does not test. A cluster that matters keeps the default (false).
single_nat_gateway = true

# spot = true ONLY because this cluster lives for a test cycle and is destroyed after it: a reclaim
# costs a few minutes, Spot saves 60-90 %. Not a recommendation - a cluster that matters sets false.
# x86, 2 vCPU each: 4 vCPU in all, under a new account's 5 vCPU quota for Spot (Service Quotas
# L-34B43A08). Memory, not CPU, is what the platform runs short of: 16 GiB (r-family) for the platform,
# 8 GiB for the apps. No pod is pinned to a group, so CPU requests spread over both nodes: kind measured
# 2026-10-15 the platform 1.33 cores, the apps 0.54, against about 3.9 allocatable. An in-place node
# upgrade starts new nodes first and needs quota above the 4 vCPU - a cycle never upgrades. Four families
# of the same size each: Spot picks whichever pool has capacity.
platform_pool = {
  instance_types = ["r7i.large", "r6i.large", "r6a.large", "r5.large"]
  node_count     = 1
  disk_size_gb   = 50
  spot           = true
}

apps_pool = {
  instance_types = ["m7i.large", "m6i.large", "m6a.large", "m5.large"]
  node_count     = 1
  disk_size_gb   = 50
  spot           = true
}

# Control-plane logs and VPC Flow Logs are off ONLY in these test cycles - a saving while the course is
# built, not a recommendation: a cluster that matters keeps the defaults (api, audit, authenticator; flow
# logs on).
control_plane_log_types = []
flow_logs               = false

# Flux follows the platform repository and reconciles the EKS profile - the same platform as Hetzner and GKE.
flux_git_repository_url = "https://github.com/safeops-course/sre.git"
flux_kustomization_path = "./flux/bootstrap/profiles/eks"
image_registry          = "ghcr.io/safeops-course"
git_owner               = "safeops-course"
# CNPG backups to Cloudflare R2 (the account's S3 endpoint; the bucket and its keys come from .env.aws).
backup_s3_endpoint = "https://99c9887cccb1cb265d748f267999af47.r2.cloudflarestorage.com"
backup_s3_region   = "auto"
