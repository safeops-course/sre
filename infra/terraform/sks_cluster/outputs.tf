# What a person or a later step needs from the cluster. Nothing here is secret (no credentials are made
# here at all - kubectl gets a short-lived certificate from exo each time).

output "cluster_name" {
  value = exoscale_sks_cluster.this.name
}

output "cluster_id" {
  description = "The cluster's id - exo compute sks ... takes it, and the kubeconfig's exec names it."
  value       = exoscale_sks_cluster.this.id
}

output "cluster_endpoint" {
  description = "The API server's public endpoint (the client certificate decides who gets in)."
  value       = exoscale_sks_cluster.this.endpoint
}

output "kubernetes_version" {
  description = "The release the control plane runs (var.kubernetes_version at creation; later patches with auto_upgrade)."
  value       = exoscale_sks_cluster.this.version
}

output "kubeconfig_path" {
  description = "Context sks-<cluster_name>-control-plane; no credentials inside."
  value       = local_file.kubeconfig.filename
}
