# The DOKS cluster - created for a test cycle and destroyed after it (docs/digitalocean.md). Settings come from
# ENV_FILE (default .env.doks in the repository root, git-ignored; template .env.doks.example) or your shell:
# DIGITALOCEAN_CONFIG (doctl's config file with the token), TF_VAR_expected_account_uuid, the R2 state key
# (R2_* or AWS_*), SOPS_AGE_KEY_FILE (the platform's age key Flux decrypts flux/secrets with),
# TF_VAR_uptrace_dsn, the backup bucket's TF_VAR_backup_s3_* and DOCTL.
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

ENV_FILE ?= ../../../.env.doks
-include $(ENV_FILE)
export TF_VAR_expected_account_uuid TF_VAR_uptrace_dsn
# The CNPG backup bucket (Cloudflare R2) and its bucket-scoped key.
export TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key
# doctl's own config file - never its default one. doctl reads the variable itself; the kubeconfig's exec
# names it (variables.tf doctl_config), and Terraform's provider gets the token from it below.
export DIGITALOCEAN_CONFIG
export TF_VAR_doctl_config := $(DIGITALOCEAN_CONFIG)
# doctl itself (.env.doks DOCTL, a full path, or doctl on PATH) - exported for scripts/doks-leftovers.sh too.
DOCTL ?= doctl
export DOCTL
export TF_VAR_doctl := $(DOCTL)
# The token, from doctl's config ("default" context): Terraform's provider reads DIGITALOCEAN_TOKEN. Read
# from the file, never typed, never in .env.doks. A token in the environment of a named doctl context would be
# ignored by doctl - the config file is the one place.
ifneq ($(wildcard $(DIGITALOCEAN_CONFIG)),)
export DIGITALOCEAN_TOKEN := $(shell yq -r '."access-token" // ""' "$(DIGITALOCEAN_CONFIG)" 2>/dev/null)
endif
unexport DIGITALOCEAN_ACCESS_TOKEN DIGITALOCEAN_CONTEXT
# The age key, from the file, as an ephemeral variable - see gke_cluster/Makefile for why only the first
# AGE-SECRET-KEY- line, and why there is no default path.
ifndef TF_VAR_sops_age_key
TF_VAR_sops_age_key := $(if $(SOPS_AGE_KEY_FILE),$(shell grep -m1 -oE 'AGE-SECRET-KEY-[A-Z0-9-]+' "$(SOPS_AGE_KEY_FILE)" 2>/dev/null))
endif
export TF_VAR_sops_age_key
SOPS_CONFIG := ../../../.sops.yaml
# The S3 backend reads AWS_*; the R2 key is named R2_* in the env files. Only the backend reads it.
ifneq ($(R2_ACCESS_KEY_ID),)
export AWS_ACCESS_KEY_ID     := $(R2_ACCESS_KEY_ID)
export AWS_SECRET_ACCESS_KEY := $(R2_SECRET_ACCESS_KEY)
endif
unexport AWS_SESSION_TOKEN

CLUSTER   := $(shell sed -n 's/^cluster_name *= *"\([^"]*\)".*/\1/p' terraform.tfvars)
LEFTOVERS := ../../../scripts/doks-leftovers.sh

.PHONY: help settings keycheck access preflight init plan apply destroy leftovers

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

# What Terraform needs for any run.
settings: ## Check that every setting is there (no cloud calls)
	@missing=""; \
	for v in DIGITALOCEAN_CONFIG TF_VAR_expected_account_uuid AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
	         TF_VAR_uptrace_dsn TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key; do \
	  [ -n "$${!v:-}" ] || missing="$$missing $$v"; done; \
	[ -n "$${TF_VAR_sops_age_key:-}" ] || missing="$$missing SOPS_AGE_KEY_FILE($(if $(SOPS_AGE_KEY_FILE),$(SOPS_AGE_KEY_FILE) not readable,not set))"; \
	[ -z "$$missing" ] || { echo "missing:$$missing - set them in $(ENV_FILE) (template: .env.doks.example)" >&2; exit 2; }
	@test -n "$(CLUSTER)" || { echo "no cluster_name in terraform.tfvars" >&2; exit 2; }
	@case "$$DIGITALOCEAN_CONFIG" in /*) ;; *) echo "DIGITALOCEAN_CONFIG must be a full path (it is written into kubeconfig.yaml): $$DIGITALOCEAN_CONFIG" >&2; exit 2 ;; esac
	@[ -f "$$DIGITALOCEAN_CONFIG" ] || { echo "no doctl config at $$DIGITALOCEAN_CONFIG - DIGITALOCEAN_CONFIG=... doctl auth init (docs/digitalocean.md, step 2)" >&2; exit 2; }
	@[ -n "$${DIGITALOCEAN_TOKEN:-}" ] || { echo "no access-token in $$DIGITALOCEAN_CONFIG (its default context; or no yq to read it) - doctl auth init with DIGITALOCEAN_CONFIG set, no --context (docs/digitalocean.md, step 2)" >&2; exit 2; }

# The key Terraform sends must decrypt what this cluster's Flux decrypts (see gke_cluster/Makefile).
keycheck: settings ## The age key is a recipient of every platform rule in .sops.yaml (no cloud calls)
	@command -v age-keygen >/dev/null || { echo "missing: age-keygen (to check the age key against .sops.yaml)" >&2; exit 2; }
	@command -v yq >/dev/null || { echo "missing: yq v4 (to read .sops.yaml)" >&2; exit 2; }
	@recipient="$$(printf '%s\n' "$$TF_VAR_sops_age_key" | age-keygen -y)" && [ -n "$$recipient" ] || { echo "the age key (TF_VAR_sops_age_key, or the first key in SOPS_AGE_KEY_FILE) could not be read by age-keygen" >&2; exit 2; }; \
	rules="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not)] | length' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	missing="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not) | select((.age // "") | split(",") | map(trim) | any_c(. == strenv(R)) | not) | .path_regex] | join(" ")' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ "$$rules" -gt 0 ] || { echo "no platform rules in $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ -z "$$missing" ] || { echo "the age key is $$recipient - not a recipient of: $$missing (.sops.yaml): Flux could not decrypt flux/secrets" >&2; exit 2; }

# Terraform (the token from DIGITALOCEAN_CONFIG) and kubectl (doctl with the same file) use one token, so the
# plan's identity check covers both. Here the tools, and that doctl answers for the expected account - one
# read-only call. destroy needs the same before its pre-destroy hook: without doctl the hook reaches
# nothing, and the volumes, the load balancer and the DNS records stay behind.
access: settings ## The tools and doctl's account (one read-only call)
	@for t in "$(DOCTL)" kubectl jq yq; do command -v "$$t" >/dev/null || { echo "missing: $$t (docs/digitalocean.md, prerequisites)" >&2; exit 2; }; done
	@uuid="$$("$(DOCTL)" --context default account get --format UUID --no-header 2>/dev/null)" \
	  || { echo "doctl cannot sign in with $$DIGITALOCEAN_CONFIG (token expired or revoked?) - docs/digitalocean.md, step 2" >&2; exit 2; }; \
	[ "$$uuid" = "$$TF_VAR_expected_account_uuid" ] || { echo "doctl's token belongs to account $$uuid, expected $$TF_VAR_expected_account_uuid" >&2; exit 2; }

preflight: keycheck access ## The settings and age key, the tools and doctl's account

init: ## Terraform init (state in R2)
	@$(TF) init -input=false >/dev/null

plan: preflight init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan
	@$(TF) show -no-color tfplan | grep -E '^Plan:|^No changes' || true

apply: preflight ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)

# Terraform asks before it destroys; AUTO_APPROVE=1 skips the question (CI, or a confirmed teardown).
# The order mirrors aks_cluster's destroy:
#   0. kubeconfig.yaml, written again from the live cluster - the hook below reaches the cluster only
#      through it, and a file this checkout lacks (it is git-ignored) or kept from an earlier cluster of
#      the same name (another endpoint and CA) would leave the volumes, the load balancer and the DNS
#      records behind. doctl writes it to a new file (read-only calls, no token in it; on a failure the old
#      file is left as it was); kubectl then writes the exec in full - the same command, arguments
#      (--context=default) and DIGITALOCEAN_CONFIG as main.tf's kubeconfig: --exec-command alone drops
#      doctl's arguments (2026-10-23: args null, the hook found the cluster unreachable) - gives the context
#      its fixed name, and the new file must reach the API before it replaces the old one. Never `terraform apply -target=local_file.kubeconfig`: a target brings the
#      cluster into an apply nobody planned or approved;
#   1. the pre-destroy hook alone (flux.tf: volumes, Traefik's load balancer Service, Flux) while the
#      cluster, its CSI driver and cloud controller run; -refresh=false: a refresh would read the
#      Kubernetes objects it depends on, and an unreachable API would stop the whole teardown here;
#   2. the Kubernetes objects, the Flux null_resources and metrics-server's Helm release leave the state -
#      the cluster goes anyway, and an unreachable API must not stop the destroy of what is billed;
#   3. terraform destroy (it waits for the nodes to leave the VPC before deleting it - main.tf
#      terraform_data.vpc_empty); then kubeconfig.yaml goes - step 0 rewrote it, so local_file no longer knows it;
#   4. leftovers, whatever the destroy returned - the script itself, so its own exit status counts; after a
#      successful destroy with --settle (DigitalOcean deletes the load balancers and volumes in the
#      background); a failed destroy keeps its own exit status.
# `access` first: no destroy starts without the tools and the token the hook needs.
destroy: access init ## Destroy the cluster (asks; AUTO_APPROVE=1 does not), then look for leftovers
	@{ \
	  rm -f kubeconfig.yaml.new && \
	  id="$$("$(DOCTL)" --context default kubernetes cluster get "$(CLUSTER)" --format ID --no-header)" && [ -n "$$id" ] && \
	  KUBECONFIG=kubeconfig.yaml.new "$(DOCTL)" --context default kubernetes cluster kubeconfig save "$$id" --set-current-context >/dev/null && \
	  user="$$(kubectl config view --kubeconfig kubeconfig.yaml.new -o jsonpath='{.contexts[0].context.user}')" && [ -n "$$user" ] && \
	  kubectl config set-credentials "$$user" --kubeconfig kubeconfig.yaml.new \
	    --exec-api-version client.authentication.k8s.io/v1beta1 --exec-command "$(DOCTL)" \
	    --exec-arg=kubernetes --exec-arg=cluster --exec-arg=kubeconfig --exec-arg=exec-credential \
	    --exec-arg=--version=v1beta1 --exec-arg=--context=default --exec-arg="$$id" \
	    --exec-env "DIGITALOCEAN_CONFIG=$$DIGITALOCEAN_CONFIG" --exec-interactive-mode Never >/dev/null && \
	  kubectl config rename-context "$$(kubectl config current-context --kubeconfig kubeconfig.yaml.new)" \
	    "doks-$(CLUSTER)-control-plane" --kubeconfig kubeconfig.yaml.new >/dev/null && \
	  ! grep -qE '^ *(token|client-key-data):' kubeconfig.yaml.new && \
	  kubectl version --kubeconfig kubeconfig.yaml.new --request-timeout=30s >/dev/null && \
	  chmod 600 kubeconfig.yaml.new && mv kubeconfig.yaml.new kubeconfig.yaml; \
	} || { rm -f kubeconfig.yaml.new; echo "WARNING: could not write kubeconfig.yaml (no cluster $(CLUSTER)?) - the pre-destroy hook cannot reach the cluster; check make leftovers" >&2; }
	@$(TF) destroy -refresh=false -target='terraform_data.flux_pre_destroy' $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,)
	@for r in $$($(TF) state list | grep -E '^(kubernetes_|null_resource\.flux_|helm_release\.)'); do $(TF) state rm "$$r" >/dev/null; done
	@rc=0; $(TF) destroy $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,) || rc=$$?; \
	if [ $$rc -eq 0 ]; then rm -f kubeconfig.yaml; settle=--settle; else settle=; fi; \
	$(LEFTOVERS) $$settle "$(CLUSTER)"; check=$$?; \
	if [ $$rc -ne 0 ]; then exit $$rc; fi; exit $$check

# What can outlive a cluster and keep costing, in the whole team - scripts/doks-leftovers.sh lists it
# (exit 1 when anything is left, 2 when a query failed; make itself then exits 2 either way).
leftovers: ## List billable leftovers in the team (fails when any is left or a query failed)
	@$(LEFTOVERS) "$(CLUSTER)"
