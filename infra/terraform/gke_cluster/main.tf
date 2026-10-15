# A GKE Standard cluster built the way Google's hardening guide describes, for the platform in this
# repository. It needs the foundation (infra/terraform/gcp_foundation): the APIs, the gke-nodes
# service account and the alert e-mail channel.
#
#   network      its own VPC (never "default"), one subnet with named Pod and Service ranges,
#                Private Google Access
#   egress       private nodes (no public IP); Cloud NAT is their only way out, with two alerts
#   control      the API server only through its DNS endpoint (IAM decides who gets in), no IP endpoint
#   cluster      Dataplane V2 (NetworkPolicy, egress too), Workload Identity, shielded nodes with
#                secure boot, no kubelet read-only port, no client certificates, no legacy ABAC
#   node pools   "platform" and "apps", by role, both as gke-nodes; Spot only where tfvars says so
#   webhooks     reach the cluster through Konnectivity - no firewall rule (see below)
#   kubeconfig   kubeconfig.yaml: the DNS endpoint + gke-gcloud-auth-plugin, no credentials inside
# https://docs.cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster

# Fail the plan when Terraform runs as anyone else (see gcp_foundation/main.tf).
data "google_client_openid_userinfo" "me" {
  lifecycle {
    postcondition {
      condition     = self.email == var.expected_principal
      error_message = "Terraform authenticates as ${coalesce(self.email, "(no e-mail in the token)")}, expected ${var.expected_principal}. Point GOOGLE_APPLICATION_CREDENTIALS at that identity's ADC file or fix TF_VAR_expected_principal."
    }
  }
}

# Made by the foundation, looked up by name.
data "google_service_account" "gke_nodes" {
  account_id = "gke-nodes"
}

data "google_monitoring_notification_channel" "alerts" {
  display_name = var.alert_channel_display_name
}

locals {
  # The network tag on every node: firewall rules for the nodes target it, never "all instances".
  node_tag = "${var.cluster_name}-gke-node"
}

# ─── Network ──────────────────────────────────────────────────────────────────
resource "google_compute_network" "this" {
  name                    = var.cluster_name
  auto_create_subnetworks = false # custom mode: only the subnet below, no subnet in every region
  routing_mode            = "REGIONAL"

  depends_on = [data.google_client_openid_userinfo.me]
}

# VPC-native: Pods and Services get IPs from named secondary ranges, so routes, firewall rules and
# NetworkPolicies see real Pod IPs. Private Google Access: nodes without a public IP still reach
# Google APIs (image pulls from Artifact Registry, logging, monitoring) without going through NAT.
resource "google_compute_subnetwork" "nodes" {
  name                     = "${var.cluster_name}-nodes"
  network                  = google_compute_network.this.id
  region                   = var.region
  ip_cidr_range            = var.nodes_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# ─── Egress: Cloud NAT ────────────────────────────────────────────────────────
# Private nodes have no public IP; everything they fetch from the internet (images from GHCR, Helm
# charts, Let's Encrypt, Cloudflare, GitHub for Flux) leaves through this gateway. Paid per node-hour
# and per GB - accepted, so that no node can be reached from the internet.
resource "google_compute_router" "nat" {
  name    = "${var.cluster_name}-nat"
  network = google_compute_network.this.id
  region  = var.region
}

# Dynamic port allocation: a node starts with nat_min_ports_per_vm ports and grows up to the max on
# demand, instead of a fixed large block per node. It cannot be combined with endpoint-independent
# mapping. Logs: errors only - every translation would cost more than it tells.
# https://docs.cloud.google.com/nat/docs/ports-and-addresses
resource "google_compute_router_nat" "nat" {
  name                                = "${var.cluster_name}-nat"
  router                              = google_compute_router.nat.name
  region                              = var.region
  nat_ip_allocate_option              = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat  = "LIST_OF_SUBNETWORKS"
  enable_dynamic_port_allocation      = true
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = var.nat_min_ports_per_vm
  max_ports_per_vm                    = var.nat_max_ports_per_vm

  subnetwork {
    name                    = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Two alerts on the gateway, to the foundation's e-mail channel: a node could not get a NAT port, and
# packets were dropped because the gateway ran out of addresses or ports. Either means connections
# from the cluster to the internet are failing right now.
# https://docs.cloud.google.com/nat/docs/monitoring
resource "google_monitoring_alert_policy" "nat_allocation_failed" {
  display_name = "${var.cluster_name}: Cloud NAT port allocation failed"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "nat_allocation_failed is true"
    condition_threshold {
      filter          = "resource.type = \"nat_gateway\" AND resource.labels.gateway_name = \"${google_compute_router_nat.nat.name}\" AND metric.type = \"router.googleapis.com/nat/nat_allocation_failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_COUNT_TRUE"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A node of ${var.cluster_name} could not get a Cloud NAT port: its new connections to the internet fail. Check `max_ports_per_vm` (terraform.tfvars) against the NAT logs (errors only) in Cloud Logging."
  }

  notification_channels = [data.google_monitoring_notification_channel.alerts.name]
}

resource "google_monitoring_alert_policy" "nat_dropped_out_of_resources" {
  display_name = "${var.cluster_name}: Cloud NAT dropped packets (out of resources)"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "dropped_sent_packets_count, reason OUT_OF_RESOURCES"
    condition_threshold {
      filter          = "resource.type = \"nat_gateway\" AND resource.labels.gateway_name = \"${google_compute_router_nat.nat.name}\" AND metric.type = \"router.googleapis.com/nat/dropped_sent_packets_count\" AND metric.labels.reason = \"OUT_OF_RESOURCES\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Cloud NAT of ${var.cluster_name} dropped outgoing packets: no NAT address or port was free. Raise `max_ports_per_vm` or add NAT addresses."
  }

  notification_channels = [data.google_monitoring_notification_channel.alerts.name]
}

# ─── Cluster ──────────────────────────────────────────────────────────────────
resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone

  network         = google_compute_network.this.id
  subnetwork      = google_compute_subnetwork.nodes.id
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # The node pools below replace the default one (which would run as the Compute default account).
  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = var.release_channel
  }

  # Dataplane V2 (eBPF): enforces NetworkPolicy, egress included. The provider still defaults to the
  # legacy dataplane, so it is set here; no Calico network_policy block next to it.
  datapath_provider = "ADVANCED_DATAPATH"

  # Nodes have private IPs only; their egress is Cloud NAT.
  private_cluster_config {
    enable_private_nodes = true
  }

  # The API server through its DNS name only, from anywhere that reaches Google APIs - GitHub runners
  # with changing IPs and a laptop alike. IAM decides who gets in; there is no IP endpoint and no IP
  # allow-list to keep up to date.
  # https://docs.cloud.google.com/kubernetes-engine/docs/concepts/network-isolation
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
    ip_endpoints_config {
      enabled = false
    }
  }

  # Pods get Google credentials through Kubernetes service accounts, never from the node.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Legacy ways in, all closed.
  enable_legacy_abac = false
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }
  anonymous_authentication_config {
    mode = "LIMITED" # only the health endpoints answer an anonymous request
  }

  node_pool_defaults {
    node_config_defaults {
      insecure_kubelet_readonly_port_enabled = "FALSE"
    }
  }

  # Cloud Logging gets system and workload logs. Cloud Monitoring gets system metrics only: the
  # platform runs its own Prometheus, so Google's managed Prometheus would collect everything twice.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }

  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_BASIC"
  }

  cost_management_config {
    enabled = true
  }

  deletion_protection = var.deletion_protection
}

# Node settings both pools share.
locals {
  node_config = {
    image_type      = "COS_CONTAINERD"
    disk_type       = "pd-balanced"
    service_account = data.google_service_account.gke_nodes.email
    # With its own service account the scope stays wide and IAM does the restricting (Google's advice).
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    tags         = [local.node_tag]
  }
}

resource "google_container_node_pool" "platform" {
  name       = "platform"
  cluster    = google_container_cluster.this.id
  location   = var.zone
  node_count = var.platform_pool.node_count

  node_config {
    machine_type    = var.platform_pool.machine_type
    disk_size_gb    = var.platform_pool.disk_size_gb
    spot            = var.platform_pool.spot
    image_type      = local.node_config.image_type
    disk_type       = local.node_config.disk_type
    service_account = local.node_config.service_account
    oauth_scopes    = local.node_config.oauth_scopes
    tags            = local.node_config.tags
    labels          = { "pool" = "platform" }

    workload_metadata_config {
      mode = "GKE_METADATA" # the GKE metadata server: no node credentials for Pods
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # A new node first, then the old one drains: no capacity gap during an upgrade.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}

resource "google_container_node_pool" "apps" {
  name     = "apps"
  cluster  = google_container_cluster.this.id
  location = var.zone

  autoscaling {
    min_node_count = var.apps_pool.min_node_count
    max_node_count = var.apps_pool.max_node_count
  }

  node_config {
    machine_type    = var.apps_pool.machine_type
    disk_size_gb    = var.apps_pool.disk_size_gb
    spot            = var.apps_pool.spot # Spot, not "preemptible": no 24-hour limit
    image_type      = local.node_config.image_type
    disk_type       = local.node_config.disk_type
    service_account = local.node_config.service_account
    oauth_scopes    = local.node_config.oauth_scopes
    tags            = local.node_config.tags
    labels          = { "pool" = "apps" }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}

# ─── Admission webhooks ───────────────────────────────────────────────────────
# No firewall rule for webhook ports (Kyverno and CloudNativePG serve on 9443). With the DNS endpoint
# only, GKE runs Konnectivity: the control plane reaches webhooks through a tunnel ending in the
# konnectivity-agent Pods (kube-system) inside the cluster - Pod to Pod, not from a control plane IP
# (there is none to name: no IP endpoint). No NetworkPolicy is needed either: default-deny covers only
# develop, staging, production and minio, and no webhook runs there (Kyverno, cnpg-system and
# cert-manager have none). cluster-conformance C7 proves it on every cycle - it passed on GKE,
# 2026-10-15. A webhook in a default-deny namespace would need a policy admitting konnectivity-agent.

# ─── kubeconfig ───────────────────────────────────────────────────────────────
# The DNS endpoint and the auth plugin: kubectl asks gke-gcloud-auth-plugin for a short-lived token of
# whoever runs it. The file holds no credentials. The context name is fixed, so tools can name it.
resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig.yaml"
  file_permission = "0600"
  content = yamlencode({
    apiVersion        = "v1"
    kind              = "Config"
    "current-context" = "gke-${var.cluster_name}-control-plane"
    clusters = [{
      name    = "gke-${var.cluster_name}"
      cluster = { server = "https://${google_container_cluster.this.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint}" }
    }]
    users = [{
      name = "gke-${var.cluster_name}"
      user = {
        exec = {
          apiVersion         = "client.authentication.k8s.io/v1beta1"
          command            = "gke-gcloud-auth-plugin"
          installHint        = "gcloud components install gke-gcloud-auth-plugin"
          provideClusterInfo = true
        }
      }
    }]
    contexts = [{
      name    = "gke-${var.cluster_name}-control-plane"
      context = { cluster = "gke-${var.cluster_name}", user = "gke-${var.cluster_name}" }
    }]
  })
}
