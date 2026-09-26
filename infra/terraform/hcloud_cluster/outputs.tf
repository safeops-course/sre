output "kubeconfig" {
  description = "Kubeconfig for the created cluster (YAML), context hetzner-<cluster_name>-control-plane."
  value       = local.kubeconfig_named
  sensitive   = true
}

output "kubeconfig_export" {
  description = "Run this command to set your KUBECONFIG."
  value       = "export KUBECONFIG=$(pwd)/kubeconfig.yaml"
}

