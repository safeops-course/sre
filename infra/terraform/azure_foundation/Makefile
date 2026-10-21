# The Azure foundation - applied once, by a person, from a workstation (it creates the identity CI deploys
# with). docs/azure.md walks through it; `make bootstrap` does the whole first setup.
#
# Settings come from ENV_FILE (default: .env.azure in the repository root, git-ignored; template
# .env.azure.example) or, without that file, from your shell: AZURE_CONFIG_DIR, TF_VAR_subscription_id,
# TF_VAR_tenant_id, TF_VAR_expected_principal_object_id, TF_VAR_alert_email, and the R2 state key
# (R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY, or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

ENV_FILE ?= ../../../.env.azure
-include $(ENV_FILE)
export TF_VAR_subscription_id TF_VAR_tenant_id TF_VAR_expected_principal_object_id TF_VAR_alert_email
# The Azure CLI's own directory (its sign-in and token cache): Terraform signs in through the CLI, so this
# decides which sign-in it uses - never the default ~/.azure, which may hold other tenants.
export AZURE_CONFIG_DIR
# The S3 backend reads AWS_*; the R2 key is named R2_* in the env files. Only the backend reads it.
ifneq ($(R2_ACCESS_KEY_ID),)
export AWS_ACCESS_KEY_ID     := $(R2_ACCESS_KEY_ID)
export AWS_SECRET_ACCESS_KEY := $(R2_SECRET_ACCESS_KEY)
endif
# A session token of another AWS session in the shell would be paired with the R2 key by the backend.
unexport AWS_SESSION_TOKEN
# Azure credentials in the environment would win over the CLI sign-in (a client secret, a service principal):
# Terraform must run as the person signed in to AZURE_CONFIG_DIR, nothing else.
unexport ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_CLIENT_CERTIFICATE_PATH ARM_USE_OIDC ARM_USE_MSI ARM_OIDC_TOKEN ARM_SUBSCRIPTION_ID ARM_TENANT_ID

LOCATION := $(shell sed -n 's/^location *= *"\([^"]*\)".*/\1/p' terraform.tfvars)

.PHONY: help init preflight plan apply verify bootstrap

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

# Every setting present before Terraform runs - a missing one is named, not discovered half-way. The CLI's
# signed-in subscription and tenant must be the platform's (read from its local cache - no cloud call);
# the person itself is checked by the plan (main.tf): only Microsoft Entra can say who the token is.
preflight: ## Check the settings and the Azure CLI sign-in (no cloud calls)
	@missing=""; \
	for v in AZURE_CONFIG_DIR TF_VAR_subscription_id TF_VAR_tenant_id TF_VAR_expected_principal_object_id TF_VAR_alert_email AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do \
	  [ -n "$${!v:-}" ] || missing="$$missing $$v"; \
	done; \
	[ -z "$$missing" ] || { echo "missing:$$missing - set them in $(ENV_FILE) (template: .env.azure.example)" >&2; exit 2; }
	@test -n "$(LOCATION)" || { echo "no location in terraform.tfvars" >&2; exit 2; }
	@for t in az jq; do command -v $$t >/dev/null || { echo "$$t is not installed (docs/azure.md, prerequisites)" >&2; exit 2; }; done
	@account="$$(az account show --subscription "$$TF_VAR_subscription_id" --output json 2>/dev/null)" \
	  || { echo "the Azure CLI (AZURE_CONFIG_DIR=$$AZURE_CONFIG_DIR) is not signed in to subscription $$TF_VAR_subscription_id - az login --tenant $$TF_VAR_tenant_id (docs/azure.md, step 2)" >&2; exit 2; }; \
	tenant="$$(jq -r .tenantId <<<"$$account")"; \
	[ "$$tenant" = "$$TF_VAR_tenant_id" ] || { echo "subscription $$TF_VAR_subscription_id is in tenant $$tenant, expected $$TF_VAR_tenant_id" >&2; exit 2; }
	@echo "subscription $$TF_VAR_subscription_id, tenant $$TF_VAR_tenant_id, location $(LOCATION), expected identity $$TF_VAR_expected_principal_object_id"

init: ## Terraform init (state in R2)
	@$(TF) init -input=false >/dev/null

plan: preflight init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan
	@$(TF) show -no-color tfplan | grep -E '^Plan:|^No changes' || true

apply: preflight ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)

# The subscription matches the code: a resource the plan would create, change or delete is drift
# (see gcp_foundation/Makefile for why not -detailed-exitcode). 0 = no drift, 1 = drift or an error.
verify: preflight init ## The foundation matches the code (no drift)
	@$(TF) plan -input=false -lock=false -out=verify.tfplan >/dev/null || { echo "FAIL the plan did not run" >&2; rm -f verify.tfplan; exit 1; }
	@set -o pipefail; \
	changes="$$($(TF) show -json verify.tfplan | jq -er '[.resource_changes[]? | select(.mode == "managed" and .change.actions != ["no-op"]) | .address] | join(" ")')" \
	  || { echo "FAIL could not read the plan (terraform show / jq error above)" >&2; rm -f verify.tfplan; exit 1; }; \
	rm -f verify.tfplan; \
	if [ -n "$$changes" ]; then echo "FAIL drift: $$changes - run make plan and read it" >&2; exit 1; fi; \
	echo "OK   no drift: the subscription matches the code"

# The whole first setup: plan, confirm, apply, verify.
bootstrap: preflight ## First setup: plan, confirm, apply, verify
	@$(MAKE) --no-print-directory plan
	@read -r -p "Apply this plan to Azure subscription $$TF_VAR_subscription_id? [y/N] " answer; [ "$$answer" = y ] || { echo "not applied"; exit 1; }
	@$(MAKE) --no-print-directory apply
	@$(MAKE) --no-print-directory verify
