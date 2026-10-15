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
  # 2 vCPU, 8 GB. Measured on kind 2026-10-15: the platform requests 1.33 cores and 1.7 GiB, the
  # three app environments 0.54 cores and 1.2 GiB; GKE adds about 0.5 core of its own per node.
  machine_type = "e2-standard-2"
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

nat_min_ports_per_vm = 64
nat_max_ports_per_vm = 4096

alert_channel_display_name = "Platform alerts (e-mail)"

# Per-cycle cluster: terraform destroy must work. A cluster that matters keeps true.
deletion_protection = false
