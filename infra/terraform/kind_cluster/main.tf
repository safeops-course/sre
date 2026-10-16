# Local kind cluster of the SafeOps course - Chapter 00 builds it, Chapter 02 explains it.
#
# What this file creates. Terraform works out the order from the references
# between resources (kind_cluster.sre.endpoint in a provider block, depends_on):
#   1. kind_cluster.sre                     the cluster: each node is a Docker container
#   2. merge_kubeconfig                     its kubeconfig merged into ~/.kube/config
#   3. helm_release.cilium                  the network (CNI): dual-stack, NetworkPolicies - the same engine as
#                                           Hetzner (kube-hetzner's Cilium) and GKE (Dataplane V2 is Cilium)
#      wait_for_nodes, wait_for_cluster     Cilium rolled out and every node Ready, then a short wait for the API
#   4. helm_release.metrics_server          metrics for kubectl top and the HPA (Traefik, the ingress, comes from Flux)
#   5. namespaces, ConfigMaps, Secrets      what Flux expects to find when it starts deploying -
#                                           incl. flux_git_auth, the Git token (private forks only)
#   6. flux_operator_install, flux_instance Flux, following your fork - from here on Git drives the cluster
# local-profile.tf adds the generated secrets of the local profile; variables.tf holds the inputs.
#
# Run it through the guard - plan, read, apply that plan: make kind-plan, then make kind-apply.
# Terraform language: https://developer.hashicorp.com/terraform/language

# Terraform and provider versions. A provider is a plugin that talks to one API;
# "~> 3.3" means 3.3 or newer, but below 4.0. https://developer.hashicorp.com/terraform/language/providers/requirements
terraform {
  required_version = ">= 1.11.0" # write-only attributes (data_wo) need 1.11; ephemeral variables 1.10

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

# kind provider - creates the cluster. https://registry.terraform.io/providers/tehcyx/kind/latest/docs
provider "kind" {}

# Helm and Kubernetes providers, configured from the cluster created below
# (kind_cluster.sre.*): they always talk to this cluster, never to your current
# kubectl context. A lab convenience - in production the cluster and what runs in
# it are separate applies (Chapter 02).
# https://registry.terraform.io/providers/hashicorp/helm/latest/docs
provider "helm" {
  kubernetes = {
    host                   = kind_cluster.sre.endpoint
    client_certificate     = kind_cluster.sre.client_certificate
    client_key             = kind_cluster.sre.client_key
    cluster_ca_certificate = kind_cluster.sre.cluster_ca_certificate
  }
}

# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs
provider "kubernetes" {
  host                   = kind_cluster.sre.endpoint
  client_certificate     = kind_cluster.sre.client_certificate
  client_key             = kind_cluster.sre.client_key
  cluster_ca_certificate = kind_cluster.sre.cluster_ca_certificate
}

# Values computed once and reused below. https://developer.hashicorp.com/terraform/language/values/locals
locals {
  kubeconfig_path          = pathexpand("${path.module}/kubeconfig.yaml")
  flux_pull_secret_yaml    = var.flux_git_token != "" ? "    pullSecret: \"flux-system\"\n" : ""
  backup_s3_secret_enabled = nonsensitive(var.backup_s3_access_key_id != "" && var.backup_s3_secret_access_key != "")
  ghcr_secret_enabled      = var.enable_ghcr && nonsensitive(var.ghcr_token != "")
}

# MinIO's data directory on this machine (git-ignored), mounted into the worker node below: the CNPG
# backups survive `make kind-destroy`, so a rebuilt cluster can restore from them (Chapter 22).
# Created before the cluster with mode 0777: Docker would create a missing mount source as root, and
# MinIO runs as uid 1000. `rm -rf` it for a clean start - a new cluster writes a new archive anyway.
locals {
  minio_data_dir = abspath("${path.module}/.minio-data")
}

resource "terraform_data" "minio_data_dir" {
  input = local.minio_data_dir

  provisioner "local-exec" {
    command = "mkdir -p \"${local.minio_data_dir}\" && chmod 0777 \"${local.minio_data_dir}\""
  }
}

# The cluster. kind runs each node as a Docker container; the resource returns the
# API address and client certificate that the providers above use.
# https://registry.terraform.io/providers/tehcyx/kind/latest/docs/resources/cluster
resource "kind_cluster" "sre" {
  depends_on = [terraform_data.minio_data_dir]

  name = "sre-control-plane"
  # kind's own wait waits for Ready nodes, and a node is Ready only once a CNI runs - ours (Cilium) is
  # installed right after, so waiting here would never end. helm_release.cilium waits for it instead.
  wait_for_ready  = false
  kubeconfig_path = local.kubeconfig_path
  node_image      = var.kind_node_image

  kind_config {
    api_version = "kind.x-k8s.io/v1alpha4"
    kind        = "Cluster"

    # Dual-stack: every pod and Service gets an IPv4 and an IPv6 address, as on Hetzner and GKE. kind's
    # own CNI (kindnet) is off - Cilium is installed below, the policy engine the clouds run too.
    # The IPv6 ranges are unique local (fd00::/8, not routed on the internet) - kind's own defaults.
    networking {
      api_server_address  = "127.0.0.1"
      api_server_port     = 6443
      kube_proxy_mode     = "iptables"
      ip_family           = "dual"
      pod_subnet          = "10.244.0.0/16,fd00:10:244::/56"
      service_subnet      = "10.96.0.0/16,fd00:10:96::/112"
      disable_default_cni = true
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

      # MinIO's PersistentVolume (flux/infrastructure/data/minio/pvc.yaml) points at this path.
      extra_mounts {
        host_path      = local.minio_data_dir
        container_path = "/var/local/minio-data"
      }
    }
  }
}

# null_resource + local-exec: run a command on your machine as part of the apply.
# Here: merge the new kubeconfig into ~/.kube/config as context kind-sre-control-plane.
# https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource
# https://developer.hashicorp.com/terraform/language/resources/provisioners/local-exec
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

# Cilium's agents rolled out and every node Ready, or the apply stops here with the nodes' and agents'
# state - not 10 minutes later in a Helm release that times out for want of a network (metrics-server
# did, 2026-10-16). The DaemonSet rollout is checked too: a node stays Ready once Cilium wrote its CNI
# config, even if a later agent (an upgrade) crash-loops. Run again for a new cluster and a new Cilium.
resource "null_resource" "wait_for_nodes" {
  depends_on = [helm_release.cilium]

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    command     = "kubectl --kubeconfig=\"${local.kubeconfig_path}\" -n kube-system rollout status ds/cilium --timeout=300s && kubectl --kubeconfig=\"${local.kubeconfig_path}\" wait --for=condition=Ready nodes --all --timeout=300s || { kubectl --kubeconfig=\"${local.kubeconfig_path}\" get nodes; kubectl --kubeconfig=\"${local.kubeconfig_path}\" -n kube-system get pods -l k8s-app=cilium; exit 1; }"
  }

  lifecycle {
    replace_triggered_by = [kind_cluster.sre, helm_release.cilium]
  }
}

# Give the API server a moment before Helm and Kubernetes resources talk to it.
# https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep
resource "time_sleep" "wait_for_cluster" {
  depends_on      = [null_resource.wait_for_nodes]
  create_duration = "30s"

  # A new kind cluster (for example a new node_image) needs this step again;
  # without it the replaced cluster came up without Flux.
  lifecycle {
    replace_triggered_by = [kind_cluster.sre]
  }
}

# Outputs: values printed after apply (terraform output). https://developer.hashicorp.com/terraform/language/values/outputs
output "kubeconfig" {
  description = "Path to the generated kubeconfig for the kind cluster"
  value       = local.kubeconfig_path
}

output "kubeconfig_load_instructions" {
  description = "How to use the generated kubeconfig"
  value       = <<-EOT
    # The kubeconfig is already merged into ~/.kube/config. Name the cluster in every
    # command instead of switching the shared current context (Chapter 01):
    kubectl --context kind-sre-control-plane get nodes
    flux --context kind-sre-control-plane get kustomizations -A
  EOT
}

# Traefik moved to Flux (flux/infrastructure/ingress/traefik; the local profile makes it a NodePort on
# 30080/30443). A cluster built before the move still has Terraform's Helm release and namespace:
# `removed` with destroy = false makes Terraform forget them without deleting anything - Flux's
# HelmRelease (same release name, same namespace) takes the release over in place, so the ingress
# never goes away. https://developer.hashicorp.com/terraform/language/resources/syntax#removing-resources
# Flux keeps its own release record in flux-system, like every HelmRelease here; Terraform's old one
# stays in traefik. Delete only that record once Flux shows the release Ready - never `helm uninstall`,
# which would remove the live ingress:
#   kubectl --context kind-sre-control-plane -n traefik delete secret -l owner=helm,name=traefik
removed {
  from = helm_release.traefik
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_namespace_v1.traefik
  lifecycle { destroy = false }
}

# Cilium: the cluster's network (CNI) and its NetworkPolicy engine, dual-stack. The values follow
# kube-hetzner's own Cilium (hcloud_cluster, cni_plugin = "cilium"), so kind proves what Hetzner runs:
# Kubernetes-assigned pod ranges of both families, tunnel (VXLAN) routing, kube-proxy kept (iptables),
# no Hubble. One operator replica: two nodes. Helm's wait does not catch a crash-looping agent (it
# returned after 3 s while every agent restarted - 2026-10-16), so null_resource.wait_for_nodes below
# waits for Ready nodes: a node is Ready only once its CNI runs.
# 1.20.3, not kube-hetzner's 1.19.3 default: Cilium before 1.19.8 does not start on Linux 7.2 (OrbStack's
# kernel; cilium/cilium#48016 - its BPF feature probe is refused by the newer verifier).
# https://docs.cilium.io/en/stable/installation/kind/
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  namespace  = "kube-system"
  version    = var.cilium_version
  wait       = true
  timeout    = 600

  depends_on = [null_resource.merge_kubeconfig]

  # A new kind cluster (a new node_image, a networking change) has no CNI: install Cilium there again,
  # or its nodes stay NotReady and nothing after this ever starts.
  lifecycle {
    replace_triggered_by = [kind_cluster.sre]
  }

  values = [yamlencode({
    ipam                 = { mode = "kubernetes" }
    k8s                  = { requireIPv4PodCIDR = true, requireIPv6PodCIDR = true }
    ipv4                 = { enabled = true }
    ipv6                 = { enabled = true }
    kubeProxyReplacement = false
    routingMode          = "tunnel"
    endpointRoutes       = { enabled = true }
    bpf                  = { masquerade = false }
    rollOutCiliumPods    = true
    operator             = { replicas = 1 }
    hubble               = { enabled = false }
    # An ipBlock matches node addresses too, as in Kubernetes' own model: Cilium leaves nodes out of CIDR
    # rules by default, and the API server runs on a node here (kind, k3s) - without this, Postgres'
    # instance manager (allow-postgres-egress-apiserver) could not reach it. cluster-conformance C3 checks.
    policyCIDRMatchMode = "nodes"
    image               = { pullPolicy = "IfNotPresent" }
  })]
}

# metrics-server: CPU and memory metrics for kubectl top and the HPA (Chapter 09).
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

# The Flux Operator, installed from its release manifest (pinned: var.flux_operator_version).
# https://fluxcd.control-plane.io/operator/
# The pinned SHA-256 of flux_operator_version's install.yaml, from scripts/flux-operator.sha256 (the one
# place for it); "" when that version has no line - the precondition below then fails the plan.
locals {
  flux_operator_manifest_sha256 = try(regex("(?m)^([0-9a-f]{64})  ${replace(var.flux_operator_version, ".", "\\.")}$", file("${path.module}/../scripts/flux-operator.sha256"))[0], "")
}

# The command and why it is a server-side apply: scripts/flux-operator-install.sh (shared by every module).
resource "null_resource" "flux_operator_install" {
  depends_on = [time_sleep.wait_for_cluster]

  # Only what the operator install depends on (as in gke and hcloud); the repository, branch and path are
  # the FluxInstance's inputs and re-create only null_resource.flux_instance below.
  triggers = {
    kubeconfig_path = local.kubeconfig_path
    # reinstall when the pinned Flux Operator release changes
    operator_version = var.flux_operator_version
    # a re-pinned manifest (same version) is installed and checked again
    manifest_sha256 = local.flux_operator_manifest_sha256
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    command     = "\"${path.module}/../scripts/flux-operator-install.sh\" \"${local.kubeconfig_path}\" \"${var.flux_operator_version}\" \"${local.flux_operator_manifest_sha256}\""
  }

  # A new kind cluster (for example a new node_image) needs this step again;
  # without it the replaced cluster came up without Flux.
  lifecycle {
    precondition {
      condition     = local.flux_operator_manifest_sha256 != ""
      error_message = "Flux Operator ${var.flux_operator_version} has no line in infra/terraform/scripts/flux-operator.sha256 - add its install.yaml SHA-256 (the file says how), then plan again."
    }
    replace_triggered_by = [kind_cluster.sre]
  }
}

# The FluxInstance: which Flux version to run, and which Git repository, branch and
# path to follow. From here on Git drives what runs in the cluster (Chapter 03).
resource "null_resource" "flux_instance" {
  # cluster-config first: the Kustomizations substitute from it (${cluster_ipv6_range} and others).
  depends_on = [
    null_resource.flux_operator_install,
    kubernetes_secret_v1.flux_git_auth,
    kubernetes_config_map_v1.cluster_config,
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

# Runs at destroy time (when = destroy): ../scripts/flux-pre-destroy.sh removes what
# Flux created in these namespaces first, so the destroy does not race a controller
# that recreates objects.
# terraform_data with `input`, not null_resource with `triggers`: the hook must run only when the
# cluster is destroyed - never because the namespace list or the kubeconfig path changed (moved below).
resource "terraform_data" "flux_pre_destroy" {
  depends_on = [
    kind_cluster.sre,
    kubernetes_namespace_v1.bootstrap,
    null_resource.flux_instance,
  ]

  input = {
    kubeconfig_path = local.kubeconfig_path
    namespaces      = "develop,staging,production,observability,traefik,minio"
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    command     = "\"${path.module}/../scripts/flux-pre-destroy.sh\" \"${self.input.kubeconfig_path}\" \"${self.input.namespaces}\""
    interpreter = ["/bin/bash", "-c"]
  }

  # A new kind cluster (for example a new node_image) needs this step again;
  # without it the replaced cluster came up without Flux.
  lifecycle {
    replace_triggered_by = [kind_cluster.sre]
  }
}

# Was a null_resource: a change of its triggers (the namespace list, the kubeconfig path) REPLACED it,
# and a replacement runs the destroy-time hook - against the live cluster, in an ordinary apply.
# terraform_data takes those values as `input`, which changes in place (found in review, 2026-10-15).
# `removed` with destroy = false, not `moved`: a move turns the old triggers into triggers_replace and
# replaces the resource - running the hook once more (kind plan, 2026-10-15). Forgetting the old one
# runs nothing; the new one does nothing on create.
removed {
  from = null_resource.flux_pre_destroy

  lifecycle {
    destroy = false
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
    # The pods' IPv6 range (networking.pod_subnet above): NetworkPolicies cut it out of ::/0 (postBuild).
    cluster_ipv6_range    = "fd00:10:244::/56"
    cluster_name          = "sre-control-plane"
    image_registry        = var.image_registry
    git_owner             = var.git_owner
    guardian_llm_provider = var.guardian_llm_provider
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
# or the state. Exception: the key generated for the local profile is read by data.local_file,
# so it IS in the (local) state - the local provider has no ephemeral file source, and the file
# only exists after the first apply. Acceptable for a throwaway dev key; use sops_age_key for a
# real one.
# Terraform re-sends a write-only value only when data_wo_revision changes. For the local profile
# the revision follows the key file: the first 8 hex digits of its SHA-256, read as a number. A new
# age.agekey (a rotation, Chapter 04) therefore reaches the cluster on the next apply, and the plan
# shows it as an in-place update of this Secret - with no number to remember, and no drift on later
# plans. For a key passed in sops_age_key, bump sops_age_key_revision after rotating it.
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
  data_wo_revision = var.sops_age_key_revision + (var.local_profile ? parseint(substr(sha256(data.local_file.age_key[0].content), 0, 8), 16) : 0)
}

# The secret used to be optional (count); keep the existing object instead of recreating it.
moved {
  from = kubernetes_secret_v1.sops_age[0]
  to   = kubernetes_secret_v1.sops_age
}

# The day and time this cluster was created, for the CNPG archive's serverName (BACKUP_CLUSTER_ID in
# the backup-s3 ConfigMap below): every new cluster writes an archive of its own, and the old one stays
# for a restore. timestamp() is read once - ignore_changes keeps it; a new cluster gets a new one.
# https://developer.hashicorp.com/terraform/language/resources/terraform-data
resource "terraform_data" "cluster_id" {
  input = formatdate("YYYYMMDD-hhmm", timestamp())
  # A replaced kind cluster (a new node image) is a new cluster: a new id.
  triggers_replace = kind_cluster.sre.id

  lifecycle {
    ignore_changes = [input]
  }
}

# Non-secret backup target for Flux. The cnpg-cluster-<env> Kustomizations read
# BACKUP_S3_ENDPOINT, BACKUP_S3_BUCKET and BACKUP_CLUSTER_ID from this ConfigMap (postBuild.substituteFrom),
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
    BACKUP_CLUSTER_ID  = terraform_data.cluster_id.output
    } : {
    BACKUP_S3_ENDPOINT = var.backup_s3_endpoint
    BACKUP_S3_BUCKET   = var.backup_s3_bucket
    BACKUP_CLUSTER_ID  = terraform_data.cluster_id.output
  }
}

# CNPG backup credentials (Hetzner Object Storage) for the full platform profile
# (local_profile = false). The local profile uses MinIO instead (local-profile.tf).
# Full platform profile only (local_profile = false; local-profile.tf seeds all three
# envs for the local profile). CNPG owner credentials for production (bootstrap.initdb.secret, and DATABASE_* of the
# backend). Generated per cluster and never written to Git - the plain Secret that used
# to live in flux/infrastructure/data/cnpg-clusters/production made the production
# database password public. develop/staging still come from SOPS (flux/secrets/<env>).
# https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password - generated once, then stable (it lives in the state).
resource "random_password" "postgres_app_production" {
  count   = var.local_profile ? 0 : 1
  length  = 32
  special = false
}

# The Guardian's Secret on kind (Chapter 14; on the platform it comes from SOPS, secrets-observability).
# internal-token: generated, guards the Guardian's HTTP API; Alertmanager sends it as a Bearer token.
# The LLM key goes under the key the Deployment reads for that provider; without one the Guardian
# still detects and tracks incidents, without the analysis.
resource "random_password" "guardian_internal_token" {
  count   = var.local_profile ? 1 : 0
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "guardian" {
  count = var.local_profile ? 1 : 0

  metadata {
    name      = "k8s-ai-monitor-secrets"
    namespace = "observability"
  }

  type = "Opaque"

  data = merge(
    { "internal-token" = random_password.guardian_internal_token[0].result },
    var.guardian_llm_api_key == "" ? {} : { "${var.guardian_llm_provider}-api-key" = var.guardian_llm_api_key },
  )

  depends_on = [kubernetes_namespace_v1.bootstrap]
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
