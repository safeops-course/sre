# Terraform and provider versions: the ranges below; .terraform.lock.hcl (git-ignored, as in every module
# here) pins the exact build per checkout - another checkout can resolve a newer one within the range.
#   azurerm     Azure - the AKS cluster, its node pools, the control-plane logs
#   kubernetes  what Terraform puts inside the cluster before Flux takes over (flux.tf)
#   local       writes kubeconfig.yaml next to the module (no credentials in it)
#   null        runs kubectl for the Flux Operator and the FluxInstance
#   random      generates the production database password
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10"
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

# Credentials: the Azure CLI's sign-in from AZURE_CONFIG_DIR (see azure_foundation/versions.tf). The
# foundation registers the resource providers; this module registers none.
provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  use_cli         = true

  resource_provider_registrations = "none"

  features {
    # The control-plane log workspace goes for good with the cluster: a soft-deleted one would keep its
    # name for 14 days and come back with its old data when the next cycle creates it.
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }
}

# The kubernetes provider signs in the way kubectl does (kubeconfig.yaml): a short-lived Microsoft Entra
# token from Azure kubelogin, out of the same Azure CLI sign-in - the person the foundation made Kubernetes
# admin of the cluster's group. A token, not credentials from the cluster: it has no local accounts.
# 6dae42f8-... is the AKS server application every AKS cluster with Entra ID accepts tokens for.
locals {
  aks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = var.kubelogin
    args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  }
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.this.kube_config[0].host
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)

  exec {
    api_version = local.aks_exec.api_version
    command     = local.aks_exec.command
    args        = local.aks_exec.args
  }
}
