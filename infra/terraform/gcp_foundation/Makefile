# The Google Cloud foundation - applied once, by a person, from a workstation (it creates the identity
# CI deploys with). docs/gcp.md walks through it; `make bootstrap` does the whole first setup.
#
# Settings come from ENV_FILE (default: .env.gcp in the repository root, git-ignored; template
# .env.gcp.example) or, without that file, from your shell: TF_VAR_expected_principal,
# TF_VAR_billing_account_id, TF_VAR_alert_email, GOOGLE_APPLICATION_CREDENTIALS, and the R2 state key
# (R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY, or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

ENV_FILE ?= ../../../.env.gcp
-include $(ENV_FILE)
export TF_VAR_expected_principal TF_VAR_billing_account_id TF_VAR_alert_email GOOGLE_APPLICATION_CREDENTIALS
# The S3 backend reads AWS_*; the R2 key is named R2_* in the env files (.env.local, .env.gcp).
ifneq ($(R2_ACCESS_KEY_ID),)
export AWS_ACCESS_KEY_ID     := $(R2_ACCESS_KEY_ID)
export AWS_SECRET_ACCESS_KEY := $(R2_SECRET_ACCESS_KEY)
endif

GCP_PROJECT := $(shell sed -n 's/^project_id *= *"\(.*\)".*/\1/p' terraform.tfvars)

.PHONY: help init preflight plan apply verify delete-default-network bootstrap

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

# Every setting present before Terraform runs - a missing one is named, not discovered half-way.
# The identity itself is checked by the plan (main.tf): only Google can say who the credentials are.
preflight: ## Check that every setting is there (no cloud calls)
	@missing=""; \
	for v in TF_VAR_expected_principal TF_VAR_billing_account_id TF_VAR_alert_email AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do \
	  [ -n "$${!v:-}" ] || missing="$$missing $$v"; \
	done; \
	if [ -n "$${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ ! -f "$$GOOGLE_APPLICATION_CREDENTIALS" ]; then \
	  missing="$$missing GOOGLE_APPLICATION_CREDENTIALS(file not found)"; fi; \
	[ -z "$$missing" ] || { echo "missing:$$missing - set them in $(ENV_FILE) (template: .env.gcp.example)" >&2; exit 2; }
	@echo "project $(GCP_PROJECT), expected identity $$TF_VAR_expected_principal, credentials $${GOOGLE_APPLICATION_CREDENTIALS:-(gcloud default directory)}"

init: ## Terraform init (state in R2)
	@$(TF) init -input=false >/dev/null

plan: preflight init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan
	@$(TF) show -no-color tfplan | grep -E '^Plan:|^No changes' || true

apply: preflight ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)

# The project matches the code (no drift) and holds no default VPC. 0 = yes, 1 = not.
# Drift = a resource the plan would create, change or delete. Not -detailed-exitcode: the data source
# in the check block is re-read on every apply, so that exit code would always say "changes".
verify: preflight init ## The foundation matches the code and the project has no default VPC
	@$(TF) plan -input=false -lock=false -out=verify.tfplan >/dev/null || { echo "FAIL the plan did not run" >&2; rm -f verify.tfplan; exit 1; }
	@changes="$$($(TF) show -json verify.tfplan | jq -r '[.resource_changes[]? | select(.mode == "managed" and .change.actions != ["no-op"]) | .address] | join(" ")')"; \
	rm -f verify.tfplan; \
	if [ -n "$$changes" ]; then echo "FAIL drift: $$changes - run make plan and read it" >&2; exit 1; fi; \
	echo "OK   no drift: the project matches the code"
	@if gcloud compute networks describe default --project=$(GCP_PROJECT) >/dev/null 2>&1; then \
	  echo "FAIL $(GCP_PROJECT) has a default VPC: make delete-default-network CONFIRM=yes" >&2; exit 1; \
	else echo "OK   no default VPC"; fi

# The "default" VPC Google creates with the Compute API opens SSH and RDP to the internet; nothing here
# uses it (main.tf, check "no_default_network"). Its firewall rules go first - a network with rules
# cannot be deleted. Not undone by Terraform, so it asks for CONFIRM=yes.
delete-default-network: ## One-time: delete the "default" VPC and its firewall rules (CONFIRM=yes)
	@test -n "$(GCP_PROJECT)" || { echo "no project_id in terraform.tfvars" >&2; exit 2; }
	@test "$(CONFIRM)" = yes || { echo "deletes the default VPC of $(GCP_PROJECT) and its firewall rules - run again with CONFIRM=yes" >&2; exit 2; }
	@rules="$$(gcloud compute firewall-rules list --project=$(GCP_PROJECT) --filter='network~/default$$' --format='value(name)')"; \
	  if [ -n "$$rules" ]; then gcloud compute firewall-rules delete --project=$(GCP_PROJECT) --quiet $$rules; fi
	@if gcloud compute networks describe default --project=$(GCP_PROJECT) >/dev/null 2>&1; then \
	  gcloud compute networks delete default --project=$(GCP_PROJECT) --quiet; \
	else echo "no default network in $(GCP_PROJECT)"; fi

# The whole first setup, in order: the default VPC exists only after the apply turned the Compute
# API on, so it is deleted after it. One question - the plan is shown and must be confirmed.
bootstrap: plan ## First setup: plan, confirm, apply, delete the default VPC, verify
	@read -r -p "Apply this plan to $(GCP_PROJECT)? [y/N] " answer; [ "$$answer" = y ] || { echo "not applied"; exit 1; }
	@$(MAKE) --no-print-directory apply
	@$(MAKE) --no-print-directory delete-default-network CONFIRM=yes
	@$(MAKE) --no-print-directory verify
