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
# Single-node: workloads run on control plane, no separate worker.
control_plane_server_type         = "cx23"
control_plane_count               = 1
allow_scheduling_on_control_plane = false

workers_server_type = "cx33"
workers_count       = 1

# ─── Autoscaling ─────────────────────────────────────────────────────────────
# When enabled, workers_count is ignored; min/max nodes govern the pool instead.
# autoscaling_enabled   = false
# autoscaling_min_nodes = 0
# autoscaling_max_nodes = 5

# ─── K3s & OS Upgrades ──────────────────────────────────────────────────────
k3s_channel = "stable"
k3s_version = "v1.36.4+k3s1" # pinned: the same Kubernetes as the kind cluster
# a pinned version must not move by itself; OS updates stay automatic (kured)
auto_upgrade_k3s = false
auto_upgrade_os  = true

# ─── Kured (Kubernetes Reboot Daemon) ───────────────────────────────────────
# Required for auto_upgrade_os — coordinates node reboots after OS updates.
kured_enabled = true
# kured_reboot_days = "sat,sun"   # default: sat,sun
# kured_start_time  = "02:00"     # default: 02:00
# kured_end_time    = "05:00"     # default: 05:00

# ─── Ingress ─────────────────────────────────────────────────────────────────
ingress_controller = "traefik"
# traefik_redirect_to_https = true
# traefik_autoscaling       = true

# ─── Flux ────────────────────────────────────────────────────────────────────
flux_git_repository_url    = "https://github.com/safeops-course/sre.git"
flux_git_repository_branch = "main"
flux_kustomization_path    = "./flux/bootstrap/flux-system"
# flux_version             = "2.x"
# flux_operator_version    = "0.60.0"

# ─── Image Registry ────────────────────────────────────────────────────────────
# Change these if you fork the repos to your own GitHub account.
# image_registry = "ghcr.io/your-github-username"
# git_owner      = "your-github-username"

# ─── OIDC (Dex) ───────────────────────────────────────────────────────────────
# On by default (oidc_issuer_url = "https://dex.safeops.work"). Set "" to disable.
