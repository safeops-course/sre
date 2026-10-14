# The course's Google Cloud foundation. Not here (public repository): expected_principal,
# billing_account_id, alert_email - set them as TF_VAR_* in the environment.

project_id = "safeops-510221"
region     = "europe-west1" # Belgium: lowest Google Cloud price tier in Europe, every GKE feature

budget_amount = 10 # the billing account is in USD

# safeops-course/sre (gh api repos/safeops-course/sre --jq '.id, .owner.id')
github_repository_id       = "1178278859"
github_repository_owner_id = "267145983"
github_ref                 = "refs/heads/main"
