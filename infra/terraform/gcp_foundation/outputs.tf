# What the GKE workflow and the cluster module need from the foundation. None of it is secret: the
# Workload Identity provider name and the service account e-mails only work together with a GitHub
# token that matches the attribute condition.

output "workload_identity_provider" {
  description = "For google-github-actions/auth: workload_identity_provider."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_service_account" {
  description = "For google-github-actions/auth: service_account (the identity the GKE workflow runs as)."
  value       = google_service_account.deployer.email
}

output "gke_nodes_service_account" {
  description = "The service account GKE node pools run as."
  value       = google_service_account.gke_nodes.email
}

output "alert_notification_channel" {
  description = "Cloud Monitoring channel for platform alerts."
  value       = google_monitoring_notification_channel.email.id
}
