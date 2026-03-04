provider "hcloud" {
  token = var.hcloud_token
}

# ─── Pool & feature construction ─────────────────────────────────────────────

locals {
  # Control plane — always one pool.
  control_plane_nodepools = [
    {
      name         = "cp"
      server_type  = var.control_plane_server_type
      location     = var.location
      labels       = ["project=sre", "managed-by=terraform"]
      taints       = []
      count        = var.control_plane_count
      disable_ipv6 = true
    },
  ]

  # Static workers — used when autoscaling is OFF.
  # When autoscaling is ON the workers pool moves to autoscaler_nodepools.
  static_agent_pools = var.autoscaling_enabled ? [] : [
    {
      name         = "workers"
      server_type  = var.workers_server_type
      location     = var.location
      labels       = ["role=workers", "project=sre", "managed-by=terraform"]
      taints       = []
      count        = var.workers_count
      disable_ipv6 = true
    },
  ]

  # Autoscaler pool — used when autoscaling is ON.
  autoscaler_nodepools = var.autoscaling_enabled ? [
    {
      name        = "workers"
      server_type = var.workers_server_type
      location    = var.location
      min_nodes   = var.autoscaling_min_nodes
      max_nodes   = var.autoscaling_max_nodes
      labels      = { "role" = "workers", "project" = "sre", "managed-by" = "terraform" }
    },
  ] : []

  # Kured options — only populated when enabled.
  kured_options = var.kured_enabled ? {
    "reboot-days" = var.kured_reboot_days
    "start-time"  = var.kured_start_time
    "end-time"    = var.kured_end_time
  } : {}

  # etcd S3 backup — reuses the R2/S3 credentials already wired through load-env.sh.
  # k3s expects a bare hostname (no https:// prefix).
  etcd_s3_endpoint = var.backup_s3_endpoint != "" ? replace(var.backup_s3_endpoint, "https://", "") : ""

  etcd_s3_backup = local.etcd_s3_endpoint != "" ? {
    "etcd-s3-endpoint"   = local.etcd_s3_endpoint
    "etcd-s3-access-key" = var.backup_s3_access_key_id
    "etcd-s3-secret-key" = var.backup_s3_secret_access_key
    "etcd-s3-bucket"     = var.backup_s3_bucket
    "etcd-s3-folder"     = "${var.cluster_name}/etcd-snapshots"
    "etcd-s3-region"     = var.backup_s3_region
  } : {}
}

module "kube_hetzner" {
  # kube-hetzner v2.19.0
  source = "git::https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner.git?ref=a52d120bfb9f67d6c1d01add5d202609543df3ab"
  providers = {
    hcloud = hcloud
  }

  # Core
  hcloud_token    = var.hcloud_token
  cluster_name    = var.cluster_name
  ssh_public_key  = var.ssh_public_key
  ssh_private_key = var.ssh_private_key

  # Node pools
  control_plane_nodepools           = local.control_plane_nodepools
  agent_nodepools                   = local.static_agent_pools
  autoscaler_nodepools              = local.autoscaler_nodepools
  allow_scheduling_on_control_plane = var.allow_scheduling_on_control_plane

  # Load balancer
  load_balancer_type         = var.load_balancer_type
  load_balancer_location     = var.location
  load_balancer_disable_ipv6 = true

  # Ingress
  ingress_controller        = var.ingress_controller
  traefik_redirect_to_https = var.traefik_redirect_to_https
  traefik_autoscaling       = var.traefik_autoscaling

  # K3s versioning
  initial_k3s_channel       = var.k3s_channel
  install_k3s_version       = var.k3s_version
  automatically_upgrade_k3s = var.auto_upgrade_k3s
  automatically_upgrade_os  = var.auto_upgrade_os

  # Kured
  kured_options = local.kured_options

  # etcd backup to S3/R2
  etcd_s3_backup = local.etcd_s3_backup
}

locals {
  kubeconfig_path = pathexpand("${path.module}/kubeconfig.yaml")

  # Render pullSecret only when a token is provided.
  flux_pull_secret_yaml = var.flux_git_token != "" ? "    pullSecret: flux-system\n" : ""

  flux_git_secret_enabled = var.flux_git_token != ""
  sops_age_secret_enabled = var.sops_age_key != ""
  backup_s3_secret_enabled = nonsensitive(
    var.backup_s3_access_key_id != "" &&
    var.backup_s3_secret_access_key != "" &&
    var.backup_s3_bucket != ""
  )
}

resource "local_sensitive_file" "kubeconfig" {
  content         = module.kube_hetzner.kubeconfig
  filename        = local.kubeconfig_path
  file_permission = "0600"
}

provider "helm" {
  kubernetes {
    host                   = module.kube_hetzner.kubeconfig_data.host
    client_certificate     = module.kube_hetzner.kubeconfig_data.client_certificate
    client_key             = module.kube_hetzner.kubeconfig_data.client_key
    cluster_ca_certificate = module.kube_hetzner.kubeconfig_data.cluster_ca_certificate
  }
}

provider "kubernetes" {
  host                   = module.kube_hetzner.kubeconfig_data.host
  client_certificate     = module.kube_hetzner.kubeconfig_data.client_certificate
  client_key             = module.kube_hetzner.kubeconfig_data.client_key
  cluster_ca_certificate = module.kube_hetzner.kubeconfig_data.cluster_ca_certificate
}

resource "kubernetes_namespace" "bootstrap" {
  for_each = toset([
    "flux-system",
    "develop",
    "staging",
    "production",
    "observability",
  ])

  metadata {
    name = each.value
    labels = {
      "managed-by" = "terraform"
    }
  }

  depends_on = [local_sensitive_file.kubeconfig]

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]
  }
}

# Optional: credentials for syncing a private Git repository over HTTPS.
resource "kubernetes_secret" "flux_git_credentials" {
  count = local.flux_git_secret_enabled ? 1 : 0

  metadata {
    name      = "flux-system"
    namespace = "flux-system"
  }

  type = "Opaque"

  data = {
    username = "git"
    password = var.flux_git_token
  }

  depends_on = [kubernetes_namespace.bootstrap]
}

resource "null_resource" "flux_operator_install" {
  depends_on = [kubernetes_namespace.bootstrap]

  triggers = {
    kubeconfig_path = local.kubeconfig_path
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    command     = "kubectl --kubeconfig=\"${local.kubeconfig_path}\" apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/install.yaml"
  }
}

resource "null_resource" "flux_instance" {
  depends_on = [
    null_resource.flux_operator_install,
    kubernetes_secret.flux_git_credentials,
  ]

  triggers = {
    kubeconfig_path = local.kubeconfig_path
    repo_url        = var.flux_git_repository_url
    repo_branch     = var.flux_git_repository_branch
    repo_path       = var.flux_kustomization_path
    flux_version    = var.flux_version
    provider        = "generic"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOC
      cat <<EOF | kubectl --kubeconfig="${local.kubeconfig_path}" apply -f -
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "${var.flux_version}"
    registry: ghcr.io/fluxcd
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
    - image-reflector-controller
    - image-automation-controller
  cluster:
    type: kubernetes
  sync:
    kind: GitRepository
    url: "${var.flux_git_repository_url}"
    ref: "refs/heads/${var.flux_git_repository_branch}"
    provider: generic
    path: "${var.flux_kustomization_path}"
${local.flux_pull_secret_yaml}
EOF
    EOC
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = "kubectl --kubeconfig=\"${self.triggers.kubeconfig_path}\" delete fluxinstance flux -n flux-system --ignore-not-found=true --timeout=30s 2>/dev/null || true"
  }
}

# Optional: GHCR imagePullSecret in every namespace used by workloads.
resource "kubernetes_secret" "ghcr_credentials" {
  for_each = var.enable_ghcr ? toset(["flux-system", "develop", "staging", "production", "observability"]) : toset([])

  metadata {
    name      = "ghcr-credentials-docker"
    namespace = each.key
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          username = var.ghcr_username
          password = var.ghcr_token
          auth     = base64encode("${var.ghcr_username}:${var.ghcr_token}")
        }
      }
    })
  }

  depends_on = [kubernetes_namespace.bootstrap]
}

# GitHub token for ImageUpdateAutomation (push commits back to repo).
resource "kubernetes_secret" "github_image_automation" {
  count = local.flux_git_secret_enabled ? 1 : 0

  metadata {
    name      = "github-image-automation"
    namespace = "flux-system"
  }

  type = "Opaque"

  data = {
    username = "git"
    password = var.flux_git_token
  }

  depends_on = [kubernetes_namespace.bootstrap]
}

# Optional: age private key for Flux SOPS decryption.
resource "kubernetes_secret" "sops_age" {
  count = local.sops_age_secret_enabled ? 1 : 0

  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  data = {
    "age.agekey" = var.sops_age_key
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.bootstrap]
}

# Optional: backup object-store credentials for CloudNativePG.
resource "kubernetes_secret" "cnpg_backup_s3" {
  for_each = local.backup_s3_secret_enabled ? toset(["develop", "staging", "production"]) : toset([])

  metadata {
    name      = "cnpg-backup-s3"
    namespace = each.key
  }

  type = "Opaque"

  data = merge(
    {
      ACCESS_KEY_ID     = var.backup_s3_access_key_id
      ACCESS_SECRET_KEY = var.backup_s3_secret_access_key
      BUCKET            = var.backup_s3_bucket
    },
    var.backup_s3_endpoint != "" ? { ENDPOINT = var.backup_s3_endpoint } : {},
    var.backup_s3_region != "" ? { REGION = var.backup_s3_region } : {},
  )

  depends_on = [kubernetes_namespace.bootstrap]
}
