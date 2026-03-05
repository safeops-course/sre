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
  }
}

provider "kind" {}

provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = local.kubeconfig_path
}

locals {
  kubeconfig_path          = pathexpand("${path.module}/kubeconfig.yaml")
  flux_pull_secret_yaml    = var.github_app_id != "" ? "    pullSecret: \"flux-system\"\n" : ""
  backup_s3_secret_enabled = nonsensitive(var.r2_access_key_id != "" && var.r2_secret_access_key != "")
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
    kubernetes_secret.flux_github_app
  ]

  triggers = {
    kubeconfig_path = local.kubeconfig_path
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
    provider: github
    path: "${var.flux_kustomization_path}"
${local.flux_pull_secret_yaml}
EOF
    EOC
    interpreter = ["/bin/bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "kubectl --kubeconfig=\"${self.triggers.kubeconfig_path}\" delete fluxinstance flux -n flux-system --ignore-not-found=true"
    interpreter = ["/bin/bash", "-c"]
  }
}

# Create GitHub App secret for Flux authentication
resource "kubernetes_secret" "flux_github_app" {
  count      = var.github_app_id != "" ? 1 : 0
  depends_on = [null_resource.flux_operator_install]

  metadata {
    name      = "flux-system"
    namespace = "flux-system"
  }

  data = {
    "githubAppID"             = var.github_app_id
    "githubAppInstallationID" = var.github_app_installation_id
    "githubAppPrivateKey"     = file(var.github_app_private_key_file)
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
  }

  depends_on = [time_sleep.wait_for_cluster]
}

# Bootstrap namespaces early so Terraform can safely create cross-namespace secrets.
resource "kubernetes_namespace" "bootstrap" {
  for_each = toset(["develop", "staging", "production", "observability"])

  metadata {
    name = each.key
  }

  depends_on = [time_sleep.wait_for_cluster]

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
    ]
  }
}

# Create imagePullSecret for GHCR in each namespace
resource "kubernetes_secret" "ghcr_credentials" {
  for_each   = var.enable_ghcr ? toset(["flux-system", "develop", "staging", "production", "observability"]) : toset([])
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

# Create GitHub token secret for ImageUpdateAutomation
resource "kubernetes_secret" "github_image_automation" {
  count      = var.flux_git_token != "" ? 1 : 0
  depends_on = [null_resource.flux_instance]

  metadata {
    name      = "github-image-automation"
    namespace = "flux-system"
  }

  type = "Opaque"

  data = {
    username = "git"
    password = var.flux_git_token
  }
}

# Create SOPS age secret for Flux decryption
resource "kubernetes_secret" "sops_age" {
  count      = var.sops_age_key != "" ? 1 : 0
  depends_on = [null_resource.flux_instance]

  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  type = "Opaque"

  data = {
    "age.agekey" = var.sops_age_key
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
