# Inputs of the Google Cloud foundation. Values that identify a person or a billing account have no
# default and are not in terraform.tfvars (the repository is public): set them as TF_VAR_* in the
# environment (the owner keeps them in a local env file).

variable "project_id" {
  description = "The Google Cloud project that holds the platform (it must exist, with billing enabled)."
  type        = string
}

variable "region" {
  description = "Default region for regional resources."
  type        = string
}

variable "expected_principal" {
  description = "The identity that may run this module (the e-mail of the user or service account Terraform authenticates as). Any other identity fails the plan - a workstation with several Google identities must not apply into the wrong one. Set TF_VAR_expected_principal."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account of the project (XXXXXX-XXXXXX-XXXXXX), for the budget. Set TF_VAR_billing_account_id."
  type        = string
}

variable "alert_email" {
  description = "Where budget and platform alerts go (a Cloud Monitoring e-mail channel). Set TF_VAR_alert_email."
  type        = string
}

variable "budget_amount" {
  description = "Monthly budget, in the billing account's own currency. Alerts at 50, 90 and 100 percent of actual spend and at 100 percent of the forecast. A budget only alerts - it never stops spending."
  type        = number
}

variable "github_repository_id" {
  description = "Numeric id of the GitHub repository whose workflows may deploy (gh api repos/OWNER/REPO --jq .id). An id, not a name: a deleted repository's name can be registered again by anyone, its id cannot."
  type        = string
}

variable "github_repository_owner_id" {
  description = "Numeric id of the repository's owner (gh api repos/OWNER/REPO --jq .owner.id)."
  type        = string
}

variable "github_ref" {
  description = "The only Git ref whose workflow runs get Google credentials. Pull request code never does."
  type        = string
}
