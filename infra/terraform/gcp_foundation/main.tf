# The Google Cloud foundation: what stays while GKE clusters come and go. Applied once, by a person,
# from a workstation (it creates the very identity CI deploys with). Nothing here costs money on its
# own: enabled APIs, service accounts, Workload Identity Federation, a notification channel and a
# budget are free; cost starts with what infra/terraform/gke_cluster creates.
#
#   identity check            only var.expected_principal may plan or apply
#   APIs                      only what the clusters need
#   gke-nodes                 the node service account - the minimum role Google documents
#   terraform-gke             the deployer CI impersonates - enough for a cluster, never owner/editor
#   Workload Identity Fed.    GitHub Actions on one repository and one ref get short-lived credentials,
#                             no service account key exists anywhere
#   alert e-mail + budget     where alerts go; a budget that warns at 50/90/100 % and on the forecast

# Fail the plan when Terraform runs as anyone else. A workstation can hold several Google identities
# (Application Default Credentials of another project, an impersonated service account); applying
# this module as the wrong one would create the deployer in the wrong place.
data "google_client_openid_userinfo" "me" {
  lifecycle {
    postcondition {
      condition     = self.email == var.expected_principal
      error_message = "Terraform authenticates as ${coalesce(self.email, "(no e-mail in the token)")}, expected ${var.expected_principal}. Point GOOGLE_APPLICATION_CREDENTIALS at that identity's ADC file (gcloud auth application-default login) or fix TF_VAR_expected_principal."
    }
  }
}

# ─── APIs ─────────────────────────────────────────────────────────────────────
# Enabling an API is free; only using it costs. disable_on_destroy = false: turning an API off can
# delete what other tools created with it - removing it from this list must never do that.
locals {
  services = [
    "billingbudgets.googleapis.com",       # the budget below
    "cloudresourcemanager.googleapis.com", # project IAM policy
    "compute.googleapis.com",              # VPC, Cloud NAT, firewall, nodes
    "container.googleapis.com",            # GKE
    "iam.googleapis.com",                  # service accounts, Workload Identity Federation
    "iamcredentials.googleapis.com",       # short-lived tokens for the impersonated deployer
    "logging.googleapis.com",              # Cloud Logging (cluster and NAT logs)
    "monitoring.googleapis.com",           # alert policies, notification channel
    "sts.googleapis.com",                  # exchanges the GitHub OIDC token for a Google token
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false

  depends_on = [data.google_client_openid_userinfo.me]
}

# Read after the APIs are on: the Resource Manager API is one of them (a fresh project has it off).
data "google_project" "this" {
  depends_on = [google_project_service.this]
}

# ─── Node service account ─────────────────────────────────────────────────────
# Every GKE node runs as this account, never as the Compute Engine default one (which has Editor on
# the project). roles/container.defaultNodeServiceAccount is Google's documented minimum: write
# logs and metrics, nothing else.
# https://docs.cloud.google.com/kubernetes-engine/security/configure-node-service-accounts
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE nodes"
  description  = "Runs the GKE nodes: logs and metrics only (roles/container.defaultNodeServiceAccount)."

  depends_on = [google_project_service.this]
}

resource "google_project_iam_member" "gke_nodes" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.gke_nodes.member
}

# ─── Deployer ─────────────────────────────────────────────────────────────────
# What the GKE workflow runs as. Enough to build a cluster and its network, nothing more: no owner or
# editor, no IAM admin (the node account above already exists), no service account keys.
resource "google_service_account" "deployer" {
  account_id   = "terraform-gke"
  display_name = "Terraform - GKE"
  description  = "Impersonated by GitHub Actions (Workload Identity Federation) to build GKE clusters."

  depends_on = [google_project_service.this]
}

locals {
  deployer_roles = [
    "roles/container.admin",                      # clusters, node pools and - for the Flux bootstrap - the Kubernetes API
    "roles/compute.networkAdmin",                 # VPC, subnet, Cloud Router, Cloud NAT
    "roles/compute.securityAdmin",                # firewall rules (admission webhooks from the control plane)
    "roles/monitoring.alertPolicyEditor",         # the Cloud NAT alert policies
    "roles/monitoring.notificationChannelViewer", # find the alert e-mail channel
  ]
}

resource "google_project_iam_member" "deployer" {
  for_each = toset(local.deployer_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.deployer.member
}

# A cluster's node pools run as gke-nodes, so the deployer must be allowed to "act as" it - on that
# one account, not on every service account in the project.
resource "google_service_account_iam_member" "deployer_uses_gke_nodes" {
  service_account_id = google_service_account.gke_nodes.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deployer.member
}

# ─── Workload Identity Federation for GitHub Actions ─────────────────────────
# GitHub signs a short-lived OIDC token for each workflow run; Google exchanges it for credentials of
# the deployer. No key is stored in GitHub. The attribute condition is the lock: only runs of one
# repository (by id - a name can be re-registered), of its owner, on one ref. A pull request's code
# never gets in. A deleted pool keeps its id for 30 days - this module is applied once, not per cycle.
# https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "Workflow runs of the platform repository."

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  # checkov:skip=CKV_GCP_125:the condition pins the repository and its owner by numeric id and the ref - stricter than the repository name Checkov looks for
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "GitHub Actions OIDC"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
    "attribute.environment"         = "assertion.environment"
  }

  attribute_condition = join(" && ", [
    "assertion.repository_id == '${var.github_repository_id}'",
    "assertion.repository_owner_id == '${var.github_repository_owner_id}'",
    "assertion.ref == '${var.github_ref}'",
  ])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "deployer_from_github" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/${var.github_repository_id}"
}

# ─── Alerts ───────────────────────────────────────────────────────────────────
# One e-mail channel for every alert of the platform's Google Cloud side (budget, Cloud NAT). The
# cluster module finds it by its display name.
resource "google_monitoring_notification_channel" "email" {
  display_name = "Platform alerts (e-mail)"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }

  depends_on = [google_project_service.this]
}

# A budget warns, it never stops spending: the alert is the signal to destroy what was forgotten.
# Billing account administrators get the e-mails too (default recipients stay on).
resource "google_billing_budget" "monthly" {
  provider = google.billing

  billing_account = var.billing_account_id
  display_name    = "${var.project_id} monthly"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      units = tostring(var.budget_amount) # in the billing account's own currency
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.id]
    disable_default_iam_recipients   = false
  }

  depends_on = [google_project_service.this]
}

# ─── Defaults Google creates with the Compute API ─────────────────────────────
# Turning on compute.googleapis.com creates, in a project without an organization policy against it:
#   1. the Compute Engine default service account, with roles/editor on the whole project;
#   2. a "default" VPC whose firewall opens SSH and RDP to the whole internet.
# Neither is used here (nodes run as gke-nodes, clusters in their own VPC), and both are what the CIS
# Google Cloud benchmark says to remove. In an organization, the policies
# iam.automaticIamGrantsForDefaultServiceAccounts and compute.skipDefaultNetworkCreation prevent them.

# Take Editor away from the default service account - and keep it away: every plan checks it.
resource "google_project_iam_member_remove" "default_compute_editor" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"

  depends_on = [google_project_service.this]
}

# Terraform did not create the default VPC, so it cannot delete it declaratively; the one-time delete
# is `make delete-default-network`. This check warns on every plan while it (or a re-created one)
# exists - a warning, not an error: the rest of the plan stays usable.
# No depends_on: in a check block it defers the read to every apply, and a plan would never come out
# clean. On a project whose Compute API is still off the read fails - in a check block that is a
# warning too, never an error.
check "no_default_network" {
  data "google_compute_networks" "all" {}

  assert {
    condition     = !contains(data.google_compute_networks.all.networks, "default")
    error_message = "The project has a \"default\" VPC (SSH and RDP open to the internet). Delete it once: make -C infra/terraform/gcp_foundation delete-default-network CONFIRM=yes"
  }
}
