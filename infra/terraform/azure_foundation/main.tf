# The Azure foundation: what stays while AKS clusters come and go. Applied once, by a person, from a
# workstation (it creates the very identity CI deploys with). Nothing here costs money on its own:
# resource provider registrations, empty resource groups, a managed identity with a federated credential,
# role assignments and a budget are free; cost starts with what infra/terraform/aks_cluster creates.
#
#   identity check        only var.expected_principal_object_id may plan or apply
#   resource providers    only what the clusters need (versions.tf)
#   cluster group         <cluster_name>-aks: the one resource group a cluster is built in - the deployer's
#                         rights and the person's Kubernetes admin role are scoped to it
#   GitHub deployer       GitHub Actions of one repository on one ref get short-lived tokens of a
#                         user-assigned managed identity in <cluster_name>-ci, a group it has no rights
#                         on; no client secret exists anywhere
#   budget                warns at 50/90/100 % of spend and at 100 % of the forecast
# Azure creates no default network in a subscription (unlike AWS's default VPC and Google's "default"
# network), so there is nothing to delete here.

# Fail the plan when Terraform runs as anyone else. The provider already pins the tenant and the
# subscription; this pins the person - `az login` can hold several accounts.
data "azurerm_client_config" "me" {
  lifecycle {
    postcondition {
      condition     = self.object_id == var.expected_principal_object_id
      error_message = "Terraform authenticates as object id ${self.object_id}, expected ${var.expected_principal_object_id}. Sign in as that identity (az login, with AZURE_CONFIG_DIR from .env.azure) or fix TF_VAR_expected_principal_object_id."
    }
  }
}

# ─── The cluster's resource group ─────────────────────────────────────────────
# Made here, not by the cluster module: every role below is scoped to it, so the deployer can build and
# delete a cluster in this one group and nothing else in the subscription. Empty between cycles (free).
# AKS puts the nodes, disks, load balancer and public IPs in a second group it manages itself
# (<cluster_name>-aks-nodes, aks_cluster/main.tf) and deletes it with the cluster.
resource "azurerm_resource_group" "aks" {
  name     = "${var.cluster_name}-aks"
  location = var.location

  depends_on = [data.azurerm_client_config.me]
}

# Kubernetes admin of every cluster in the group, for the person. With Azure RBAC for Kubernetes (the
# cluster has no local accounts), owning the subscription gives no access to the Kubernetes API - that
# takes a data-plane role. Scoped to the group, so it exists before a cycle creates the cluster:
# Terraform's own Flux bootstrap never waits for a fresh assignment to propagate.
# https://learn.microsoft.com/azure/aks/manage-azure-rbac
resource "azurerm_role_assignment" "person_cluster_admin" {
  scope                = azurerm_resource_group.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.expected_principal_object_id
}

# ─── GitHub Actions: the deployer ─────────────────────────────────────────────
# GitHub signs a short-lived OIDC token for each workflow run; Microsoft Entra exchanges it for a token of
# this managed identity, because the federated credential below trusts exactly that issuer, audience and
# subject. No secret is stored in GitHub.
# The subject is the whole lock - Azure matches it exactly and checks no other claim. It carries the
# repository's name (repo:OWNER/REPO:ref:REF), unlike the AWS and Google locks, which use the numeric
# repository id: keep the repository's name, or a deleted repository's name taken by someone else would
# match. A pull request's code never matches (its subject is repo:OWNER/REPO:pull_request). A job with an
# approval `environment:` gets the subject repo:OWNER/REPO:environment:NAME instead and needs a credential
# of its own.
# https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity
# The identity lives in a group of its own, where it has no rights: in the cluster's group its Contributor
# role would let a workflow run add a federated credential to itself (another subject, another issuer) -
# a door for anyone, for good - or delete itself.
resource "azurerm_resource_group" "ci" {
  name     = "${var.cluster_name}-ci"
  location = var.location

  depends_on = [data.azurerm_client_config.me]
}

resource "azurerm_user_assigned_identity" "deployer" {
  name                = "terraform-aks"
  location            = var.location
  resource_group_name = azurerm_resource_group.ci.name
}

resource "azurerm_federated_identity_credential" "github" {
  name                      = "github-${replace(var.github_ref, "/", "-")}"
  user_assigned_identity_id = azurerm_user_assigned_identity.deployer.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:${var.github_repository}:ref:${var.github_ref}"
}

# What the AKS workflow runs as: Contributor on the cluster's group - the cluster, its node pools and
# its Log Analytics workspace - and Kubernetes admin there for the Flux bootstrap. Contributor cannot
# assign roles (Microsoft.Authorization writes are excluded), and the identity itself is in another group
# (above), so a workflow run cannot grant itself more than this file does; it holds no rights anywhere else
# in the subscription. It can delete the cluster's group, with the person's role in it - a later apply of
# this module puts both back.
resource "azurerm_role_assignment" "deployer" {
  for_each = toset([
    "Contributor",
    "Azure Kubernetes Service RBAC Cluster Admin",
  ])

  scope                = azurerm_resource_group.aks.id
  role_definition_name = each.value
  principal_id         = azurerm_user_assigned_identity.deployer.principal_id
  principal_type       = "ServicePrincipal"
}

# ─── Budget ───────────────────────────────────────────────────────────────────
# A budget warns, it never stops spending: the alert is the signal to destroy what was forgotten. The
# amount fits test cycles - create, check, destroy - not a cluster left running (~$6 a day). A new
# subscription can take up to 48 hours before budgets can be created: if the apply fails here, apply again later.
resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "monthly"
  subscription_id = "/subscriptions/${var.subscription_id}"
  amount          = var.budget_amount
  time_grain      = "Monthly"

  # A budget starts on the first day of a month, not in the past; once created it runs on, so a later
  # month's plan does not move it.
  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", plantimestamp())
  }

  dynamic "notification" {
    for_each = [
      { type = "Actual", percent = 50 },
      { type = "Actual", percent = 90 },
      { type = "Actual", percent = 100 },
      { type = "Forecasted", percent = 100 },
    ]
    content {
      operator       = "GreaterThan"
      threshold      = notification.value.percent
      threshold_type = notification.value.type
      contact_emails = [var.alert_email]
    }
  }

  lifecycle {
    ignore_changes = [time_period]
  }

  depends_on = [data.azurerm_client_config.me]
}
