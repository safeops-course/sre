# Inputs of the Azure foundation. Values that identify a person, a tenant or a subscription have no default
# and are not in terraform.tfvars (the repository is public): set them as TF_VAR_* in the environment (the
# owner keeps them in .env.azure).

variable "location" {
  description = "The Azure region the clusters run in; the cluster's resource group and the deployer identity live here."
  type        = string
}

variable "subscription_id" {
  description = "The Azure subscription that holds the platform (a GUID). Every call goes to it. Set TF_VAR_subscription_id."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.subscription_id))
    error_message = "subscription_id must be the subscription's GUID (az account show --query id -o tsv)."
  }
}

variable "tenant_id" {
  description = "The Microsoft Entra tenant of the subscription (a GUID). Set TF_VAR_tenant_id."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.tenant_id))
    error_message = "tenant_id must be the tenant's GUID (az account show --query tenantId -o tsv)."
  }
}

variable "expected_principal_object_id" {
  description = "Object id of the identity that may run this module - a person signed in with `az login`. Any other identity fails the plan: a workstation can be signed in to several tenants. It also becomes the clusters' Kubernetes admin. Set TF_VAR_expected_principal_object_id (az ad signed-in-user show --query id -o tsv)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.expected_principal_object_id))
    error_message = "expected_principal_object_id must be an object id GUID (az ad signed-in-user show --query id -o tsv)."
  }
}

variable "alert_email" {
  description = "Where the budget alerts go. Set TF_VAR_alert_email."
  type        = string
  sensitive   = true
}

variable "budget_amount" {
  description = "Monthly cost budget of the subscription, in its billing currency. Alerts at 50, 90 and 100 percent of actual spend and at 100 percent of the forecast. A budget only alerts - it never stops spending."
  type        = number

  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount is ${var.budget_amount}; use an amount above 0."
  }
}

variable "cluster_name" {
  description = "Name of the AKS cluster. Its resource group is <cluster_name>-aks, made here so the deployer's rights end at that one group."
  type        = string
}

variable "github_repository" {
  description = "OWNER/REPO whose workflows may deploy - part of the federated credential's subject."
  type        = string
}

variable "github_ref" {
  description = "The only Git ref whose workflow runs get Azure tokens (refs/heads/main). Pull request code never does."
  type        = string
}
