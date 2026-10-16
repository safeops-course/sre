# Hetzner k3s cluster of the SafeOps platform - Chapter 02 explains it, read-only.
# Creating it costs money; the course runs it on kind (../kind_cluster).
#
# What this file creates. Terraform works out the order from the references between
# resources (module.kube_hetzner.kubeconfig_data in a provider block, depends_on):
#   1. module.kube_hetzner           servers, private network, firewall, load balancer, k3s on every node
#   2. local_sensitive_file          the kubeconfig, written next to the module (kubeconfig.yaml)
#   3. namespaces, ConfigMaps,       what Flux expects to find when it starts deploying:
#      Secrets                       cluster-config, backup-s3, sops-age, the production DB password
#   4. flux_operator_install,        Flux, following the platform repository - from here on Git
#      flux_instance                 drives the cluster
#   5. flux_pre_destroy              on destroy only: removes what Flux created before the nodes go
# backend.tf says where the state lives (Cloudflare R2), versions.tf the provider versions,
# variables.tf the inputs.
#
# Run it through the guard - plan, read, apply that plan: make hcloud-plan, then make hcloud-apply.
# Terraform language: https://developer.hashicorp.com/terraform/language

# hcloud provider - talks to the Hetzner Cloud API with the project token.
# https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs
provider "hcloud" {
  token = var.hcloud_token
}

# ─── Pool & feature construction ─────────────────────────────────────────────
# Values computed once and handed to the module below; a "x ? a : b" picks one shape or the other.
# https://developer.hashicorp.com/terraform/language/values/locals
# https://developer.hashicorp.com/terraform/language/expressions/conditionals

locals {
  # Every node has a public IPv6 (kube-hetzner's default, enable_public_ipv6 = true): dual-stack needs it -
  # Hetzner networks are IPv4-only, so a node's IPv6 is its public one. (A `disable_ipv6` line here was the
  # v2 field: v3 has no such field, Terraform dropped it silently, and the nodes had IPv6 all along.)
  # Control plane — always one pool.
  control_plane_nodepools = [
    {
      name        = "cp"
      server_type = var.control_plane_server_type
      location    = var.location
      labels      = ["project=sre", "managed-by=terraform"]
      taints      = []
      count       = var.control_plane_count
    },
  ]

  # Static workers — used when autoscaling is OFF.
  # When autoscaling is ON the workers pool moves to autoscaler_nodepools.
  static_agent_pools = var.autoscaling_enabled ? [] : [
    {
      name        = "workers"
      server_type = var.workers_server_type
      location    = var.location
      labels      = ["role=workers", "project=sre", "managed-by=terraform"]
      taints      = []
      count       = var.workers_count
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

  # Kured options — only populated when enabled. Kured reboots a node after an OS update, one node
  # at a time, inside this window. https://kured.dev/docs/ Off on this platform (see variables.tf).
  kured_options = var.kured_enabled ? {
    "reboot-days" = var.kured_reboot_days
    "start-time"  = var.kured_start_time
    "end-time"    = var.kured_end_time
  } : {}

  # etcd S3 backup — the same Hetzner Object Storage bucket and key as the CNPG backups (BACKUP_S3).
  # k3s expects a bare hostname (no https:// prefix). https://docs.k3s.io/cli/etcd-snapshot
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

# kube-hetzner: a community module that builds a k3s cluster on Hetzner Cloud - servers on
# openSUSE MicroOS, network, firewall, load balancer, k3s installed over SSH. A module is a
# packaged set of resources with its own inputs; pinned to one version, so an upgrade is a PR.
# https://registry.terraform.io/modules/kube-hetzner/kube-hetzner/hcloud/latest
# https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner
# https://developer.hashicorp.com/terraform/language/modules
module "kube_hetzner" {
  source  = "kube-hetzner/kube-hetzner/hcloud"
  version = "3.2.1"
  providers = {
    hcloud = hcloud
  }

  # Core
  hcloud_token   = var.hcloud_token
  cluster_name   = var.cluster_name
  ssh_public_key = var.ssh_public_key
  # null = kube-hetzner signs in through ssh-agent (the key matching ssh_public_key). A private key
  # passed as a variable would land in the saved plan and in the state (terraform_data inputs).
  ssh_private_key = null

  # Node pools
  control_plane_nodepools           = local.control_plane_nodepools
  agent_nodepools                   = local.static_agent_pools
  autoscaler_nodepools              = local.autoscaler_nodepools
  allow_scheduling_on_control_plane = var.allow_scheduling_on_control_plane

  # Load balancer
  load_balancer_type        = var.load_balancer_type
  load_balancer_location    = var.location
  load_balancer_enable_ipv6 = true

  # Node-to-node IPv6 for Cilium's health check. Hetzner's private network carries IPv4 only, so a node's
  # IPv6 address is its public one, and kube-hetzner's firewall dropped what one node sent to another
  # there: Cilium reported "1/2 reachable" for ever (2026-10-16; pods are not affected - Cilium tunnels both
  # families over the private IPv4 network). Opened: only the health check (TCP 4240) and ping (ICMP, also
  # ICMPv6), only from Hetzner's IPv6 range of the location - not from the internet. The nodes' own /128s
  # would be tighter but are known only after the servers exist (a dependency cycle), and a separate
  # firewall is detached again by kube-hetzner's servers (they set firewall_ids) on every apply.
  # https://docs.cilium.io/en/stable/operations/system_requirements/#firewall-rules
  extra_firewall_rules = [
    {
      description = "Cilium health check between the nodes over IPv6"
      direction   = "in"
      protocol    = "tcp"
      port        = "4240"
      source_ips  = [local.hetzner_ipv6_range[var.location]]
    },
    {
      description = "Ping between the nodes over IPv6 (Cilium health)"
      direction   = "in"
      protocol    = "icmp"
      port        = ""
      source_ips  = [local.hetzner_ipv6_range[var.location]]
    },
  ]

  # Ingress: Traefik comes from Flux (flux/infrastructure/ingress/traefik), as on every cluster.
  # "custom" = the module installs no ingress controller but still creates the load balancer
  # (<cluster_name>-custom, on the private network) and deletes it on destroy - the billed resource
  # stays in Terraform's state. Traefik's Service takes it over by name (cluster-config below).
  ingress_controller = "custom"

  # Network: Cilium, dual-stack - every pod and Service gets an IPv4 and an IPv6 address, as on kind and
  # GKE. kube-hetzner supports IPv6 cluster ranges with Cilium only (validation-contract.tf), so Cilium is
  # the CNI and the NetworkPolicy engine (k3s's own policy controller is then off). The IPv6 ranges are a
  # random unique local prefix (fdf9:a717:c7cc::/48, RFC 4193 - pods :/56, Services :100::/112): not routed on the internet, so pod and
  # Service addresses fall in fc00::/7, which the egress NetworkPolicies cut out like 10.0.0.0/8. Pod
  # traffic between nodes stays in Cilium's tunnel over the private IPv4 network. A fresh cluster only:
  # k3s cannot add IPv6 to a running IPv4 cluster. The IPv4 ranges stay kube-hetzner's defaults.
  cni_plugin = "cilium"
  # Pinned here, not left to the module's default: the same version as kind (kind_cluster cilium_version),
  # so a kube-hetzner upgrade cannot move Hetzner to another Cilium unnoticed.
  cilium_version    = "1.20.3"
  cluster_ipv6_cidr = "fdf9:a717:c7cc::/56"
  service_ipv6_cidr = "fdf9:a717:c7cc:100::/112"
  # An ipBlock matches node addresses too, as in Kubernetes' own model: Cilium leaves nodes out of CIDR
  # rules by default, and k3s's API server runs on a node - without this, Postgres' instance manager
  # (allow-postgres-egress-apiserver) could not reach it. The same value as kind's Cilium; conformance C3.
  cilium_merge_values = <<-EOT
    policyCIDRMatchMode: nodes
  EOT

  # K3s versioning
  k3s_channel                      = var.k3s_channel
  k3s_version                      = var.k3s_version
  automatically_upgrade_kubernetes = var.auto_upgrade_k3s
  automatically_upgrade_os         = var.auto_upgrade_os
  system_upgrade_enable_eviction   = var.k3s_upgrade_eviction

  # cert-manager is managed by Flux, not kube-hetzner
  enable_cert_manager = false

  # Kured: deployed only when enabled. The module deploys it by default (enable_kured = true) -
  # without this line kured_enabled = false would still leave kured running.
  enable_kured  = var.kured_enabled
  kured_options = local.kured_options

  # etcd backup to Hetzner Object Storage
  etcd_s3_backup = local.etcd_s3_backup

  # OIDC (Dex) for kubectl and Headlamp - applied in place (k3s restart, no node recreation)
  authentication_config = local.oidc_authentication_config

  # Extra k3s server flags (escape hatch; OIDC goes through authentication_config above)
  control_plane_exec_args = var.k3s_exec_server_args
}

# More computed values: the OIDC config for the API server and the kubeconfig with a clear name.
locals {
  # Structured authentication (not --oidc-* flags): one issuer can accept several audiences, so
  # both Dex clients work - "kubernetes" (kubectl oidc-login) and "headlamp" (Headlamp's own login).
  # Claims map 1:1 to RBAC: users by email, groups = GitHub teams as "org:team"
  # (safeops-course:members, safeops-course:admins - Dex never sends the bare org).
  # https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-authentication-configuration
  oidc_authentication_config = var.oidc_issuer_url == "" ? "" : yamlencode({
    apiVersion = "apiserver.config.k8s.io/v1"
    kind       = "AuthenticationConfiguration"
    jwt = [{
      issuer = {
        url                 = var.oidc_issuer_url
        audiences           = var.oidc_audiences
        audienceMatchPolicy = "MatchAny"
      }
      claimMappings = {
        username = { claim = "email", prefix = "" }
        groups   = { claim = "groups", prefix = "" }
      }
    }]
  })

  # Hetzner's IPv6 range for the servers of each location (Germany 2a01:4f8::/32, Finland 2a01:4f9::/32):
  # the source of the nodes' Cilium health rules above. variables.tf allows only these locations.
  hetzner_ipv6_range = {
    fsn1 = "2a01:4f8::/32"
    nbg1 = "2a01:4f8::/32"
    hel1 = "2a01:4f9::/32"
  }

  kubeconfig_path = pathexpand("${path.module}/kubeconfig.yaml")

  # kube-hetzner names the kubeconfig context after cluster_name ("sre") - too generic next to other
  # clusters in a merged kubeconfig. Rename only the context (cluster/user names, server and certs stay),
  # so it reads like kind's "kind-sre-control-plane". cluster_name itself must not change: it also names
  # the servers, the etcd snapshot folder and the external-dns owner ID (with cloud_provider).
  # https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
  kubeconfig_context = "hetzner-${var.cluster_name}-control-plane"
  kubeconfig_parsed  = yamldecode(module.kube_hetzner.kubeconfig)
  kubeconfig_named = yamlencode(merge(local.kubeconfig_parsed, {
    contexts          = [for c in local.kubeconfig_parsed.contexts : merge(c, { name = local.kubeconfig_context })]
    "current-context" = local.kubeconfig_context
  }))

  # Render pullSecret only when a token is provided.
  flux_pull_secret_yaml = var.flux_git_token != "" ? "    pullSecret: flux-system\n" : ""

  flux_git_secret_enabled = var.flux_git_token != ""
  backup_s3_secret_enabled = nonsensitive(
    var.backup_s3_access_key_id != "" &&
    var.backup_s3_secret_access_key != "" &&
    var.backup_s3_bucket != ""
  )
}

# The kubeconfig on disk, readable only by you (0600). It holds the cluster's admin
# certificate - the break-glass access - and is git-ignored.
# https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/sensitive_file
resource "local_sensitive_file" "kubeconfig" {
  content         = local.kubeconfig_named
  filename        = local.kubeconfig_path
  file_permission = "0600"
}

# Helm and Kubernetes providers, configured from the module's outputs: they always talk to
# this cluster, never to your current kubectl context.
# https://registry.terraform.io/providers/hashicorp/helm/latest/docs
provider "helm" {
  kubernetes = {
    host                   = module.kube_hetzner.kubeconfig_data.host
    client_certificate     = module.kube_hetzner.kubeconfig_data.client_certificate
    client_key             = module.kube_hetzner.kubeconfig_data.client_key
    cluster_ca_certificate = module.kube_hetzner.kubeconfig_data.cluster_ca_certificate
  }
}

# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs
provider "kubernetes" {
  host                   = module.kube_hetzner.kubeconfig_data.host
  client_certificate     = module.kube_hetzner.kubeconfig_data.client_certificate
  client_key             = module.kube_hetzner.kubeconfig_data.client_key
  cluster_ca_certificate = module.kube_hetzner.kubeconfig_data.cluster_ca_certificate
}

# The namespaces the Secrets and ConfigMaps below go into - they must exist before Flux starts.
# for_each makes one namespace per name; ignore_changes leaves labels and annotations to Flux,
# which sets its own (Pod Security, environment) - Terraform would otherwise remove them on every apply.
# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1
# https://developer.hashicorp.com/terraform/language/meta-arguments/for_each
# https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle
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

# Cluster-level config consumed by Flux postBuild substitutions: ${cluster_name} in a manifest
# becomes the value from here. https://fluxcd.io/flux/components/kustomize/kustomizations/#post-build-variable-substitution
# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1
resource "kubernetes_config_map_v1" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = "flux-system"
  }

  data = {
    cloudflare_proxied = "enabled"
    # Names the provider in the external-dns owner ID (k8s-external-dns-<cluster_name>-<cloud_provider>).
    cloud_provider = "hetzner"
    cluster_name   = var.cluster_name
    # The pods' IPv6 range (cluster_ipv6_cidr): NetworkPolicies cut it out of ::/0 (postBuild).
    cluster_ipv6_range = "fdf9:a717:c7cc::/56"
    image_registry     = var.image_registry
    git_owner          = var.git_owner
    # The load balancer kube-hetzner creates for ingress_controller = "custom" (its name is
    # "<cluster_name>-<ingress_controller>"); Traefik's Service annotations name it.
    ingress_lb_name     = "${var.cluster_name}-custom"
    ingress_lb_location = var.location
    ingress_lb_type     = var.load_balancer_type
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# Sensitive config consumed by Flux postBuild substitutions (via substituteFrom Secret).
# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1
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

# Optional: credentials for syncing a private Git repository over HTTPS. count = 0 creates
# nothing, so with an empty token there is no Secret. https://developer.hashicorp.com/terraform/language/meta-arguments/count
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

# Flux Operator - installs and upgrades Flux from one FluxInstance object. A null_resource
# owns no real object: it only runs the command (local-exec) on create; triggers decide when
# it runs again. https://fluxcd.control-plane.io/operator/
# https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource
# https://developer.hashicorp.com/terraform/language/resources/provisioners/local-exec
# The pinned SHA-256 of flux_operator_version's install.yaml, from scripts/flux-operator.sha256 (the one
# place for it); "" when that version has no line - the precondition below then fails the plan.
locals {
  flux_operator_manifest_sha256 = try(regex("(?m)^([0-9a-f]{64})  ${replace(var.flux_operator_version, ".", "\\.")}$", file("${path.module}/../scripts/flux-operator.sha256"))[0], "")
}

# The command and why it is a server-side apply: scripts/flux-operator-install.sh (shared by every module).
resource "null_resource" "flux_operator_install" {
  depends_on = [kubernetes_namespace_v1.bootstrap]

  # operator_version: a new pinned release is installed on the next apply.
  triggers = {
    kubeconfig_path  = local.kubeconfig_path
    operator_version = var.flux_operator_version
    # a re-pinned manifest (same version) is installed and checked again
    manifest_sha256 = local.flux_operator_manifest_sha256
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    command     = "\"${path.module}/../scripts/flux-operator-install.sh\" \"${local.kubeconfig_path}\" \"${var.flux_operator_version}\" \"${local.flux_operator_manifest_sha256}\""
  }

  lifecycle {
    precondition {
      condition     = local.flux_operator_manifest_sha256 != ""
      error_message = "Flux Operator ${var.flux_operator_version} has no line in infra/terraform/scripts/flux-operator.sha256 - add its install.yaml SHA-256 (the file says how), then plan again."
    }
  }
}

# The FluxInstance: which Flux version and controllers to run, and which Git repository,
# branch and path to follow. A change of any trigger re-applies it.
# https://fluxcd.control-plane.io/operator/fluxinstance/
resource "null_resource" "flux_instance" {
  # cluster-config first: the Kustomizations substitute from it (${cluster_ipv6_range} and others).
  depends_on = [
    null_resource.flux_operator_install,
    kubernetes_secret_v1.flux_git_credentials,
    kubernetes_config_map_v1.cluster_config,
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

# Runs only on destroy (when = destroy): ../scripts/flux-pre-destroy.sh suspends Flux and deletes
# the workloads and volumes while the cluster still works - volumes left behind stay billed.
# on_failure = continue: the destroy goes on, the script's log is the only warning.
# terraform_data with `input`, not null_resource with `triggers`: the hook must run only when the
# cluster is destroyed - never because the namespace list or the kubeconfig path changed (moved below).
resource "terraform_data" "flux_pre_destroy" {
  # module.kube_hetzner: destroy runs this hook before ANY node is removed. Without it a plain
  # `terraform destroy` deleted the workers in parallel - Kyverno, the Flux controllers and the CSI
  # driver died with them, and the namespaces and volumes could no longer be cleaned up.
  depends_on = [
    module.kube_hetzner,
    local_sensitive_file.kubeconfig,
    kubernetes_namespace_v1.bootstrap,
    null_resource.flux_instance,
  ]

  input = {
    kubeconfig_path = local.kubeconfig_path
    namespaces      = "flux-system,develop,staging,production,observability"
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = "\"${path.module}/../scripts/flux-pre-destroy.sh\" \"${self.input.kubeconfig_path}\" \"${self.input.namespaces}\""
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

# Optional: GHCR imagePullSecret in every namespace used by workloads - only needed while
# the images are private. https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
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

# age private key for Flux SOPS decryption. Write-only (data_wo): the key is sent to the cluster
# but never stored in the plan or the state. Terraform cannot see a change in a write-only value,
# so after a key rotation bump sops_age_key_revision.
# https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only
# https://fluxcd.io/flux/guides/mozilla-sops/
resource "kubernetes_secret_v1" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  data_wo = {
    "age.agekey" = var.sops_age_key
  }
  data_wo_revision = var.sops_age_key_revision

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# The day and time this cluster was created, for the CNPG archive's serverName (BACKUP_CLUSTER_ID in
# the backup-s3 ConfigMap below): every new cluster writes an archive of its own, and the old one stays
# for a restore. timestamp() is read once - ignore_changes keeps it; a new cluster gets a new one.
# https://developer.hashicorp.com/terraform/language/resources/terraform-data
resource "terraform_data" "cluster_id" {
  input = formatdate("YYYYMMDD-hhmm", timestamp())
  # A new k3s cluster has a new certificate authority: a new id, even if the state was kept. Ordinary
  # applies (a resized server, a new chart) keep the CA and the id.
  triggers_replace = sha256(module.kube_hetzner.kubeconfig_data.cluster_ca_certificate)

  lifecycle {
    ignore_changes = [input]
  }
}

# Non-secret backup target for Flux. The cnpg-cluster-<env> Kustomizations read
# BACKUP_S3_ENDPOINT, BACKUP_S3_BUCKET and BACKUP_CLUSTER_ID from this ConfigMap (postBuild.substituteFrom),
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
    BACKUP_CLUSTER_ID  = terraform_data.cluster_id.output
  }

  depends_on = [kubernetes_namespace_v1.bootstrap]
}

# CNPG owner credentials for production (bootstrap.initdb.secret, and DATABASE_* of the
# backend). Generated per cluster and never written to Git - the plain Secret that used
# to live in flux/infrastructure/data/cnpg-clusters/production made the production
# database password public. develop/staging still come from SOPS (flux/secrets/<env>).
# random_password is generated once and then stable - it lives in the state, so the state
# itself is a secret.
# https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password
# https://cloudnative-pg.io/documentation/current/bootstrap/
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

# Optional: backup object-store credentials for CloudNativePG, one per environment - only when
# the BACKUP_S3 keys are set. https://cloudnative-pg.io/documentation/current/backup/
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

# The secret used to be optional (count); keep the existing object instead of recreating it.
# A moved block renames an address in the state; without it Terraform would destroy and create.
# https://developer.hashicorp.com/terraform/language/modules/develop/refactoring
moved {
  from = kubernetes_secret_v1.sops_age[0]
  to   = kubernetes_secret_v1.sops_age
}
