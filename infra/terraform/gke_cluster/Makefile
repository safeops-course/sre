# The GKE cluster - created for a test cycle and destroyed after it (docs/gcp.md). Settings come from
# ENV_FILE (default .env.gcp in the repository root, git-ignored) or your shell: TF_VAR_expected_principal,
# GOOGLE_APPLICATION_CREDENTIALS, the R2 state key (R2_* or AWS_*).
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

ENV_FILE ?= ../../../.env.gcp
-include $(ENV_FILE)
export TF_VAR_expected_principal GOOGLE_APPLICATION_CREDENTIALS
ifneq ($(R2_ACCESS_KEY_ID),)
export AWS_ACCESS_KEY_ID     := $(R2_ACCESS_KEY_ID)
export AWS_SECRET_ACCESS_KEY := $(R2_SECRET_ACCESS_KEY)
endif

GCP_PROJECT := $(shell sed -n 's/^project_id *= *"\(.*\)".*/\1/p' terraform.tfvars)

.PHONY: help preflight init plan apply destroy leftovers

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

preflight: ## Check that every setting is there (no cloud calls)
	@missing=""; \
	for v in TF_VAR_expected_principal AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do [ -n "$${!v:-}" ] || missing="$$missing $$v"; done; \
	command -v gke-gcloud-auth-plugin >/dev/null || missing="$$missing gke-gcloud-auth-plugin(gcloud components install gke-gcloud-auth-plugin)"; \
	[ -z "$$missing" ] || { echo "missing:$$missing - set them in $(ENV_FILE) (template: .env.gcp.example)" >&2; exit 2; }

init: ## Terraform init (state in R2)
	@$(TF) init -input=false >/dev/null

plan: preflight init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan
	@$(TF) show -no-color tfplan | grep -E '^Plan:|^No changes' || true

apply: preflight ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)

# Terraform asks before it destroys; AUTO_APPROVE=1 skips the question (CI, or a confirmed teardown).
destroy: preflight init ## Destroy the cluster and its network (asks; AUTO_APPROVE=1 does not), then look for leftovers
	@$(TF) destroy $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,)
	@$(MAKE) --no-print-directory leftovers

# What can outlive a cluster and keep costing: disks of PersistentVolumes (GKE keeps them), load
# balancer forwarding rules and addresses of LoadBalancer Services, NEGs, and firewall rules GKE or a
# controller created. Exit 1 when anything is left.
leftovers: ## List billable leftovers in the project (exit 1 when any)
	@left=0; \
	for kind in "compute disks" "compute forwarding-rules" "compute target-pools" "compute addresses" \
	            "compute network-endpoint-groups" "compute firewall-rules" "compute routers" "compute networks" \
	            "container clusters"; do \
	  out="$$(gcloud $$kind list --project=$(GCP_PROJECT) --format='value(name)' 2>/dev/null)"; \
	  if [ -n "$$out" ]; then left=1; echo "LEFT $$kind: $$(tr '\n' ' ' <<<"$$out")"; fi; \
	done; \
	if [ $$left = 0 ]; then echo "OK   nothing left in $(GCP_PROJECT)"; else exit 1; fi
