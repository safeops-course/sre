# Terraform and provider versions. "~> 8.7" means 8.7 or newer, but below 9.0, so a minor update never
# breaks the module; the exact version picked is pinned in .terraform.lock.hcl.
#   google  Google Cloud - project APIs, service accounts, Workload Identity Federation, monitoring,
#           the billing budget. https://registry.terraform.io/providers/hashicorp/google/latest/docs
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.7"
    }
  }
}

# Credentials: Application Default Credentials (gcloud auth application-default login), never a key
# file. The provider reads GOOGLE_APPLICATION_CREDENTIALS or gcloud's default directory - NOT a
# CLOUDSDK_CONFIG directory - so a workstation that also holds other Google identities must point
# GOOGLE_APPLICATION_CREDENTIALS at the right file. The identity check in main.tf stops a plan that
# runs as anyone but var.expected_principal.
provider "google" {
  project = var.project_id
  region  = var.region
}

# For the budget only: the Budget API is called on the billing account, and with user credentials
# Google needs a project to bill that API's quota to - this one (user_project_override). Kept off the
# default provider: there it also changes other calls (the identity check reads no e-mail with it).
provider "google" {
  alias                 = "billing"
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}
