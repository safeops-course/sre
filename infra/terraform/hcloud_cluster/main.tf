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

  # etcd S3 backup — the same Hetzner Object Storage bucket and key as the CNPG backups (BACKUP_S3).
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
  source  = "kube-hetzner/kube-hetzner/hcloud"
  version = "3.2.1"
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
  load_balancer_type        = var.load_balancer_type
  load_balancer_location    = var.location
  load_balancer_enable_ipv6 = false

  # Ingress
  ingress_controller        = var.ingress_controller
  traefik_redirect_to_https = var.traefik_redirect_to_https
  traefik_autoscaling       = var.traefik_autoscaling

  # K3s versioning
  k3s_channel                      = var.k3s_channel
  k3s_version                      = var.k3s_version
  automatically_upgrade_kubernetes = var.auto_upgrade_k3s
  automatically_upgrade_os         = var.auto_upgrade_os

  # cert-manager is managed by Flux, not kube-hetzner
  enable_cert_manager = false

  # Kured
  kured_options = local.kured_options

  # etcd backup to Hetzner Object Storage
  etcd_s3_backup = local.etcd_s3_backup

  # OIDC / extra kube-apiserver flags
  control_plane_exec_args = var.k3s_exec_server_args
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
  kubernetes = {
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

resource "kubernetes_namespace_v1" "bootstrap" {
  for_each = toset([
    "flux-system",
    "develop",
    "staging",
    "production",
    "observability",
    "auth",
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

# Cluster-level config consumed by Flux postBuild substitutions.
resource "kubernetes_config_map_v1" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = "flux-system"
  }

  data = {
    cloudflare_proxied = "enabled"
    cluster_name       = var.cluster_name
    image_registry     = var.image_registry
    git_owner          = var.git_owner
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# Sensitive config consumed by Flux postBuild substitutions (via substituteFrom Secret).
resource "kubernetes_secret_v1" "cluster_secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = "flux-system"
  }

  type = "Opaque"

  data = {
    uptrace_dsn = var.uptrace_dsn
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# Optional: credentials for syncing a private Git repository over HTTPS.
resource "kubernetes_secret_v1" "flux_git_credentials" {
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

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

resource "null_resource" "flux_operator_install" {
  depends_on = [kubernetes_namespace_v1.bootstrap]

  triggers = {
    kubeconfig_path = local.kubeconfig_path
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    command     = "kubectl --kubeconfig=\"${local.kubeconfig_path}\" apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v${var.flux_operator_version}/install.yaml"
  }
}

resource "null_resource" "flux_instance" {
  depends_on = [
    null_resource.flux_operator_install,
    kubernetes_secret_v1.flux_git_credentials,
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
    command     = "kubectl --kubeconfig=\"${self.triggers.kubeconfig_path}\" delete fluxinstance flux -n flux-system --ignore-not-found=true --wait=false --timeout=30s 2>/dev/null || true"
  }
}

resource "null_resource" "flux_pre_destroy" {
  depends_on = [
    local_sensitive_file.kubeconfig,
    kubernetes_namespace_v1.bootstrap,
    null_resource.flux_instance,
  ]

  triggers = {
    kubeconfig_path = local.kubeconfig_path
    namespaces      = "flux-system,develop,staging,production,observability"
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = "\"${path.module}/../scripts/flux-pre-destroy.sh\" \"${self.triggers.kubeconfig_path}\" \"${self.triggers.namespaces}\""
  }
}

# Optional: GHCR imagePullSecret in every namespace used by workloads.
resource "kubernetes_secret_v1" "ghcr_credentials" {
  for_each = var.enable_ghcr ? toset(["flux-system", "develop", "staging", "production", "observability", "auth"]) : toset([])

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

  depends_on = [kubernetes_namespace_v1.bootstrap]
}


# Optional: age private key for Flux SOPS decryption.
resource "kubernetes_secret_v1" "sops_age" {
  count = local.sops_age_secret_enabled ? 1 : 0

  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  data = {
    "age.agekey" = var.sops_age_key
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# Non-secret backup target for Flux. The cnpg-cluster-<env> Kustomizations read
# BACKUP_S3_ENDPOINT and BACKUP_S3_BUCKET from this ConfigMap (postBuild.substituteFrom),
# so etcd snapshots, the cnpg-backup-s3 Secret and the CNPG clusters all use the same
# Terraform inputs - there is no second copy of these values in Git.
resource "kubernetes_config_map_v1" "backup_s3" {
  metadata {
    name      = "backup-s3"
    namespace = "flux-system"
  }

  data = {
    BACKUP_S3_ENDPOINT = var.backup_s3_endpoint
    BACKUP_S3_BUCKET   = var.backup_s3_bucket
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# Optional: backup object-store credentials for CloudNativePG.
# CNPG owner credentials for production (bootstrap.initdb.secret, and DATABASE_* of the
# backend). Generated per cluster and never written to Git - the plain Secret that used
# to live in flux/infrastructure/data/cnpg-clusters/production made the production
# database password public. develop/staging still come from SOPS (flux/secrets/<env>).
resource "random_password" "postgres_app_production" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "postgres_app_production" {
  metadata {
    name      = "app-postgres-app"
    namespace = "production"
    labels = {
      "cnpg.io/reload" = "true"
    }
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = "app"
    password = random_password.postgres_app_production.result
  }

  # CNPG adopts the Secret and adds connection keys and labels; Terraform only seeds it.
  lifecycle {
    ignore_changes = [data, metadata[0].labels, metadata[0].annotations]
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

resource "kubernetes_secret_v1" "cnpg_backup_s3" {
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

  depends_on = [kubernetes_namespace_v1.bootstrap]
}
