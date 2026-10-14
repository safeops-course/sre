# The Google Cloud foundation - applied once, by a person, from a workstation (it creates the identity
# CI deploys with). Needs: the R2 state keys (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), Application
# Default Credentials of the right Google identity, and TF_VAR_expected_principal,
# TF_VAR_billing_account_id, TF_VAR_alert_email.
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

.PHONY: help init whoami plan apply

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-10s\033[0m %s\n", $$1, $$2}'

init: ## Terraform init (state in R2)
	$(TF) init -input=false

# The plan checks the identity too (main.tf); this shows it before anything else runs.
whoami: ## Which Google identity Terraform will use (Application Default Credentials)
	@echo "ADC file: $${GOOGLE_APPLICATION_CREDENTIALS:-(gcloud default directory)}"
	@echo "expected: $${TF_VAR_expected_principal:-(TF_VAR_expected_principal not set)}"

plan: init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan

apply: ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)
