# Terraform and provider versions: the ranges below; .terraform.lock.hcl (git-ignored, as in every module
# here) pins the exact build per checkout - another checkout can resolve a newer one within the range.
#   exoscale    Exoscale - the security group, the SKS cluster and its node pools, the identity check
#   kubernetes  what Terraform puts inside the cluster before Flux takes over (flux.tf)
#   local       writes kubeconfig.yaml next to the module (no credentials in it)
#   null        runs kubectl for the Flux Operator and the FluxInstance
#   random      generates the production database password
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    exoscale = {
      source  = "exoscale/exoscale"
      version = "~> 0.76"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

# Credentials: the API key and secret from EXOSCALE_API_KEY / EXOSCALE_API_SECRET, which the Makefile reads
# from exo's own config file (EXOSCALE_CONFIG, never exo's default one). Never a value in this repository.
# The key's IAM role allows the compute service class only; the plan's identity check (main.tf) fails unless
# the key belongs to the expected organization.
provider "exoscale" {}

# kubectl and Terraform sign in the same way, through exo: `exo compute sks kubeconfig ... --exec-credential`
# asks Exoscale for a short-lived client certificate of the cluster (group system:masters, exo's default),
# with the key in EXOSCALE_CONFIG. The env entry names that file, so the exec works in any shell - kubectl's
# or Terraform's - without exo's default config. Not exoscale_sks_kubeconfig: its certificate stays valid for
# 30 days, sits in the state, and kubeconfig.yaml must hold no credentials.
locals {
  # Exoscale gives the endpoint as a bare host name (<id>.sks-<zone>.exo.io); the API server is HTTPS on 443,
  # as in exo's own kubeconfig. The kubernetes provider and kubectl need the full URL.
  api_server_url = "https://${exoscale_sks_cluster.this.endpoint}:443"

  sks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = var.exo
    args        = ["compute", "sks", "kubeconfig", exoscale_sks_cluster.this.id, "admin", "--zone=${var.zone}", "--exec-credential"]
    env         = { EXOSCALE_CONFIG = var.exo_config }
  }
}

provider "kubernetes" {
  host                   = local.api_server_url
  cluster_ca_certificate = exoscale_sks_cluster.this.control_plane_ca

  exec {
    api_version = local.sks_exec.api_version
    command     = local.sks_exec.command
    args        = local.sks_exec.args
    env         = local.sks_exec.env
  }
}
