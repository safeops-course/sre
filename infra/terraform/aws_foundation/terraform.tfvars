# The course's AWS foundation. Not here (public repository): account_id, aws_profile,
# expected_principal_arn, alert_email - set them as TF_VAR_* in the environment (.env.aws).

region = "eu-central-1" # Frankfurt

# Test cycles only: create, check, destroy - a cycle costs a few dollars (docs/aws.md).
budget_amount = 10

cluster_name = "sre"

# safeops-course/sre (gh api repos/safeops-course/sre --jq '.id, .owner.id')
github_repository          = "safeops-course/sre"
github_repository_id       = "1178278859"
github_repository_owner_id = "267145983"
github_ref                 = "refs/heads/main"
