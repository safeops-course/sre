# Terraform and provider versions; the exact versions are pinned in .terraform.lock.hcl.
#   google  Google Cloud - VPC, Cloud NAT, firewall, GKE, alert policies
#   local   writes kubeconfig.yaml next to the module (no credentials in it)
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.7"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}

# Credentials: Application Default Credentials - a person's (gcloud auth application-default login,
# GOOGLE_APPLICATION_CREDENTIALS when the workstation holds other identities) or, in CI, the
# terraform-gke service account through Workload Identity Federation. The identity check in main.tf
# stops a plan that runs as anyone but var.expected_principal.
provider "google" {
  project = var.project_id
  region  = var.region
}
