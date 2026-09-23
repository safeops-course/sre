SHELL := /bin/bash
TF    := terraform
TF_DIR := $(CURDIR)
CLUSTER_NAME := sre-control-plane

.PHONY: help init plan apply destroy destroy-force state-clean state-clean-k8s state-list kubeconfig test

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

init: ## Terraform init
	$(TF) init

plan: ## Terraform plan
	$(TF) plan

apply: ## Terraform apply
	$(TF) apply

destroy: ## Destroy cluster (cleanup Flux, then Kind)
	@echo "==> Deleting Kind cluster directly..."
	@kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@echo "==> Cleaning up Terraform state..."
	@$(MAKE) --no-print-directory state-clean
	@rm -f $(TF_DIR)/kubeconfig.yaml
	@echo "==> Done. Cluster and state cleaned up."

state-list: ## List all resources in state
	$(TF) state list

state-clean-k8s: ## Remove all kubernetes/helm resources from state
	@$(TF) state list 2>/dev/null | grep -E '^kubernetes_|^helm_' | while IFS= read -r r; do \
		echo "  removing $$r"; \
		$(TF) state rm "$$r" 2>/dev/null || true; \
	done

state-clean: ## Remove ALL resources from state
	@$(TF) state list 2>/dev/null | while IFS= read -r r; do \
		echo "  removing $$r"; \
		$(TF) state rm "$$r" 2>/dev/null || true; \
	done
	@echo "==> State is now empty."

test: ## Validate Terraform configuration
	@if [ ! -d .terraform ]; then $(TF) init -input=false -backend=false; fi
	$(TF) validate

kubeconfig: ## Export KUBECONFIG path
	@echo "export KUBECONFIG=$(TF_DIR)/kubeconfig.yaml"
