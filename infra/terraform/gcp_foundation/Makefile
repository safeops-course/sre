# The Google Cloud foundation - applied once, by a person, from a workstation (it creates the identity
# CI deploys with). Needs: the R2 state keys (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), Application
# Default Credentials of the right Google identity, and TF_VAR_expected_principal,
# TF_VAR_billing_account_id, TF_VAR_alert_email.
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

.PHONY: help init whoami plan apply delete-default-network

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

# The "default" VPC Google creates with the Compute API opens SSH and RDP to the internet; nothing here
# uses it (main.tf, check "no_default_network"). Its firewall rules go first - a network with rules
# cannot be deleted. One-time and not undone by Terraform, so it asks for CONFIRM=yes.
GCP_PROJECT := $(shell sed -n 's/^project_id *= *"\(.*\)".*/\1/p' terraform.tfvars)

delete-default-network: ## One-time: delete the "default" VPC and its firewall rules (CONFIRM=yes)
	@test -n "$(GCP_PROJECT)" || { echo "no project_id in terraform.tfvars" >&2; exit 2; }
	@test "$(CONFIRM)" = yes || { echo "deletes the default VPC of $(GCP_PROJECT) and its firewall rules - run again with CONFIRM=yes" >&2; exit 2; }
	@rules="$$(gcloud compute firewall-rules list --project=$(GCP_PROJECT) --filter='network~/default$$' --format='value(name)')"; \
	  if [ -n "$$rules" ]; then gcloud compute firewall-rules delete --project=$(GCP_PROJECT) --quiet $$rules; fi
	@if gcloud compute networks describe default --project=$(GCP_PROJECT) >/dev/null 2>&1; then \
	  gcloud compute networks delete default --project=$(GCP_PROJECT) --quiet; \
	else echo "no default network in $(GCP_PROJECT)"; fi
