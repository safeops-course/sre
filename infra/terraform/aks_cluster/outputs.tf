# What a person or a later step needs from the cluster. Nothing here is secret.

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "cluster_endpoint" {
  description = "The API server's public endpoint (Microsoft Entra ID decides who gets in)."
  value       = "https://${azurerm_kubernetes_cluster.this.fqdn}:443"
}

output "kubernetes_version" {
  description = "The version AKS runs (the patch of var.kubernetes_version it picked)."
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "node_resource_group" {
  description = "The group AKS keeps the nodes, disks, load balancer and addresses in - deleted with the cluster."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "kubeconfig_path" {
  description = "Context aks-<cluster_name>-control-plane; no credentials inside."
  value       = local_file.kubeconfig.filename
}
