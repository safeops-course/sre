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

destroy: ## Destroy cluster (run Flux/Kubernetes pre-destroy cleanup, then infra)
	@echo "==> Running Flux/Kubernetes pre-destroy cleanup..."
	@$(TF) destroy -target='null_resource.flux_pre_destroy' -auto-approve
	@echo "==> Removing Flux resources from state (pre-destroy hook already ran)..."
	@$(TF) state rm 'null_resource.flux_instance' 2>/dev/null || true
	@$(TF) state rm 'null_resource.flux_operator_install' 2>/dev/null || true
	@echo "==> Removing Kubernetes resources from state (cluster-side teardown already handled)..."
	@$(MAKE) --no-print-directory state-clean-k8s
	@echo "==> Destroying infrastructure..."
	$(TF) destroy

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
