# What a person or a later step needs from the cluster. Nothing here is secret (the cluster's kube_config,
# which holds a token, stays in the state only).

output "cluster_name" {
  value = digitalocean_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "The cluster's id - doctl kubernetes cluster ... takes it, and the kubeconfig's exec names it."
  value       = digitalocean_kubernetes_cluster.this.id
}

output "cluster_endpoint" {
  description = "The API server's public endpoint (the token decides who gets in)."
  value       = digitalocean_kubernetes_cluster.this.endpoint
}

output "kubernetes_version" {
  description = "The DOKS release the cluster runs (the newest of var.kubernetes_version when it was planned)."
  value       = digitalocean_kubernetes_cluster.this.version
}

output "kubeconfig_path" {
  description = "Context doks-<cluster_name>-control-plane; no credentials inside."
  value       = local_file.kubeconfig.filename
}
