# An AKS cluster for the platform in this repository - the same platform as on Hetzner, GKE and EKS. It
# needs the foundation (infra/terraform/azure_foundation): the resource group it is built in, and the
# Kubernetes admin role of the person running it, both made there.
#
#   network      Azure CNI Overlay powered by Cilium: dual-stack (IPv4 + IPv6 for nodes, pods and
#                Services), Cilium enforces NetworkPolicy (egress too); the node network is the one AKS
#                manages in the node resource group - nothing else is connected to it
#   egress       the Standard load balancer's outbound rules, an IPv4 and an IPv6 address - the documented
#                way out for a dual-stack cluster
#   control      the API server's public endpoint; Microsoft Entra ID decides who gets in (Azure RBAC for
#                Kubernetes), no local accounts - so no certificate a leaked kubeconfig could carry
#   upgrades     Kubernetes patches and weekly node images inside a maintenance window (var)
#   node pools   "platform" (the system pool) and "apps" (a user pool), on-demand
#   logs         control-plane logs to a Log Analytics workspace (var)
#   kubeconfig   kubeconfig.yaml: the endpoint + Azure kubelogin, no credentials inside
# https://learn.microsoft.com/azure/aks/best-practices

# Fail the plan when Terraform runs as anyone else (see azure_foundation/main.tf).
data "azurerm_client_config" "me" {
  lifecycle {
    postcondition {
      condition     = self.object_id == var.expected_principal_object_id
      error_message = "Terraform authenticates as object id ${self.object_id}, expected ${var.expected_principal_object_id}. Sign in as that identity (az login, with AZURE_CONFIG_DIR from .env.azure) or fix TF_VAR_expected_principal_object_id."
    }
  }
}

# Made by the foundation, looked up by name: a missing one fails the plan with "not found" - apply the
# foundation first.
data "azurerm_resource_group" "aks" {
  name = "${var.cluster_name}-aks"

  depends_on = [data.azurerm_client_config.me]
}

locals {
  # AKS puts the nodes, their disks, the load balancer and its addresses in a group of its own and deletes
  # it with the cluster. A fixed name instead of AKS's MC_<group>_<cluster>_<location>: leftovers can name it.
  node_resource_group = "${data.azurerm_resource_group.aks.name}-nodes"
  # AKS's maintenance windows are UTC and weekly here; both channels share one.
  maintenance_window = {
    frequency   = "Weekly"
    interval    = 1
    day_of_week = var.maintenance_window.day_of_week
    start_time  = var.maintenance_window.start_time
    duration    = var.maintenance_window.duration_hours
    utc_offset  = "+00:00"
  }
}

# ─── Cluster ──────────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "this" {
  # checkov:skip=CKV_AZURE_6:the API server is public - Microsoft Entra ID decides who gets in, and GitHub-hosted runners have changing addresses (as on EKS)
  # checkov:skip=CKV_AZURE_115:a private cluster needs a network path in (VPN, bastion) that the course does not have
  # checkov:skip=CKV_AZURE_117:disks are encrypted at rest with platform-managed keys; a disk encryption set means a Key Vault and a key of our own per cycle
  # checkov:skip=CKV_AZURE_226:ephemeral OS disks need a size with a local disk; D2as_v7 has none (managed OS disk)
  # checkov:skip=CKV_AZURE_227:host encryption needs the EncryptionAtHost feature registered per subscription; disks are encrypted at rest by the platform
  # checkov:skip=CKV_AZURE_232:the system pool runs the platform's own components too - two nodes in all, no room for a pool of AKS add-ons alone
  # checkov:skip=CKV_AZURE_116:Azure Policy add-on not used - Kyverno is the admission policy engine on every cluster
  # checkov:skip=CKV_AZURE_170:the paid tier (Standard, an uptime SLA) is the default of var.sku_tier; only the test cycles' tfvars choose Free
  # checkov:skip=CKV_AZURE_172:the Key Vault secrets provider is not used - secrets come from SOPS through Flux
  # checkov:skip=CKV_AZURE_4:Container Insights (OMS agent) not used - metrics and logs go to Prometheus and the OpenTelemetry collectors; control-plane logs go to Log Analytics (var)
  name                = var.cluster_name
  location            = data.azurerm_resource_group.aks.location
  resource_group_name = data.azurerm_resource_group.aks.name
  node_resource_group = local.node_resource_group
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier

  # Who gets in: Microsoft Entra ID tokens only (kubelogin), authorized by Azure role assignments - the
  # foundation gives the person "Azure Kubernetes Service RBAC Cluster Admin" on the cluster's group. No
  # local accounts: no admin certificate exists, and `az aks get-credentials --admin` is refused.
  role_based_access_control_enabled = true
  local_account_disabled            = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenant_id
  }

  # The control plane's own identity (load balancer, public IPs, disks in the node resource group): a
  # system-assigned managed identity - created and deleted with the cluster, no secret.
  identity {
    type = "SystemAssigned"
  }

  # Kubernetes patches (var.automatic_upgrade_channel) and node images (var.node_os_upgrade_channel),
  # each only inside the window; none of either needs no window.
  automatic_upgrade_channel = var.automatic_upgrade_channel == "none" ? null : var.automatic_upgrade_channel
  node_os_upgrade_channel   = var.node_os_upgrade_channel

  dynamic "maintenance_window_auto_upgrade" {
    for_each = var.automatic_upgrade_channel == "none" ? [] : [local.maintenance_window]
    content {
      frequency   = maintenance_window_auto_upgrade.value.frequency
      interval    = maintenance_window_auto_upgrade.value.interval
      day_of_week = maintenance_window_auto_upgrade.value.day_of_week
      start_time  = maintenance_window_auto_upgrade.value.start_time
      duration    = maintenance_window_auto_upgrade.value.duration
      utc_offset  = maintenance_window_auto_upgrade.value.utc_offset
    }
  }

  dynamic "maintenance_window_node_os" {
    for_each = contains(["None", "Unmanaged"], var.node_os_upgrade_channel) ? [] : [local.maintenance_window]
    content {
      frequency   = maintenance_window_node_os.value.frequency
      interval    = maintenance_window_node_os.value.interval
      day_of_week = maintenance_window_node_os.value.day_of_week
      start_time  = maintenance_window_node_os.value.start_time
      duration    = maintenance_window_node_os.value.duration
      utc_offset  = maintenance_window_node_os.value.utc_offset
    }
  }

  # Dual-stack Azure CNI Overlay with the Cilium data plane: Cilium is also the NetworkPolicy engine - the
  # only one AKS offers with dual-stack. The pod and service ranges are the module's (var); the node
  # network is AKS's managed one. Outbound through the load balancer, with one IPv4 and one IPv6
  # address: the documented way out for both families (a managed NAT gateway is IPv4 only).
  # https://learn.microsoft.com/azure/aks/azure-cni-overlay-dual-stack
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    ip_versions         = ["IPv4", "IPv6"]
    pod_cidrs           = var.pod_cidrs
    service_cidrs       = var.service_cidrs
    dns_service_ip      = cidrhost(var.service_cidrs[0], 10)
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"

    load_balancer_profile {
      managed_outbound_ip_count   = 1
      managed_outbound_ipv6_count = 1
    }
  }

  # Node pools are the two below, sized in terraform.tfvars - not node auto-provisioning (Karpenter), which
  # would pick sizes and add nodes by itself. azurerm 5 requires the block.
  node_provisioning_profile {
    mode = "Manual"
  }

  # The system pool: AKS's own pods (CoreDNS, the CSI drivers, Cilium, metrics-server) must run here; the
  # platform's run here too. No zones: one cluster per region for a test cycle - a cluster that matters
  # spreads its pools over zones (zones = ["1", "2", "3"]).
  default_node_pool {
    name                        = "platform"
    temporary_name_for_rotation = "platformtmp"
    # The nodes' version as well: azurerm sets a pool's version only when it creates the pool, so without
    # it a new kubernetes_version would upgrade the control plane alone.
    orchestrator_version = var.kubernetes_version
    vm_size              = var.platform_pool.vm_size
    node_count           = var.platform_pool.node_count
    os_disk_size_gb      = var.platform_pool.disk_size_gb
    os_disk_type         = "Managed"
    max_pods             = 250 # Azure CNI Overlay's own default, written out: pods do not use node network addresses
    node_labels          = { pool = "platform" }

    # An upgrade adds one node before it drains an old one.
    upgrade_settings {
      max_surge = "1"
    }
  }

  depends_on = [data.azurerm_client_config.me]
}

# The user pool for the applications. A fixed size: AKS adds no nodes by itself unless the cluster
# autoscaler is turned on; a pool grows by its node_count in terraform.tfvars.
resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  # checkov:skip=CKV_AZURE_226:ephemeral OS disks need a size with a local disk; D2as_v7 has none (managed OS disk)
  # checkov:skip=CKV_AZURE_227:host encryption needs the EncryptionAtHost feature registered per subscription; disks are encrypted at rest by the platform
  name                        = "apps"
  temporary_name_for_rotation = "appstmp"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.this.id
  mode                        = "User"
  orchestrator_version        = var.kubernetes_version
  vm_size                     = var.apps_pool.vm_size
  node_count                  = var.apps_pool.node_count
  os_disk_size_gb             = var.apps_pool.disk_size_gb
  os_disk_type                = "Managed"
  max_pods                    = 250
  node_labels                 = { pool = "apps" }

  upgrade_settings {
    max_surge = "1"
  }
}

# ─── Control-plane logs ───────────────────────────────────────────────────────
# The API server, the audit log without reads, and the Entra sign-ins (var.control_plane_log_categories),
# to a workspace of their own in the cluster's group - deleted with the cluster. Nothing without categories.
resource "azurerm_log_analytics_workspace" "control_plane" {
  count = length(var.control_plane_log_categories) > 0 ? 1 : 0

  name                = "${var.cluster_name}-aks-logs"
  location            = data.azurerm_resource_group.aks.location
  resource_group_name = data.azurerm_resource_group.aks.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
}

resource "azurerm_monitor_diagnostic_setting" "control_plane" {
  count = length(var.control_plane_log_categories) > 0 ? 1 : 0

  name                           = "control-plane-logs"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.control_plane[0].id
  log_analytics_destination_type = "Dedicated" # a table per category, not one AzureDiagnostics table

  dynamic "enabled_log" {
    for_each = var.control_plane_log_categories
    content {
      category = enabled_log.value
    }
  }
}

# ─── kubeconfig ───────────────────────────────────────────────────────────────
# The endpoint and Azure kubelogin: kubectl asks it for a short-lived Entra token of whoever is signed in
# to the Azure CLI. The file holds no credentials. The context name is fixed, so tools can name it.
resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig.yaml"
  file_permission = "0600"
  content = yamlencode({
    apiVersion        = "v1"
    kind              = "Config"
    "current-context" = "aks-${var.cluster_name}-control-plane"
    clusters = [{
      name = "aks-${var.cluster_name}"
      cluster = {
        server                       = azurerm_kubernetes_cluster.this.kube_config[0].host
        "certificate-authority-data" = azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
      }
    }]
    users = [{
      name = "aks-${var.cluster_name}"
      user = {
        exec = {
          apiVersion  = local.aks_exec.api_version
          command     = local.aks_exec.command
          args        = local.aks_exec.args
          installHint = "Azure kubelogin (github.com/Azure/kubelogin) and the Azure CLI signed in with AZURE_CONFIG_DIR from .env.azure (docs/azure.md)"
        }
      }
    }]
    contexts = [{
      name    = "aks-${var.cluster_name}-control-plane"
      context = { cluster = "aks-${var.cluster_name}", user = "aks-${var.cluster_name}" }
    }]
  })
}
