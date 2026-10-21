# Flux on the GKE cluster: what Flux expects to find when it starts, then Flux itself, following the
# platform repository - from there on Git drives the cluster. The same pieces, names and order as on
# Hetzner (infra/terraform/hcloud_cluster/main.tf), so both clusters run the same platform:
#   1. namespaces, ConfigMaps,   cluster-config, cluster-secrets, backup-s3, cnpg-backup-s3, sops-age
#      Secrets                   and the production database password
#   2. flux_operator_install,    Flux, reconciling var.flux_kustomization_path (profiles/gke)
#      flux_instance
#   3. flux_pre_destroy          on destroy only: removes what Flux created - volumes and the load
#                                balancer of Traefik's Service - while the cluster still runs
# kubectl here goes through kubeconfig.yaml, so through gke-gcloud-auth-plugin and gcloud's active
# account (make preflight checks that it is var.expected_principal).

# The kubernetes provider talks to the DNS endpoint with a short-lived token of the identity Terraform
# runs as. No CA certificate: the DNS endpoint serves a publicly trusted one.
# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs
data "google_client_config" "this" {}

provider "kubernetes" {
  host  = "https://${google_container_cluster.this.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint}"
  token = data.google_client_config.this.access_token
}

locals {
  kubeconfig_path = local_file.kubeconfig.filename
  # What tells this cluster from a re-created one: every new cluster has a new certificate authority.
  # The id (projects/.../clusters/<name>) stays the same when a cluster of the same name is re-created.
  cluster_ca_hash = sha256(google_container_cluster.this.master_auth[0].cluster_ca_certificate)
  # Namespaces whose Secrets and ConfigMaps Terraform writes; Flux adds labels and annotations later.
  bootstrap_namespaces = ["flux-system", "develop", "staging", "production", "observability", "auth"]
  # What flux-pre-destroy.sh deletes before the cluster goes: the workloads' volumes (persistent disks
  # outlive a deleted cluster) and traefik - its LoadBalancer Service owns a forwarding rule, an
  # address and firewall rules that GKE deletes only with the Service.
  pre_destroy_namespaces = "flux-system,develop,staging,production,observability,traefik"
}

resource "kubernetes_namespace_v1" "bootstrap" {
  for_each = toset(local.bootstrap_namespaces)

  metadata {
    name   = each.value
    labels = { "managed-by" = "terraform" }
  }

  # Flux sets its own labels and annotations (Pod Security, environment).
  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }

  depends_on = [google_container_node_pool.platform]
}

# Read by Flux postBuild substitutions (${cluster_name} and the rest).
resource "kubernetes_config_map_v1" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = "flux-system"
  }

  data = {
    cloudflare_proxied = "enabled"
    # Names the provider in the external-dns owner ID (k8s-external-dns-<cluster_name>-<cloud_provider>).
    cloud_provider = "gke"
    # A fact about the provider (IPv6 by default: dual), never read from the setting it checks: turning
    # IPv6 off must fail conformance C13, not change the promise.
    ip_stack       = "dual"
    cluster_name   = var.cluster_name
    image_registry = var.image_registry
    git_owner      = var.git_owner
    # The subnet's global IPv6 range (EXTERNAL): nodes and Pods get their IPv6 from it - not in fc00::/7
    # here, so NetworkPolicies cut this range out of ::/0 (postBuild), as 10.0.0.0/8 out of 0.0.0.0/0.
    cluster_ipv6_range = google_compute_subnetwork.nodes.external_ipv6_prefix
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

resource "kubernetes_secret_v1" "cluster_secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = "flux-system"
  }

  type = "Opaque"
  data = { uptrace_dsn = var.uptrace_dsn }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# The age key Flux decrypts flux/secrets/** with. Write-only: sent to the cluster, never stored in
# the plan or the state; after a key rotation bump sops_age_key_revision.
resource "kubernetes_secret_v1" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  data_wo          = { "age.agekey" = var.sops_age_key }
  data_wo_revision = var.sops_age_key_revision
  type             = "Opaque"

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# When this cluster was created, for the CNPG archive's serverName (BACKUP_CLUSTER_ID): a new cluster
# writes an archive of its own. A new GKE cluster has a new id, so a new value.
resource "terraform_data" "cluster_id" {
  input            = formatdate("YYYYMMDD-hhmm", timestamp())
  triggers_replace = local.cluster_ca_hash

  lifecycle {
    ignore_changes = [input]
  }
}

resource "kubernetes_config_map_v1" "backup_s3" {
  metadata {
    name      = "backup-s3"
    namespace = "flux-system"
  }

  data = {
    BACKUP_S3_ENDPOINT = var.backup_s3_endpoint
    BACKUP_S3_BUCKET   = var.backup_s3_bucket
    BACKUP_CLUSTER_ID  = terraform_data.cluster_id.output
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# The backup bucket's keys for CloudNativePG, one Secret per environment (the ObjectStore reads them).
# https://cloudnative-pg.io/plugin-barman-cloud/
resource "kubernetes_secret_v1" "cnpg_backup_s3" {
  for_each = toset(["develop", "staging", "production"])

  metadata {
    name      = "cnpg-backup-s3"
    namespace = each.key
  }

  type = "Opaque"
  data = {
    ACCESS_KEY_ID     = var.backup_s3_access_key_id
    ACCESS_SECRET_KEY = var.backup_s3_secret_access_key
    BUCKET            = var.backup_s3_bucket
    ENDPOINT          = var.backup_s3_endpoint
    REGION            = var.backup_s3_region
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# The production database owner's password: generated per cluster, never in Git (develop and staging
# come from SOPS). CNPG adopts the Secret; Terraform only seeds it.
resource "random_password" "postgres_app_production" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "postgres_app_production" {
  metadata {
    name      = "app-postgres-app"
    namespace = "production"
    labels    = { "cnpg.io/reload" = "true" }
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = "app"
    password = random_password.postgres_app_production.result
  }

  lifecycle {
    ignore_changes = [data, metadata[0].labels, metadata[0].annotations]
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# The Flux Operator, from its release manifest (pinned).
# https://fluxcd.control-plane.io/operator/
# The pinned SHA-256 of flux_operator_version's install.yaml, from scripts/flux-operator.sha256 (the one
# place for it); "" when that version has no line - the precondition below then fails the plan.
locals {
  flux_operator_manifest_sha256 = try(regex("(?m)^([0-9a-f]{64})  ${replace(var.flux_operator_version, ".", "\\.")}$", file("${path.module}/../scripts/flux-operator.sha256"))[0], "")
}

# The command and why it is a server-side apply: scripts/flux-operator-install.sh (shared by every module).
resource "null_resource" "flux_operator_install" {
  # cluster_ca: a re-created cluster gets Flux again (the kubeconfig path alone never changes).
  triggers = {
    cluster_ca       = local.cluster_ca_hash
    kubeconfig_path  = local.kubeconfig_path
    operator_version = var.flux_operator_version
    # a re-pinned manifest (same version) is installed and checked again
    manifest_sha256 = local.flux_operator_manifest_sha256
    # the operator's memory request, set by the install script: run it again when it changes
    operator_memory = regex("memory\\) = \"([0-9]+Mi)\"", file("${path.module}/../scripts/flux-operator-install.sh"))[0]
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "\"${path.module}/../scripts/flux-operator-install.sh\" \"${local.kubeconfig_path}\" \"${var.flux_operator_version}\" \"${local.flux_operator_manifest_sha256}\""
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]

  lifecycle {
    precondition {
      condition     = local.flux_operator_manifest_sha256 != ""
      error_message = "Flux Operator ${var.flux_operator_version} has no line in infra/terraform/scripts/flux-operator.sha256 - add its install.yaml SHA-256 (the file says how), then plan again."
    }
  }
}

# The FluxInstance: Flux's version and controllers, and the repository, branch and profile to follow.
# The Secrets and ConfigMaps above exist before it, so the first reconcile finds them.
# https://fluxcd.control-plane.io/operator/fluxinstance/
resource "null_resource" "flux_instance" {
  triggers = {
    cluster_ca      = local.cluster_ca_hash
    kubeconfig_path = local.kubeconfig_path
    repo_url        = var.flux_git_repository_url
    repo_branch     = var.flux_git_repository_branch
    repo_path       = var.flux_kustomization_path
    flux_version    = var.flux_version
    # re-apply the FluxInstance when the controllers' requests change (the parsed YAML: not its comments)
    controllers_resources = sha256(jsonencode(yamldecode(file("${path.module}/../scripts/flux-controllers-resources.yaml"))))
  }

  provisioner "local-exec" {
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
        ${indent(2, chomp(file("${path.module}/../scripts/flux-controllers-resources.yaml")))}
        sync:
          kind: GitRepository
          url: "${var.flux_git_repository_url}"
          ref: "refs/heads/${var.flux_git_repository_branch}"
          provider: generic
          path: "${var.flux_kustomization_path}"
      EOF
    EOC
  }

  depends_on = [
    null_resource.flux_operator_install,
    kubernetes_config_map_v1.cluster_config,
    kubernetes_secret_v1.cluster_secrets,
    kubernetes_secret_v1.sops_age,
    kubernetes_config_map_v1.backup_s3,
    kubernetes_secret_v1.cnpg_backup_s3,
    kubernetes_secret_v1.postgres_app_production,
  ]
}

# Destroy only, before the node pools and the cluster go: ../scripts/flux-pre-destroy.sh suspends Flux
# and deletes the namespaces above with their volumes and the load balancer, while the controllers
# that clean them up still run. on_failure = continue: the destroy goes on; make leftovers, run after
# it, says loudly what was left.
# terraform_data with `input`, not null_resource with `triggers`: the hook must run only when the
# cluster is destroyed - never because the namespace list or the kubeconfig path changed (moved below).
resource "terraform_data" "flux_pre_destroy" {
  input = {
    kubeconfig_path = local.kubeconfig_path
    namespaces      = local.pre_destroy_namespaces
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = "\"${path.module}/../scripts/flux-pre-destroy.sh\" \"${self.input.kubeconfig_path}\" \"${self.input.namespaces}\""
  }

  depends_on = [
    google_container_node_pool.platform,
    google_container_node_pool.apps,
    local_file.kubeconfig,
    kubernetes_namespace_v1.bootstrap,
    null_resource.flux_instance,
  ]
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
