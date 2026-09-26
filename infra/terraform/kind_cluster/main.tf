terraform {
  required_version = ">= 1.10.1"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.11"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}

provider "kind" {}

provider "helm" {
  kubernetes = {
    host                   = kind_cluster.sre.endpoint
    client_certificate     = kind_cluster.sre.client_certificate
    client_key             = kind_cluster.sre.client_key
    cluster_ca_certificate = kind_cluster.sre.cluster_ca_certificate
  }
}

provider "kubernetes" {
  host                   = kind_cluster.sre.endpoint
  client_certificate     = kind_cluster.sre.client_certificate
  client_key             = kind_cluster.sre.client_key
  cluster_ca_certificate = kind_cluster.sre.cluster_ca_certificate
}

locals {
  kubeconfig_path          = pathexpand("${path.module}/kubeconfig.yaml")
  flux_pull_secret_yaml    = var.flux_git_token != "" ? "    pullSecret: \"flux-system\"\n" : ""
  backup_s3_secret_enabled = nonsensitive(var.backup_s3_access_key_id != "" && var.backup_s3_secret_access_key != "")
  ghcr_secret_enabled      = var.enable_ghcr && nonsensitive(var.ghcr_token != "")
}

resource "kind_cluster" "sre" {
  name            = "sre-control-plane"
  wait_for_ready  = true
  kubeconfig_path = local.kubeconfig_path
  node_image      = var.kind_node_image

  kind_config {
    api_version = "kind.x-k8s.io/v1alpha4"
    kind        = "Cluster"

    networking {
      api_server_address = "127.0.0.1"
      api_server_port    = 6443
      kube_proxy_mode    = "iptables"
    }

    containerd_config_patches = [
      <<-EOT
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5001"]
          endpoint = ["http://kind-registry:5000"]
      EOT
    ]

    node {
      role = "control-plane"

      kubeadm_config_patches = [
        <<-EOT
          kind: InitConfiguration
          nodeRegistration:
            kubeletExtraArgs:
              node-labels: "ingress-ready=true"
              authorization-mode: "Webhook"
        EOT
      ]

      extra_port_mappings {
        container_port = 30080
        host_port      = 8080
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 30443
        host_port      = 8443
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
    }

    node {
      role = "worker"
    }
  }
}

resource "null_resource" "merge_kubeconfig" {
  depends_on = [kind_cluster.sre]

  provisioner "local-exec" {
    when        = create
    command     = "${path.module}/scripts/merge-kubeconfig.sh \"${local.kubeconfig_path}\""
    interpreter = ["/bin/bash", "-c"]
  }

  # A new kind cluster (for example a new node_image) needs this step again;
  # without it the replaced cluster came up without Flux.
  lifecycle {
    replace_triggered_by = [kind_cluster.sre]
  }
}

resource "time_sleep" "wait_for_cluster" {
  depends_on      = [null_resource.merge_kubeconfig]
  create_duration = "30s"

  # A new kind cluster (for example a new node_image) needs this step again;
  # without it the replaced cluster came up without Flux.
  lifecycle {
    replace_triggered_by = [kind_cluster.sre]
  }
}

output "kubeconfig" {
  description = "Path to the generated kubeconfig for the kind cluster"
  value       = local.kubeconfig_path
}

output "kubeconfig_load_instructions" {
  description = "How to use the generated kubeconfig"
  value       = <<-EOT
    export KUBECONFIG="${local.kubeconfig_path}"
    kubectl get nodes
    # Optional: merge into your default kubeconfig
    ${path.module}/scripts/merge-kubeconfig.sh "${local.kubeconfig_path}"
    kubectl config use-context kind-sre-control-plane
  EOT
}

resource "kubernetes_namespace_v1" "traefik" {
  metadata { name = "traefik" }
  depends_on = [time_sleep.wait_for_cluster]
}

resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  namespace  = "traefik"
  version    = var.traefik_chart_version

  depends_on = [kubernetes_namespace_v1.traefik]

  set = [
    {
      name  = "service.spec.type"
      value = "NodePort"
    },
    {
      name  = "ports.web.nodePort"
      value = "30080"
    },
    {
      name  = "ports.websecure.nodePort"
      value = "30443"
    },
    {
      name  = "providers.kubernetesIngress.enabled"
      value = "true"
    },
    {
      name  = "providers.kubernetesCRD.enabled"
      value = "true"
    },
  ]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = var.metrics_server_chart_version

  depends_on = [time_sleep.wait_for_cluster]

  set = [
    {
      name  = "args[0]"
      value = "--kubelet-insecure-tls"
    },
  ]
}

resource "null_resource" "flux_operator_install" {
  depends_on = [time_sleep.wait_for_cluster]

  triggers = {
    kubeconfig_path = local.kubeconfig_path
    repo_url        = var.flux_git_repository_url
    repo_branch     = var.flux_git_repository_branch
    repo_path       = var.flux_kustomization_path
    provider        = "github"
    # reinstall when the pinned Flux Operator release changes
    operator_version = var.flux_operator_version
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    command     = "kubectl --kubeconfig=\"${local.kubeconfig_path}\" apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v${var.flux_operator_version}/install.yaml"
  }

  # A new kind cluster (for example a new node_image) needs this step again;
  # without it the replaced cluster came up without Flux.
  lifecycle {
    replace_triggered_by = [kind_cluster.sre]
  }
}

resource "null_resource" "flux_instance" {
  depends_on = [
    null_resource.flux_operator_install,
    kubernetes_secret_v1.flux_git_auth
  ]

  triggers = {
    kubeconfig_path = local.kubeconfig_path
    # Re-create the FluxInstance when its sync spec changes; before this only
    # the kubeconfig path was tracked, so switching repo/branch/path/token
    # after the first apply silently did nothing.
    repo_url    = var.flux_git_repository_url
    repo_branch = var.flux_git_repository_branch
    repo_path   = var.flux_kustomization_path
    pull_secret = local.flux_pull_secret_yaml
    # re-apply the FluxInstance when the pinned Flux version changes
    flux_version = var.flux_version
  }

  provisioner "local-exec" {
    when        = create
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
    interpreter = ["/bin/bash", "-c"]
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    # Wait for the operator to finish uninstalling: with --wait=false a
    # replacement (new FluxInstance applied while the old one is still
    # terminating) gets deleted together with the old one.
    command     = "kubectl --kubeconfig=\"${self.triggers.kubeconfig_path}\" delete fluxinstance flux -n flux-system --ignore-not-found=true --wait=true --timeout=5m"
    interpreter = ["/bin/bash", "-c"]
  }

  # A new kind cluster (for example a new node_image) needs this step again;
  # without it the replaced cluster came up without Flux.
  lifecycle {
    replace_triggered_by = [kind_cluster.sre]
  }
}

resource "null_resource" "flux_pre_destroy" {
  depends_on = [
    kind_cluster.sre,
    kubernetes_namespace_v1.traefik,
    kubernetes_namespace_v1.bootstrap,
    null_resource.flux_instance,
  ]

  triggers = {
    kubeconfig_path = local.kubeconfig_path
    namespaces      = "develop,staging,production,observability,traefik,minio"
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    command     = "\"${path.module}/../scripts/flux-pre-destroy.sh\" \"${self.triggers.kubeconfig_path}\" \"${self.triggers.namespaces}\""
    interpreter = ["/bin/bash", "-c"]
  }

  # A new kind cluster (for example a new node_image) needs this step again;
  # without it the replaced cluster came up without Flux.
  lifecycle {
    replace_triggered_by = [kind_cluster.sre]
  }
}

# Create PAT secret for Flux git authentication
resource "kubernetes_secret_v1" "flux_git_auth" {
  count      = var.flux_git_token != "" ? 1 : 0
  depends_on = [null_resource.flux_operator_install]

  metadata {
    name      = "flux-system"
    namespace = "flux-system"
  }

  data = {
    username = "git"
    password = var.flux_git_token
  }

  type = "Opaque"
}

# Cluster-level config consumed by Flux postBuild substitutions.
resource "kubernetes_config_map_v1" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = "flux-system"
  }

  data = {
    cloudflare_proxied = "disabled"
    cluster_name       = "sre-control-plane"
    image_registry     = var.image_registry
    git_owner          = var.git_owner
  }

  depends_on = [null_resource.flux_operator_install]
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

  depends_on = [null_resource.flux_operator_install]
}

# Bootstrap namespaces early so Terraform can safely create cross-namespace secrets.
resource "kubernetes_namespace_v1" "bootstrap" {
  for_each = toset(["develop", "staging", "production", "observability"])

  metadata {
    name = each.key
  }

  depends_on = [time_sleep.wait_for_cluster]

  lifecycle {
    # Flux owns labels (pod-security, kustomize.toolkit) and annotations
    # (kustomize.toolkit.fluxcd.io/prune) on these namespaces; Terraform only
    # guarantees they exist early enough for the generated secrets.
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]
  }
}

# Create imagePullSecret for GHCR in each namespace
resource "kubernetes_secret_v1" "ghcr_credentials" {
  for_each   = local.ghcr_secret_enabled ? toset(["flux-system", "develop", "staging", "production", "observability"]) : toset([])
  depends_on = [null_resource.flux_instance, kubernetes_namespace_v1.bootstrap]

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
}


# SOPS age secret for Flux decryption. Write-only (data_wo): sops_age_key never reaches the plan
# or the state (the generated local-profile key is a throwaway dev key read by data.local_file).
# After rotating sops_age_key, bump sops_age_key_revision so Terraform re-sends it.
resource "kubernetes_secret_v1" "sops_age" {
  depends_on = [null_resource.flux_instance, null_resource.age_key]

  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  type = "Opaque"

  data_wo = {
    "age.agekey" = var.sops_age_key != "" ? var.sops_age_key : data.local_file.age_key[0].content
  }
  data_wo_revision = var.sops_age_key_revision
}

# The secret used to be optional (count); keep the existing object instead of recreating it.
moved {
  from = kubernetes_secret_v1.sops_age[0]
  to   = kubernetes_secret_v1.sops_age
}

# Non-secret backup target for Flux. The cnpg-cluster-<env> Kustomizations read
# BACKUP_S3_ENDPOINT and BACKUP_S3_BUCKET from this ConfigMap (postBuild.substituteFrom),
# so etcd snapshots, the cnpg-backup-s3 Secret and the CNPG clusters all use the same
# Terraform inputs - there is no second copy of these values in Git.
# Local profile: the in-cluster MinIO (bucket sre, created by flux/infrastructure/data/minio).
resource "kubernetes_config_map_v1" "backup_s3" {
  depends_on = [null_resource.flux_instance]

  metadata {
    name      = "backup-s3"
    namespace = "flux-system"
  }

  data = var.local_profile ? {
    BACKUP_S3_ENDPOINT = "http://minio.minio.svc.cluster.local:9000"
    BACKUP_S3_BUCKET   = "sre"
    } : {
    BACKUP_S3_ENDPOINT = var.backup_s3_endpoint
    BACKUP_S3_BUCKET   = var.backup_s3_bucket
  }
}

# CNPG backup credentials (Hetzner Object Storage) for the full platform profile
# (local_profile = false). The local profile uses MinIO instead (local-profile.tf).
# Full platform profile only (local_profile = false; local-profile.tf seeds all three
# envs for the local profile). CNPG owner credentials for production (bootstrap.initdb.secret, and DATABASE_* of the
# backend). Generated per cluster and never written to Git - the plain Secret that used
# to live in flux/infrastructure/data/cnpg-clusters/production made the production
# database password public. develop/staging still come from SOPS (flux/secrets/<env>).
resource "random_password" "postgres_app_production" {
  count   = var.local_profile ? 0 : 1
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "postgres_app_production" {
  count = var.local_profile ? 0 : 1

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
    password = random_password.postgres_app_production[0].result
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

output "flux_operator_installed" {
  description = "Indicates that Flux Operator has been installed"
  value       = null_resource.flux_operator_install.id != ""
}

output "flux_instance_created" {
  description = "Indicates that FluxInstance has been created"
  value       = "flux"
  depends_on  = [null_resource.flux_instance]
}
