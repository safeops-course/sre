SHELL := /bin/bash

BIN_DIR := $(CURDIR)/bin
export PATH := $(BIN_DIR):$(PATH)

# Pinned toolchain versions (minimums are checked by scripts/check-tools.sh)
TERRAFORM_VERSION := 1.13.3
KUBECTL_VERSION := 1.34.1
KIND_VERSION := 0.30.0
FLUX_VERSION := 2.7.0

.PHONY: help check-tools versions plan install-hooks pre-commit fmt validate smoke-test terraform-hcloud-init terraform-hcloud-plan terraform-hcloud-apply terraform-hcloud-destroy

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

check-tools: ## Verify the workstation has every tool the labs need (lab setup)
	@./scripts/check-tools.sh

versions: ## Show pinned CLI versions
	@echo "terraform\t$(TERRAFORM_VERSION)"
	@echo "kubectl\t$(KUBECTL_VERSION)"
	@echo "kind\t$(KIND_VERSION)"
	@echo "flux\t$(FLUX_VERSION)"

plan: ## Run Terraform plans for all configured workspaces (pending implementation)
	@if [ -x "$(BIN_DIR)/terraform" ]; then \
		echo "[plan] Running terraform plan (stub)"; \
		"$(BIN_DIR)/terraform" version >/dev/null; \
	else \
		echo "[plan] terraform not available; run make bootstrap"; \
	fi

install-hooks: ## Install pre-commit hooks
	pre-commit install
	pre-commit install --hook-type prepare-commit-msg
	pre-commit install --hook-type pre-push

pre-commit: ## Run all pre-commit hooks
	pre-commit run --all-files

fmt: ## Format Terraform files
	terraform fmt -recursive infra/terraform/

smoke-test: ## Run infrastructure smoke tests against the cluster
	bash tests/smoke-test.sh

validate: ## Validate Terraform configs
	cd infra/terraform/hcloud_cluster && terraform validate

terraform-hcloud-init: ## Terraform init for Hetzner cluster
	@$(MAKE) -C infra/terraform/hcloud_cluster init

terraform-hcloud-plan: ## Terraform plan for Hetzner cluster
	@$(MAKE) -C infra/terraform/hcloud_cluster init
	@$(MAKE) -C infra/terraform/hcloud_cluster plan

terraform-hcloud-apply: ## Terraform apply for Hetzner cluster
	@$(MAKE) -C infra/terraform/hcloud_cluster init
	@$(MAKE) -C infra/terraform/hcloud_cluster apply

terraform-hcloud-destroy: ## Terraform destroy for Hetzner cluster (with state cleanup)
	@$(MAKE) -C infra/terraform/hcloud_cluster init
	@$(MAKE) -C infra/terraform/hcloud_cluster destroy
