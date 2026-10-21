# The course's Azure foundation. Not here (public repository): subscription_id, tenant_id,
# expected_principal_object_id, alert_email - set them as TF_VAR_* in the environment (.env.azure).

location = "swedencentral" # Sweden - West Europe takes no new customers (RequestDisallowedByAzure, 2026-10-21)

# Test cycles only: create, check, destroy - a cycle costs about a dollar (docs/azure.md).
budget_amount = 10

cluster_name = "sre"

github_repository = "safeops-course/sre"
github_ref        = "refs/heads/main"
