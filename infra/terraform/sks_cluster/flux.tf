# Flux on the SKS cluster: what Flux expects to find when it starts, then Flux itself, following the
# platform repository - from there on Git drives the cluster. The same pieces, names and order as on
# Hetzner, GKE, EKS, AKS and DOKS (infra/terraform/doks_cluster/flux.tf), so every cluster runs the same
# platform:
#   1. namespaces, ConfigMaps,   cluster-config, cluster-secrets, backup-s3, cnpg-backup-s3, sops-age
#      Secrets, StorageClass     and the production database password; the default StorageClass sbs
#   2. flux_operator_install,    Flux, reconciling var.flux_kustomization_path (profiles/sks)
#      flux_instance
#   3. flux_pre_destroy          on destroy only: removes what Flux created - volumes and the load
#                                balancer of Traefik's Service, which outlive a deleted cluster on
#                                Exoscale - while the cluster, its CSI driver and cloud controller run
# The kubernetes provider is configured in versions.tf; kubectl here goes through kubeconfig.yaml, so
# through exo and the same API key as Terraform (the plan's identity check covers both).

locals {
  # A fact about the provider, never read from a setting: SKS gives pods and Services no IPv6, and its
  # cloud controller gives the load balancer none
  # (docs/providers.md). cluster-config carries it, and the Services' family policy derived from it.
  ip_stack        = "ipv4"
  kubeconfig_path = local_file.kubeconfig.filename
  # What tells this cluster from a re-created one: every new cluster has a new certificate authority.
  cluster_ca_hash = sha256(exoscale_sks_cluster.this.control_plane_ca)
  # Namespaces whose Secrets and ConfigMaps Terraform writes; Flux adds labels and annotations later.
  bootstrap_namespaces = ["flux-system", "develop", "staging", "production", "observability", "auth"]
  # What flux-pre-destroy.sh deletes before the cluster goes: the workloads' volumes and traefik - its
  # LoadBalancer Service owns an Exoscale network load balancer. Both outlive a deleted cluster and stay
  # billed, and a DNS record external-dns wrote stays unless it is deleted while the cluster runs.
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

  depends_on = [exoscale_sks_nodepool.platform, exoscale_sks_nodepool.apps]
}

# The API server's real port, read from the cluster: Postgres reaches it through the Service kubernetes
# (10.96.0.1:443), and Cilium checks the NetworkPolicy against the address behind it. On SKS that is a port
# of Exoscale's own (31101 on the first cycle, 2026-10-24), not the 443 or 6443 every other cluster uses, and
# allow-postgres-egress-apiserver dropped CloudNativePG's calls - no database. Exoscale publishes the port
# nowhere else (exoscale_sks_cluster.endpoint is a name on 443). Read at apply: a port Exoscale changes later
# (a control plane upgrade) needs another apply - until then CloudNativePG fails loudly and conformance C3
# names the port.
data "kubernetes_endpoint_slice_v1" "api_server" {
  metadata {
    name      = "kubernetes"
    namespace = "default"
  }

  lifecycle {
    postcondition {
      condition     = length(self.port) == 1
      error_message = "The EndpointSlice default/kubernetes has ${length(self.port)} ports, expected the API server's one."
    }
  }

  depends_on = [exoscale_sks_nodepool.platform, exoscale_sks_nodepool.apps]
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
    cloud_provider = "sks"
    # IPv4 only (local.ip_stack) - conformance C13 checks this promise.
    ip_stack = local.ip_stack
    # The apps' and Traefik's Services take the one family there is instead of requiring two
    # (flux/apps/*/base/service.yaml, flux/infrastructure/ingress/traefik) - derived from ip_stack, so the
    # two never disagree; conformance C13 fails a dual-stack cluster whose Services ask for less.
    service_ip_family_policy = local.ip_stack == "dual" ? "RequireDualStack" : "PreferDualStack"
    cluster_name             = var.cluster_name
    image_registry           = var.image_registry
    git_owner                = var.git_owner
    # Pods have no IPv6 here, so there is no pod range to cut out of ::/0 (allow-backend-egress-https).
    # The rule still needs a value: a unique local range, already inside its fc00::/7 exception (as on EKS).
    cluster_ipv6_range = "fd00::/8"
    # The API server's port behind the Service kubernetes (data.kubernetes_endpoint_slice_v1.api_server),
    # opened to Postgres by allow-postgres-egress-apiserver.
    api_server_port = data.kubernetes_endpoint_slice_v1.api_server.port[0].port
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
# writes an archive of its own. A new SKS cluster has a new certificate authority, so a new value.
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

# The default StorageClass: Exoscale Block Storage through the CSI driver. The driver's own class
# (exoscale-sbs) is not marked default and binds a volume before the pod is scheduled; this one waits for
# the pod (WaitForFirstConsumer). No volume expansion: Exoscale resizes a volume only while it is detached,
# so a resize of a disk in use would hang - conformance C4 then skips the expansion check, with the reason.
# https://github.com/exoscale/exoscale-csi-driver
resource "kubernetes_storage_class_v1" "sbs" {
  metadata {
    name = "sbs"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "csi.exoscale.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Delete"
  allow_volume_expansion = false

  depends_on = [exoscale_sks_nodepool.platform, exoscale_sks_nodepool.apps]
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
    kubernetes_storage_class_v1.sbs,
    exoscale_sks_nodepool.platform,
    exoscale_sks_nodepool.apps,
  ]
}

# Destroy only, before the node pools and the cluster go: ../scripts/flux-pre-destroy.sh suspends Flux
# and deletes the namespaces above with their volumes and Traefik's load balancer Service, while the
# controllers that clean them up still run - the Exoscale CSI driver and cloud controller included
# (both part of the cluster, destroyed after this hook). on_failure = continue: the destroy goes on;
# make leftovers, run after it, says loudly what was left.
# terraform_data with `input`: the hook runs only when the cluster is destroyed, never because the
# namespace list or the kubeconfig path changed (see gke_cluster/flux.tf).
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
    exoscale_sks_cluster.this,
    exoscale_sks_nodepool.platform,
    exoscale_sks_nodepool.apps,
    exoscale_security_group.nodes,
    local_file.kubeconfig,
    kubernetes_namespace_v1.bootstrap,
    null_resource.flux_instance,
  ]
}
