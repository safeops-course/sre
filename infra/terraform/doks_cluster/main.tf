# The DOKS cluster for a test cycle (docs/digitalocean.md): created, tested, destroyed. No foundation module:
# what DigitalOcean keeps per account (two-factor sign-in, the spend alert, the token) has no API to manage it.
#   identity      the plan fails unless the token belongs to var.expected_account_uuid
#   network       a VPC of its own; VPC-native pods and Services (routable in the VPC, Cilium)
#   cluster       DOKS, the newest release of var.kubernetes_version, HA and automatic patch upgrades by
#                 default; the default pool "platform" and the pool "apps"
#   add-on        metrics-server (Helm) - kubectl top and the HPA; DOKS has none
#   kubeconfig    kubeconfig.yaml with doctl as the exec plugin - no credentials in the file
# IPv4 only: DOKS gives nodes, pods and Services no IPv6 - only its load balancers (docs/providers.md, the
# written exception, as on EKS). Traefik's load balancer is dual-stack (flux/bootstrap/profiles/doks).

# ─── Identity ─────────────────────────────────────────────────────────────────
# The account the token belongs to. A token of another account or team would build everything there.
data "digitalocean_account" "me" {
  lifecycle {
    postcondition {
      condition     = self.uuid == var.expected_account_uuid
      error_message = "The DigitalOcean token belongs to account ${self.uuid} (${self.email}), expected ${var.expected_account_uuid} - check DIGITALOCEAN_CONFIG in .env.doks."
    }
  }
}

# The newest DOKS release of the platform's minor (1.36 -> 1.36.5-do.1): DigitalOcean picks the patch, as
# AKS and EKS do. Only the cluster's creation reads it (ignore_changes below). A minor DOKS does not offer
# (not yet, or no longer) fails here, not as an unclear API error at create.
data "digitalocean_kubernetes_versions" "minor" {
  version_prefix = "${var.kubernetes_version}."

  lifecycle {
    postcondition {
      condition     = self.latest_version != null && self.latest_version != ""
      error_message = "DOKS offers no release of kubernetes_version ${var.kubernetes_version} (doctl kubernetes options versions)."
    }
  }
}

# ─── Network ──────────────────────────────────────────────────────────────────
# The region's default VPC. DigitalOcean makes the first VPC of a region its default, and a default VPC
# cannot be deleted (2026-10-23: the first cycle in ams3 made sre-doks the default, and its destroy was
# refused - "Can not delete default VPCs"). So the cycle's VPC must never be the first: the region needs a
# default VPC of the team's own before it (docs/digitalocean.md, step 1). The read fails the plan when the
# region has none.
data "digitalocean_vpc" "region_default" {
  region = var.region

  depends_on = [data.digitalocean_account.me]
}

# A VPC of its own, deleted with the cycle. Its range, the pods' and the Services' must not overlap one
# another or any other VPC of the team - DigitalOcean refuses the cluster otherwise.
resource "digitalocean_vpc" "this" {
  name     = "${var.cluster_name}-doks"
  region   = var.region
  ip_range = var.vpc_cidr

  lifecycle {
    precondition {
      condition     = data.digitalocean_vpc.region_default.name != "${var.cluster_name}-doks"
      error_message = "${var.cluster_name}-doks is the default VPC of ${var.region}, so it cannot be deleted. Make another VPC of the region its default first (docs/digitalocean.md, troubleshooting)."
    }
  }
}

# ─── Cluster ──────────────────────────────────────────────────────────────────
resource "digitalocean_kubernetes_cluster" "this" {
  name    = var.cluster_name
  region  = var.region
  version = data.digitalocean_kubernetes_versions.minor.latest_version

  # VPC-native: the ranges make it so (set at creation, cannot change).
  vpc_uuid       = digitalocean_vpc.this.id
  cluster_subnet = var.cluster_subnet
  service_subnet = var.service_subnet

  # Always set, never DigitalOcean's default (on from 1.36, $40 a month, cannot be turned off).
  ha = var.ha

  auto_upgrade  = var.auto_upgrade
  surge_upgrade = true # a new node joins before an old one drains
  maintenance_policy {
    day        = var.maintenance_policy.day
    start_time = var.maintenance_policy.start_time
  }

  # The API's firewall, only with addresses to allow: an empty list would shut everyone out but the nodes.
  dynamic "control_plane_firewall" {
    for_each = length(var.control_plane_allowed_addresses) > 0 ? [1] : []
    content {
      enabled           = true
      allowed_addresses = var.control_plane_allowed_addresses
    }
  }

  destroy_all_associated_resources = var.destroy_all_associated_resources

  # The version is chosen at creation only. Read again on every plan, a newly published patch would upgrade
  # the cluster at the next apply of anything - mid-cycle, or outside the maintenance window that
  # auto_upgrade keeps to. A minor upgrade is a deliberate step (doctl kubernetes cluster upgrade, one minor
  # at a time); until it is done, the postcondition fails every plan loudly instead of drifting silently.
  lifecycle {
    ignore_changes = [version]
    postcondition {
      condition     = startswith(self.version, "${var.kubernetes_version}.")
      error_message = "The cluster runs ${self.version}, kubernetes_version is ${var.kubernetes_version}: upgrade it with doctl kubernetes cluster upgrade (one minor at a time), or set kubernetes_version back."
    }
  }

  # The default pool. It cannot be removed while the cluster exists; the platform runs here.
  node_pool {
    name       = "platform"
    size       = var.platform_pool.size
    node_count = var.platform_pool.node_count
  }
}

resource "digitalocean_kubernetes_node_pool" "apps" {
  cluster_id = digitalocean_kubernetes_cluster.this.id
  name       = "apps"
  size       = var.apps_pool.size
  node_count = var.apps_pool.node_count
}

# ─── metrics-server ───────────────────────────────────────────────────────────
# CPU and memory metrics for kubectl top and the HPA (Chapter 09) - GKE, AKS and k3s have it built in, EKS
# as an add-on, kind and DOKS from this chart. The kubelets' certificates are signed by the cluster's CA,
# so no --kubelet-insecure-tls here (kind needs it).
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = var.metrics_server_chart_version

  depends_on = [digitalocean_kubernetes_node_pool.apps]
}

# ─── kubeconfig ───────────────────────────────────────────────────────────────
# The endpoint and doctl as the exec plugin (versions.tf local.doks_exec): kubectl asks it for a short-lived
# token with the token in DIGITALOCEAN_CONFIG. The file holds no credentials. The context name is fixed, so
# tools can name it.
resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig.yaml"
  file_permission = "0600"
  content = yamlencode({
    apiVersion        = "v1"
    kind              = "Config"
    "current-context" = "doks-${var.cluster_name}-control-plane"
    clusters = [{
      name = "doks-${var.cluster_name}"
      cluster = {
        server                       = digitalocean_kubernetes_cluster.this.endpoint
        "certificate-authority-data" = digitalocean_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
      }
    }]
    users = [{
      name = "doks-${var.cluster_name}"
      user = {
        exec = {
          apiVersion      = local.doks_exec.api_version
          command         = local.doks_exec.command
          args            = local.doks_exec.args
          env             = [for k, v in local.doks_exec.env : { name = k, value = v }]
          installHint     = "doctl (github.com/digitalocean/doctl) and its config with the token, DIGITALOCEAN_CONFIG from .env.doks (docs/digitalocean.md)"
          interactiveMode = "Never"
        }
      }
    }]
    contexts = [{
      name    = "doks-${var.cluster_name}-control-plane"
      context = { cluster = "doks-${var.cluster_name}", user = "doks-${var.cluster_name}" }
    }]
  })
}
