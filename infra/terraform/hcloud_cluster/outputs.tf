output "kubeconfig" {
  description = "Kubeconfig for the created cluster (YAML)."
  value       = module.kube_hetzner.kubeconfig
  sensitive   = true
}

output "kubeconfig_export" {
  description = "Run this command to set your KUBECONFIG."
  value       = "export KUBECONFIG=$(pwd)/kubeconfig.yaml"
}

