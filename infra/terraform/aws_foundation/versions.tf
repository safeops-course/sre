# Terraform and provider versions. "~> 6.69" means 6.69 or newer, but below 7.0, so a minor update never
# breaks the module; the exact version picked is pinned in .terraform.lock.hcl.
#   aws  AWS - IAM (GitHub OIDC, the deployer role), the budget, account-wide defaults (S3, EBS, IMDS).
#        https://registry.terraform.io/providers/hashicorp/aws/latest/docs
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

# Credentials: a named profile signed in with `aws login` (short-lived, refreshed every 15 minutes, at
# most 12 hours) - no access key exists. The profile is set here on purpose: a profile in the provider
# block beats AWS_ACCESS_KEY_ID in the environment, and the Makefile exports the R2 state key under
# exactly that name for the S3 backend. Without it the provider would sign AWS calls with the R2 key.
# allowed_account_ids stops every call before it reaches another account the profile might point at;
# the identity check in main.tf narrows it to one principal.
provider "aws" {
  region              = var.region
  profile             = var.aws_profile
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      managed-by = "terraform"
      stack      = "aws_foundation"
    }
  }
}
