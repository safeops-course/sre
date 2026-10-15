# ─── Secrets ──────────────────────────────────────────────────────────────────
# These are set via TF_VAR_* from load-env.sh — no need to put them here.
#   hcloud_token, ssh_public_key (the private key goes through ssh-agent),
#   flux_git_token, ghcr_username, ghcr_token, enable_ghcr, sops_age_key,
#   backup_s3_access_key_id, backup_s3_secret_access_key, backup_s3_bucket,
#   backup_s3_endpoint, backup_s3_region

# ─── Cluster Identity ────────────────────────────────────────────────────────
cluster_name       = "sre"
location           = "hel1"
load_balancer_type = "lb11"

# ─── Server Types ────────────────────────────────────────────────────────────
# One control plane (no workloads on it) and one worker. cpx (AMD) rather than cx: on 2026-10-12 a worker
# create failed in hel1 with "error during placement (resource_unavailable)" for cx33 - cpx is the type
# line with more capacity, and nothing here depends on the CPU vendor.
control_plane_server_type         = "cpx22"
control_plane_count               = 1
allow_scheduling_on_control_plane = false

workers_server_type = "cpx32"
workers_count       = 1

# ─── Autoscaling ─────────────────────────────────────────────────────────────
# When enabled, workers_count is ignored; min/max nodes govern the pool instead.
# autoscaling_enabled   = false
# autoscaling_min_nodes = 0
# autoscaling_max_nodes = 5

# ─── K3s & OS Upgrades ──────────────────────────────────────────────────────
k3s_channel = "stable"
# renovate: datasource=github-releases depName=k3s-io/k3s versioning=regex:^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)\+k3s(?<build>\d+)$
# The same version as kind (kind_cluster/variables.tf): one Kubernetes version for every cluster the
# platform is tested on. A managed cloud runs its provider's patch of the same minor.
k3s_version = "v1.36.4+k3s1"
# Nothing on the nodes moves by itself: k3s changes through k3s_version in a pull request, OS updates
# and reboots through scripts/node-maintenance.sh at a time we choose. With one worker, a reboot kured
# chose would be an outage nobody planned. Monthly is the intended cadence; the Renovate dashboard issue is the reminder.
auto_upgrade_k3s = false
auto_upgrade_os  = false

# ─── Kured (Kubernetes Reboot Daemon) ───────────────────────────────────────
# Off with auto_upgrade_os: nothing installs updates by itself, so nothing needs an automatic reboot.
kured_enabled = false
# kured_reboot_days = "sat,sun"   # default: sat,sun
# kured_start_time  = "02:00"     # default: 02:00
# kured_end_time    = "05:00"     # default: 05:00

# ─── Flux ────────────────────────────────────────────────────────────────────
flux_git_repository_url = "https://github.com/safeops-course/sre.git"
# flux_git_repository_branch: the variable default ("main") - a tfvars value would win over
# TF_VAR_flux_git_repository_branch when a cycle tests a branch.
flux_kustomization_path = "./flux/bootstrap/profiles/hetzner"
# flux_version             = "2.x"
# flux_operator_version    = "0.60.0"

# ─── Image Registry ────────────────────────────────────────────────────────────
# Change these if you fork the repos to your own GitHub account.
# image_registry = "ghcr.io/your-github-username"
# git_owner      = "your-github-username"

# ─── OIDC (Dex) ───────────────────────────────────────────────────────────────
# On by default (oidc_issuer_url = "https://dex.safeops.work"). Set "" to disable.
