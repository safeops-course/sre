# Terraform and provider versions: the ranges below; .terraform.lock.hcl (git-ignored, as in every module
# here) pins the exact build per checkout - another checkout can resolve a newer one within the range.
#   digitalocean  DigitalOcean - the VPC, the DOKS cluster and its node pools, the identity check
#   helm          metrics-server (DOKS has none)
#   kubernetes    what Terraform puts inside the cluster before Flux takes over (flux.tf)
#   local         writes kubeconfig.yaml next to the module (no credentials in it)
#   null          runs kubectl for the Flux Operator and the FluxInstance
#   random        generates the production database password
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.106"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
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

# Credentials: a personal access token from DIGITALOCEAN_TOKEN, which the Makefile reads from doctl's own
# config file (DIGITALOCEAN_CONFIG, never doctl's default one). Never a value in this repository. The plan's
# identity check (main.tf) fails unless the token belongs to var.expected_account_uuid.
provider "digitalocean" {}

# kubectl, Terraform and Helm sign in the same way, through doctl: `doctl kubernetes cluster kubeconfig
# exec-credential` asks DigitalOcean for a short-lived token of the cluster, with the token in
# DIGITALOCEAN_CONFIG (context "default"). The env entry names that file, so the exec works in any shell -
# kubectl's or Terraform's - without doctl's default config. Not the token in the cluster's kube_config
# attribute: it stays in the state, and kubeconfig.yaml must hold no credentials.
locals {
  doks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = var.doctl
    args        = ["kubernetes", "cluster", "kubeconfig", "exec-credential", "--version=v1beta1", "--context=default", digitalocean_kubernetes_cluster.this.id]
    env         = { DIGITALOCEAN_CONFIG = var.doctl_config }
  }
}

provider "kubernetes" {
  host                   = digitalocean_kubernetes_cluster.this.endpoint
  cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)

  exec {
    api_version = local.doks_exec.api_version
    command     = local.doks_exec.command
    args        = local.doks_exec.args
    env         = local.doks_exec.env
  }
}

provider "helm" {
  kubernetes = {
    host                   = digitalocean_kubernetes_cluster.this.endpoint
    cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
    exec                   = local.doks_exec
  }
}
