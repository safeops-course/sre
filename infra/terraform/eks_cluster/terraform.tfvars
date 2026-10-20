# The course's EKS cluster: created for a test cycle, then destroyed. Not here (public repository):
# account_id, aws_profile, expected_principal_arn - TF_VAR_* from .env.aws.

region       = "eu-central-1" # Frankfurt - the foundation's region
cluster_name = "sre"

availability_zones = ["eu-central-1a", "eu-central-1b"]

# The platform's minor (kind and Hetzner pin 1.36.4). EKS picks the patch.
kubernetes_version = "1.36"

# Overlaps neither the Hetzner (10.0.0.0/8 from kube-hetzner's 10.0.0.0/16), GKE (10.100-10.111) nor kind ranges.
vpc_cidr = "10.112.0.0/16"

# One NAT gateway ONLY because this cluster lives for a test cycle: a second one costs as much again,
# for a zone outage the cycle does not test. A cluster that matters keeps the default (false).
single_nat_gateway = true

# spot = true ONLY because this cluster lives for a test cycle and is destroyed after it: a reclaim
# costs a few minutes, Spot saves 60-90 %. Not a recommendation - a cluster that matters sets false.
# x86, 4 vCPU / 16 GiB for the platform - GKE measured 2026-10-16: the platform's requests (2.03 cores
# with the provider's own pods) do not fit a 2 vCPU node. Four families of the same size: Spot picks
# whichever pool has capacity.
platform_pool = {
  instance_types = ["m7i.xlarge", "m6i.xlarge", "m6a.xlarge", "m5.xlarge"]
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
