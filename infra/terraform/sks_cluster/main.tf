# The SKS cluster (Exoscale) for a test cycle (docs/exoscale.md): created, tested, destroyed. No foundation
# module: what Exoscale keeps per organization (two-factor sign-in, the low-credit alert, the IAM role and its
# API key) is set once by hand - the key this module runs with may not touch IAM.
#   identity        the plan fails unless the key belongs to the expected organization
#   network         a security group of its own for the nodes: what Cilium and the load balancer need
#   cluster         SKS with Cilium, the Exoscale cloud controller (load balancers), CSI driver (volumes) and
#                   metrics-server; the control plane "pro" by default; the node pools "platform" and "apps"
#   kubeconfig      kubeconfig.yaml with exo as the exec plugin - no credentials in the file
# IPv4 only: SKS gives pods and Services no IPv6, and its cloud controller gives the load balancer none
# (docs/providers.md, the written exception, as on EKS and DOKS).

# ─── Identity ─────────────────────────────────────────────────────────────────
# The organization the key belongs to. The key's role may not read IAM (compute only), so the organization is
# told by its default security group: every organization has one, its id is unique, and it cannot be deleted.
# A key of another organization would build everything there.
data "exoscale_security_group" "default" {
  name = "default"

  lifecycle {
    postcondition {
      condition     = self.id == var.expected_default_security_group_id
      error_message = "The Exoscale key belongs to the organization whose default security group is ${self.id}, expected ${var.expected_default_security_group_id} - check EXOSCALE_CONFIG in .env.sks."
    }
  }
}

# ─── Network ──────────────────────────────────────────────────────────────────
# The nodes' security group, deleted with the cycle. Exoscale drops every inbound packet a security group
# does not allow - between the nodes too. What the nodes need, from Exoscale's SKS documentation for Cilium:
# https://community.exoscale.com/product/compute/containers/quick-start/
# Outbound is open (a security group without egress rules allows all of it).
resource "exoscale_security_group" "nodes" {
  name        = "${var.cluster_name}-sks-nodes"
  description = "SKS ${var.cluster_name}: the nodes (Cilium, kubelet, NodePorts for the load balancer)"

  depends_on = [data.exoscale_security_group.default]
}

locals {
  # Between the nodes only (the group itself as the source): Cilium's overlay and health checks, and the
  # kubelet, which the control plane reaches through its tunnel from a node. Plus node-exporter: it listens on
  # the node's own address (host network), so Prometheus reaches the other node's exporter outside the
  # overlay - the one host-network port in flux/ (kube-prometheus-stack).
  node_to_node_rules = {
    cilium_vxlan  = { protocol = "UDP", port = 8472, description = "Cilium VXLAN overlay" }
    cilium_health = { protocol = "TCP", port = 4240, description = "Cilium health checks" }
    kubelet       = { protocol = "TCP", port = 10250, description = "kubelet (logs, exec, metrics-server)" }
    node_exporter = { protocol = "TCP", port = 9100, description = "node-exporter (Prometheus scrapes every node)" }
  }
}

resource "exoscale_security_group_rule" "node_to_node" {
  for_each = local.node_to_node_rules

  security_group_id      = exoscale_security_group.nodes.id
  type                   = "INGRESS"
  protocol               = each.value.protocol
  start_port             = each.value.port
  end_port               = each.value.port
  user_security_group_id = exoscale_security_group.nodes.id
  description            = each.value.description
}

# Cilium's health checks also ping the other nodes (ICMP echo request).
resource "exoscale_security_group_rule" "cilium_icmp" {
  security_group_id      = exoscale_security_group.nodes.id
  type                   = "INGRESS"
  protocol               = "ICMP"
  icmp_type              = 8
  icmp_code              = 0
  user_security_group_id = exoscale_security_group.nodes.id
  description            = "Cilium health checks (ping)"
}

# The load balancer sends the traffic to Traefik's NodePorts on the nodes' public addresses, and checks them
# from there - it has no address of its own to allow, so these ports are open to the internet. Only Traefik's
# two, fixed in flux/bootstrap/profiles/sks (change both): any other NodePort or LoadBalancer Service stays
# closed to the internet instead of open on every node (docs/exoscale.md, what it builds).
locals {
  traefik_node_ports = {
    web       = { port = 30080, description = "Traefik HTTP NodePort for the network load balancer" }
    websecure = { port = 30443, description = "Traefik HTTPS NodePort for the network load balancer" }
  }
}

resource "exoscale_security_group_rule" "nodeports" {
  for_each = local.traefik_node_ports

  security_group_id = exoscale_security_group.nodes.id
  type              = "INGRESS"
  protocol          = "TCP"
  start_port        = each.value.port
  end_port          = each.value.port
  cidr              = "0.0.0.0/0"
  description       = each.value.description
}

# ─── Cluster ──────────────────────────────────────────────────────────────────
resource "exoscale_sks_cluster" "this" {
  name    = var.cluster_name
  zone    = var.zone
  version = var.kubernetes_version

  # Always set, never Exoscale's default: "pro" (an SLA, a highly available control plane) or "starter"
  # (free, no SLA). Set at creation: a starter cluster can be upgraded to pro later, never the reverse.
  service_level = var.service_level
  auto_upgrade  = var.auto_upgrade

  cni = "cilium" # Exoscale's default is Calico; Cilium is the platform's CNI everywhere

  # The cloud controller makes the load balancer of a LoadBalancer Service (Traefik) and the CSI driver the
  # volumes (it needs the cloud controller). metrics-server runs in the control plane - kubectl top and the HPA.
  exoscale_ccm   = true
  exoscale_csi   = true
  metrics_server = true

  # The version is chosen at creation only. With auto_upgrade Exoscale upgrades the control plane to new
  # patches by itself, and Terraform must not try to set it back. A minor upgrade is a deliberate step
  # (exo compute sks upgrade, one minor at a time); until it is done, the postcondition fails every plan
  # loudly instead of drifting silently.
  lifecycle {
    ignore_changes = [version]
    postcondition {
      condition     = join(".", slice(split(".", self.version), 0, 2)) == join(".", slice(split(".", var.kubernetes_version), 0, 2))
      error_message = "The cluster runs ${self.version}, kubernetes_version is ${var.kubernetes_version}: upgrade it with exo compute sks upgrade (one minor at a time), or set kubernetes_version back."
    }
  }
}

# Two pools by role, as on the other clouds. A node pool is an Exoscale instance pool; its instances get the
# nodes' security group, IPv4 only (ipv6 = false: pods and Services have none anyway). After the group's
# rules: a node never starts without them, and on destroy they go only after the pools - and so after the
# pre-destroy hook, which depends on the pools.
resource "exoscale_sks_nodepool" "platform" {
  cluster_id         = exoscale_sks_cluster.this.id
  zone               = var.zone
  name               = "platform"
  instance_prefix    = "${var.cluster_name}-platform"
  instance_type      = var.platform_pool.instance_type
  size               = var.platform_pool.size
  disk_size          = var.platform_pool.disk_size
  security_group_ids = [exoscale_security_group.nodes.id]
  ipv6               = false
  labels             = { pool = "platform" }

  depends_on = [
    exoscale_security_group_rule.node_to_node,
    exoscale_security_group_rule.cilium_icmp,
    exoscale_security_group_rule.nodeports,
  ]
}

resource "exoscale_sks_nodepool" "apps" {
  cluster_id         = exoscale_sks_cluster.this.id
  zone               = var.zone
  name               = "apps"
  instance_prefix    = "${var.cluster_name}-apps"
  instance_type      = var.apps_pool.instance_type
  size               = var.apps_pool.size
  disk_size          = var.apps_pool.disk_size
  security_group_ids = [exoscale_security_group.nodes.id]
  ipv6               = false
  labels             = { pool = "apps" }

  depends_on = [
    exoscale_security_group_rule.node_to_node,
    exoscale_security_group_rule.cilium_icmp,
    exoscale_security_group_rule.nodeports,
  ]
}

# ─── kubeconfig ───────────────────────────────────────────────────────────────
# The endpoint, the control plane's certificate authority and exo as the exec plugin (versions.tf
# local.sks_exec): kubectl asks it for a short-lived client certificate with the key in EXOSCALE_CONFIG. The
# file holds no credentials. The context name is fixed, so tools can name it.
resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig.yaml"
  file_permission = "0600"
  content = yamlencode({
    apiVersion        = "v1"
    kind              = "Config"
    "current-context" = "sks-${var.cluster_name}-control-plane"
    clusters = [{
      name = "sks-${var.cluster_name}"
      cluster = {
        server                       = local.api_server_url
        "certificate-authority-data" = base64encode(exoscale_sks_cluster.this.control_plane_ca)
      }
    }]
    users = [{
      name = "sks-${var.cluster_name}"
      user = {
        exec = {
          apiVersion      = local.sks_exec.api_version
          command         = local.sks_exec.command
          args            = local.sks_exec.args
          env             = [for k, v in local.sks_exec.env : { name = k, value = v }]
          installHint     = "exo (github.com/exoscale/cli) and its config with the API key, EXOSCALE_CONFIG from .env.sks (docs/exoscale.md)"
          interactiveMode = "Never"
        }
      }
    }]
    contexts = [{
      name    = "sks-${var.cluster_name}-control-plane"
      context = { cluster = "sks-${var.cluster_name}", user = "sks-${var.cluster_name}" }
    }]
  })
}
