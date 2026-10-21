# Terraform and provider versions: the ranges below; .terraform.lock.hcl (git-ignored, as in every module
# here) pins the exact build per checkout - another checkout can resolve a newer one within the range.
#   aws         AWS - VPC, NAT gateway, EKS, node groups, add-ons, Pod Identity associations
#   kubernetes  what Terraform puts inside the cluster before Flux takes over (flux.tf)
#   helm        the AWS Load Balancer Controller (main.tf) - before Flux, so Traefik's Service finds it
#   local       writes kubeconfig.yaml next to the module (no credentials in it)
#   null        runs kubectl for the Flux Operator and the FluxInstance
#   random      generates the production database password
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
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

# Credentials: a named profile of `aws login` (see aws_foundation/versions.tf). The profile in the
# provider block beats AWS_ACCESS_KEY_ID, which the Makefile sets to the R2 state key for the backend.
# allowed_account_ids stops every call to another account; the identity check in main.tf pins the principal.
provider "aws" {
  region              = var.region
  profile             = var.aws_profile
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      managed-by = "terraform"
      stack      = "eks_cluster"
      cluster    = var.cluster_name
    }
  }
}

# The kubernetes and helm providers sign in the way kubectl does (kubeconfig.yaml): a short-lived token
# from `aws eks get-token` of the same profile - the identity that created the cluster and got its admin
# access entry. --profile beats the R2 key in AWS_ACCESS_KEY_ID here too. A token, not a data source:
# aws_eks_cluster_auth's token ends after 15 minutes, shorter than a destroy can take.
locals {
  eks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile, "--output", "json"]
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = local.eks_exec.api_version
    command     = local.eks_exec.command
    args        = local.eks_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec                   = local.eks_exec
  }
}
