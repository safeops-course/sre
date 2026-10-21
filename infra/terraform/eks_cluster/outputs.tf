# What a person or a later step needs from the cluster. Nothing here is secret.

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "The API server's public endpoint (IAM decides who gets in)."
  value       = module.eks.cluster_endpoint
}

output "kubernetes_version" {
  value = module.eks.cluster_version
}

output "kubeconfig_path" {
  description = "Context eks-<cluster_name>-control-plane; no credentials inside."
  value       = local_file.kubeconfig.filename
}
