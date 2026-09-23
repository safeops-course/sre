terraform {
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "0.9.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "kind" {}

provider "helm" {
  kubernetes {
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
  backup_s3_secret_enabled = nonsensitive(var.r2_access_key_id != "" && var.r2_secret_access_key != "")
  ghcr_secret_enabled      = var.enable_ghcr && nonsensitive(var.ghcr_token != "")
}

resource "kind_cluster" "sre" {
  name            = "sre-control-plane"
  wait_for_ready  = true
  kubeconfig_path = local.kubeconfig_path

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
}

resource "time_sleep" "wait_for_cluster" {
  depends_on      = [null_resource.merge_kubeconfig]
  create_duration = "30s"
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
    kubectl config use-context sre-control-plane
  EOT
}

resource "kubernetes_namespace" "traefik" {
  metadata { name = "traefik" }
  depends_on = [time_sleep.wait_for_cluster]
}

resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  namespace  = "traefik"
  version    = "34.5.0"

  depends_on = [kubernetes_namespace.traefik]

  set {
    name  = "service.type"
    value = "NodePort"
  }
  set {
    name  = "ports.web.nodePort"
    value = "30080"
  }
  set {
    name  = "ports.websecure.nodePort"
    value = "30443"
  }
  set {
    name  = "providers.kubernetesIngress.enabled"
    value = "true"
  }
  set {
    name  = "providers.kubernetesCRD.enabled"
    value = "true"
  }
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.2"

  depends_on = [time_sleep.wait_for_cluster]

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }
}

resource "null_resource" "flux_operator_install" {
  depends_on = [time_sleep.wait_for_cluster]

  triggers = {
    kubeconfig_path = local.kubeconfig_path
    repo_url        = var.flux_git_repository_url
    repo_branch     = var.flux_git_repository_branch
    repo_path       = var.flux_kustomization_path
    provider        = "github"
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
    kubernetes_secret.flux_git_auth
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
}

resource "null_resource" "flux_pre_destroy" {
  depends_on = [
    kind_cluster.sre,
    kubernetes_namespace.traefik,
    kubernetes_namespace.bootstrap,
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
}

# Create PAT secret for Flux git authentication
resource "kubernetes_secret" "flux_git_auth" {
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
resource "kubernetes_config_map" "cluster_config" {
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
resource "kubernetes_secret" "cluster_secrets" {
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
resource "kubernetes_namespace" "bootstrap" {
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
resource "kubernetes_secret" "ghcr_credentials" {
  for_each   = local.ghcr_secret_enabled ? toset(["flux-system", "develop", "staging", "production", "observability"]) : toset([])
  depends_on = [null_resource.flux_instance, kubernetes_namespace.bootstrap]

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


# Create SOPS age secret for Flux decryption
resource "kubernetes_secret" "sops_age" {
  count      = var.sops_age_key != "" || var.local_profile ? 1 : 0
  depends_on = [null_resource.flux_instance, null_resource.age_key]

  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  type = "Opaque"

  data = {
    "age.agekey" = var.sops_age_key != "" ? var.sops_age_key : data.local_file.age_key[0].content
  }
}

# Create CNPG backup S3 secret in each environment namespace
resource "kubernetes_secret" "cnpg_backup_s3" {
  for_each = local.backup_s3_secret_enabled ? toset(["develop", "staging", "production"]) : toset([])

  metadata {
    name      = "cnpg-backup-s3"
    namespace = each.key
  }

  type = "Opaque"

  data = merge(
    {
      ACCESS_KEY_ID     = var.r2_access_key_id
      ACCESS_SECRET_KEY = var.r2_secret_access_key
      BUCKET            = var.r2_bucket
    },
    var.r2_endpoint != "" ? { ENDPOINT = var.r2_endpoint } : {},
    var.r2_region != "" ? { REGION = var.r2_region } : {},
  )

  depends_on = [kubernetes_namespace.bootstrap]
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
