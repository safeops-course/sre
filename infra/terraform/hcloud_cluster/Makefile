SHELL := /bin/bash
TF    := terraform
TF_DIR := $(CURDIR)

.PHONY: help init plan apply destroy state-clean state-clean-k8s state-list kubeconfig test

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

init: ## Terraform init
	$(TF) init

plan: ## Terraform plan
	$(TF) plan

apply: ## Terraform apply
	$(TF) apply

DESTROY_ATTEMPTS ?= 3

destroy: ## Destroy cluster (run Flux/Kubernetes pre-destroy cleanup, then infra)
	@case "$(DESTROY_ATTEMPTS)" in ''|*[!0-9]*|0) echo "DESTROY_ATTEMPTS must be a positive integer, got '$(DESTROY_ATTEMPTS)'" >&2; exit 2 ;; esac
	@echo "==> Running Flux/Kubernetes pre-destroy cleanup..."
	@$(TF) destroy -target='null_resource.flux_pre_destroy' -auto-approve
	@echo "==> Removing Flux resources from state (pre-destroy hook already ran)..."
	@$(TF) state rm 'null_resource.flux_instance' 2>/dev/null || true
	@$(TF) state rm 'null_resource.flux_operator_install' 2>/dev/null || true
	@echo "==> Removing Kubernetes resources from state (cluster-side teardown already handled)..."
	@$(MAKE) --no-print-directory state-clean-k8s
	@echo "==> Destroying infrastructure..."
	@# Up to DESTROY_ATTEMPTS tries: the Hetzner API refuses some deletes while an earlier operation
	@# is still finishing (e.g. 422 resource_already_detaching when removing the network); a second
	@# pass finds the resource gone and continues. A real error fails every attempt.
	@# The leftover check runs even when the destroy fails - that is when something is most likely
	@# left behind. A failed destroy keeps its own exit status; otherwise the check's status counts.
	@rc=1; for attempt in $$(seq 1 $(DESTROY_ATTEMPTS)); do \
	  rc=0; $(TF) destroy || rc=$$?; \
	  [ $$rc -eq 0 ] && break; \
	  [ $$attempt -lt $(DESTROY_ATTEMPTS) ] && { echo "==> destroy attempt $$attempt failed (exit $$rc) - retrying in 30s"; sleep 30; }; \
	done; \
	echo "==> Checking that nothing billable is left in the Hetzner project..."; \
	../../../scripts/hcloud-leftovers.sh; check=$$?; \
	if [ $$rc -ne 0 ]; then exit $$rc; fi; exit $$check

state-list: ## List all resources in state
	$(TF) state list

state-clean-k8s: ## Remove all kubernetes/helm resources from state
	@$(TF) state list 2>/dev/null | grep -E '^kubernetes_|^helm_' | while IFS= read -r r; do \
		echo "  removing $$r"; \
		$(TF) state rm "$$r" 2>/dev/null || true; \
	done
	@$(TF) state rm 'local_sensitive_file.kubeconfig' 2>/dev/null || true

state-clean: ## Remove ALL resources from state (nuclear option)
	@echo "==> Removing all resources from Terraform state..."
	@$(TF) state list 2>/dev/null | while IFS= read -r r; do \
		echo "  removing $$r"; \
		$(TF) state rm "$$r" 2>/dev/null || true; \
	done
	@echo "==> State is now empty. 'terraform plan' will show everything as new."

test: ## Validate Terraform configuration
	@if [ ! -d .terraform ]; then $(TF) init -input=false -backend=false; fi
	$(TF) validate

kubeconfig: ## Export KUBECONFIG path
	@echo "export KUBECONFIG=$(TF_DIR)/kubeconfig.yaml"
