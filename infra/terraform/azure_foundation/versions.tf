# Terraform and provider versions. "~> 5.10" means 5.10 or newer, but below 6.0, so a minor update never
# breaks the module; the exact version picked is recorded in .terraform.lock.hcl (local, git-ignored).
#   azurerm  Azure - resource provider registrations, the cluster's resource group, the GitHub deployer
#            (a user-assigned managed identity + a federated credential), role assignments, the budget.
#            https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10"
    }
  }
}

# Credentials: the Azure CLI's sign-in (`az login`, short-lived tokens it refreshes itself) - no client
# secret exists. The CLI reads its sign-in from AZURE_CONFIG_DIR (the Makefile exports it from .env.azure),
# so a workstation's other tenants stay out of reach. subscription_id and tenant_id pin every call to the
# platform's subscription; the identity check in main.tf narrows it to one person.
# Resource providers: azurerm 5 registers none by itself. Only what the clusters use is named below -
# registering is free and changes nothing until something is created. Each name is spelled as Azure lists it
# (az provider list): azurerm matches it exactly, and "Microsoft.Insights" - listed as microsoft.insights -
# was silently left unregistered (2026-10-21). The registration happens on every plan, before anything else.
provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  use_cli         = true

  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.ContainerService",    # AKS
    "Microsoft.Compute",             # the nodes (virtual machine scale sets) and their disks
    "Microsoft.Network",             # the cluster's virtual network, load balancer, public IPs
    "Microsoft.Storage",             # AKS's built-in Azure Files StorageClasses
    "Microsoft.ManagedIdentity",     # the deployer's identity and its federated credential
    "Microsoft.OperationalInsights", # the Log Analytics workspace of the control-plane logs
    "microsoft.insights",            # diagnostic settings that send those logs (lower case: see above)
    "Microsoft.Consumption",         # the budget
  ]

  features {
    # Deleting a resource group that still holds something fails instead of deleting it with everything in it.
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}
