# What the AKS workflow and the cluster module need from the foundation. None of it is secret: a client id
# only works together with a token the federated credential accepts.

output "deployer_client_id" {
  description = "For azure/login: client-id (the identity the AKS workflow runs as); tenant-id and subscription-id are the module's inputs."
  value       = azurerm_user_assigned_identity.deployer.client_id
}

output "cluster_resource_group" {
  description = "The resource group the cluster module builds in (aks_cluster: var.cluster_name + \"-aks\")."
  value       = azurerm_resource_group.aks.name
}
