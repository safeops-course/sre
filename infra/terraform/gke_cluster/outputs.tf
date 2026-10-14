# What a person or a later step needs from the cluster. Nothing here is secret.

output "cluster_name" {
  value = google_container_cluster.this.name
}

output "control_plane_dns_endpoint" {
  description = "The only way to the API server (IAM-controlled)."
  value       = google_container_cluster.this.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}

output "kubernetes_version" {
  value = google_container_cluster.this.master_version
}

output "kubeconfig_path" {
  description = "Context gke-<cluster_name>-control-plane; no credentials inside."
  value       = local_file.kubeconfig.filename
}
