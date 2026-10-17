# Inputs of the AWS foundation. Values that identify a person or an account have no default and are not
# in terraform.tfvars (the repository is public): set them as TF_VAR_* in the environment (the owner
# keeps them in .env.aws).

variable "region" {
  description = "The region the clusters run in; regional account defaults (EBS encryption, IMDS) are set here."
  type        = string
}

variable "account_id" {
  description = "The AWS account that holds the platform (12 digits). The provider refuses every other account. Set TF_VAR_account_id."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the 12-digit AWS account id (aws sts get-caller-identity --query Account)."
  }
}

variable "aws_profile" {
  description = "The AWS CLI profile Terraform signs in with (a profile of `aws login`). Set TF_VAR_aws_profile."
  type        = string
}

variable "expected_principal_arn" {
  description = "The identity that may run this module (arn:aws:iam::ACCOUNT:user/NAME). Any other identity fails the plan - a workstation with several AWS profiles must not apply as the wrong one. Set TF_VAR_expected_principal_arn."
  type        = string
}

variable "alert_email" {
  description = "Where the budget alerts go. Set TF_VAR_alert_email."
  type        = string
  sensitive   = true
}

variable "budget_amount" {
  description = "Monthly cost budget in USD. Alerts at 50, 90 and 100 percent of actual spend and at 100 percent of the forecast. A budget only alerts - it never stops spending."
  type        = number

  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount is ${var.budget_amount}; use an amount above 0."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster the deployer may build. Every IAM role, policy and log group the cluster module creates starts with it - the deployer's IAM rights end there."
  type        = string
}

variable "github_repository" {
  description = "OWNER/REPO whose workflows may deploy. Used only in the sub claim, which AWS requires; the lock itself is the numeric ids below."
  type        = string
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
  description = "The only Git ref whose workflow runs get AWS credentials. Pull request code never does."
  type        = string
}
