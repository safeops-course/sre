# The GKE cluster - created for a test cycle and destroyed after it (docs/gcp.md). Settings come from
# ENV_FILE (default .env.gcp in the repository root, git-ignored) or your shell: TF_VAR_expected_principal,
# GOOGLE_APPLICATION_CREDENTIALS, the R2 state key (R2_* or AWS_*), SOPS_AGE_KEY_FILE (the platform's age
# key Flux decrypts flux/secrets with), TF_VAR_uptrace_dsn.
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

ENV_FILE ?= ../../../.env.gcp
-include $(ENV_FILE)
export TF_VAR_expected_principal GOOGLE_APPLICATION_CREDENTIALS TF_VAR_uptrace_dsn
# The CNPG backup bucket (Cloudflare R2) and its bucket-scoped key.
export TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key
# The age key goes to Terraform as an ephemeral variable (never in the plan or the state); every run
# needs it - plan, apply and destroy. Read from the file, so it is never typed or kept in an env file.
# No default path: a workstation can hold several age keys, and the wrong one fails only inside the
# cluster, when Flux cannot decrypt. `settings` checks the key against the recipients in .sops.yaml.
# Only the AGE-SECRET-KEY-... line: the file also holds comment lines, and $(shell) joins lines with
# spaces - the whole file became one line starting with "#", which age cannot read (seen 2026-10-15:
# every secrets-* Kustomization failed with "cannot get sops data key").
# A TF_VAR_sops_age_key from your shell or ENV_FILE wins (CI); otherwise the first key line of the file
# (several keys would be joined by spaces), read once (:=). [A-Z0-9-]: age's post-quantum identities
# are AGE-SECRET-KEY-PQ-1...
ifndef TF_VAR_sops_age_key
TF_VAR_sops_age_key := $(if $(SOPS_AGE_KEY_FILE),$(shell grep -m1 -oE 'AGE-SECRET-KEY-[A-Z0-9-]+' "$(SOPS_AGE_KEY_FILE)" 2>/dev/null))
endif
export TF_VAR_sops_age_key
SOPS_CONFIG := ../../../.sops.yaml
ifneq ($(R2_ACCESS_KEY_ID),)
export AWS_ACCESS_KEY_ID     := $(R2_ACCESS_KEY_ID)
export AWS_SECRET_ACCESS_KEY := $(R2_SECRET_ACCESS_KEY)
endif

GCP_PROJECT := $(shell sed -n 's/^project_id *= *"\(.*\)".*/\1/p' terraform.tfvars)

.PHONY: help settings keycheck preflight init plan apply destroy leftovers

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

# What Terraform needs for any run.
settings: ## Check that every setting is there (no cloud calls)
	@missing=""; \
	for v in TF_VAR_expected_principal AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_VAR_uptrace_dsn \
	         TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key; do [ -n "$${!v:-}" ] || missing="$$missing $$v"; done; \
	[ -n "$${TF_VAR_sops_age_key:-}" ] || missing="$$missing SOPS_AGE_KEY_FILE($(if $(SOPS_AGE_KEY_FILE),$(SOPS_AGE_KEY_FILE) not readable,not set))"; \
	[ -z "$$missing" ] || { echo "missing:$$missing - set them in $(ENV_FILE) (template: .env.gcp.example)" >&2; exit 2; }

# The key Terraform sends must decrypt what this cluster's Flux decrypts: a recipient of every platform
# rule in .sops.yaml (all but flux/secrets/local, the learner's own key), read with yq - not a text
# search, which a comment or the local rule would satisfy. A failed age-keygen stops here: an empty
# recipient must never pass.
keycheck: settings ## The age key is a recipient of every platform rule in .sops.yaml (no cloud calls)
	@command -v age-keygen >/dev/null || { echo "missing: age-keygen (to check the age key against .sops.yaml)" >&2; exit 2; }
	@command -v yq >/dev/null || { echo "missing: yq v4 (to read .sops.yaml)" >&2; exit 2; }
	@recipient="$$(printf '%s\n' "$$TF_VAR_sops_age_key" | age-keygen -y)" && [ -n "$$recipient" ] || { echo "the age key (TF_VAR_sops_age_key, or the first key in SOPS_AGE_KEY_FILE) could not be read by age-keygen" >&2; exit 2; }; \
	rules="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not)] | length' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	missing="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not) | select((.age // "") | split(",") | map(trim) | any_c(. == strenv(R)) | not) | .path_regex] | join(" ")' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ "$$rules" -gt 0 ] || { echo "no platform rules in $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ -z "$$missing" ] || { echo "the age key is $$recipient - not a recipient of: $$missing (.sops.yaml): Flux could not decrypt flux/secrets" >&2; exit 2; }

# kubectl through kubeconfig.yaml - the Flux bootstrap and the pre-destroy hook (flux.tf) - needs the
# auth plugin, and the plugin signs in as gcloud's active account: it must be the expected identity,
# or kubectl gets a 403 halfway through an apply or a destroy. Both are local checks.
preflight: keycheck ## The settings and age key, gke-gcloud-auth-plugin and gcloud's account (no cloud calls)
	@command -v gke-gcloud-auth-plugin >/dev/null || { echo "missing: gke-gcloud-auth-plugin (gcloud components install gke-gcloud-auth-plugin)" >&2; exit 2; }
	@account="$$(gcloud config get account 2>/dev/null)"; \
	[ "$$account" = "$$TF_VAR_expected_principal" ] || { echo "gcloud's active account is '$$account', expected $$TF_VAR_expected_principal - kubectl would sign in as it (CLOUDSDK_CONFIG, gcloud config set account)" >&2; exit 2; }

init: ## Terraform init (state in R2)
	@$(TF) init -input=false >/dev/null

plan: preflight init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan
	@$(TF) show -no-color tfplan | grep -E '^Plan:|^No changes' || true

apply: preflight ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)

# Terraform asks before it destroys; AUTO_APPROVE=1 skips the question (CI, or a confirmed teardown).
# A teardown is never refused for what only its cleanup needs: without the auth plugin or with another
# gcloud account the pre-destroy hook cannot reach the cluster - a warning, and `leftovers` shows what
# that left behind. The order mirrors hcloud_cluster's destroy:
#   1. the pre-destroy hook alone (flux.tf: volumes, load balancer, Flux) while the cluster runs;
#      -refresh=false: a refresh would read the Kubernetes objects it depends on, and an unreachable API
#      would stop the whole teardown here (the hook itself never fails it - on_failure = continue);
#   2. the Kubernetes objects and the Flux null_resources leave the state - the cluster goes anyway, and
#      an unreachable API must not stop the destroy of what is billed (nodes, NAT, network);
#   3. terraform destroy;
#   4. leftovers, whatever the destroy returned; a failed destroy keeps its own exit status.
destroy: settings init ## Destroy the cluster and its network (asks; AUTO_APPROVE=1 does not), then look for leftovers
	@command -v gke-gcloud-auth-plugin >/dev/null || echo "WARNING: no gke-gcloud-auth-plugin - the pre-destroy hook cannot reach the cluster; check make leftovers" >&2
	@account="$$(gcloud config get account 2>/dev/null)"; [ "$$account" = "$$TF_VAR_expected_principal" ] || echo "WARNING: gcloud's account is '$$account', not $$TF_VAR_expected_principal - the pre-destroy hook may be refused; check make leftovers" >&2
	@$(TF) destroy -refresh=false -target='terraform_data.flux_pre_destroy' $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,)
	@for r in $$($(TF) state list | grep -E '^(kubernetes_|null_resource\.flux_)'); do $(TF) state rm "$$r" >/dev/null; done
	@rc=0; $(TF) destroy $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,) || rc=$$?; \
	$(MAKE) --no-print-directory leftovers; check=$$?; \
	if [ $$rc -ne 0 ]; then exit $$rc; fi; exit $$check

# What can outlive a cluster and keep costing: disks of PersistentVolumes (GKE keeps them), load
# balancer forwarding rules and addresses of LoadBalancer Services, NEGs, and firewall rules GKE or a
# controller created. Exit 1 when anything is left, 2 when a query failed: an error never reads as
# "nothing left".
leftovers: ## List billable leftovers in the project (exit 1 when any, 2 when a query failed)
	@left=0; failed=0; \
	for kind in "compute disks" "compute forwarding-rules" "compute target-pools" "compute addresses" \
	            "compute network-endpoint-groups" "compute firewall-rules" "compute routers" "compute networks" \
	            "container clusters"; do \
	  if ! out="$$(gcloud $$kind list --project=$(GCP_PROJECT) --format='value(name)')"; then \
	    failed=1; echo "FAIL could not list $$kind (gcloud error above)" >&2; continue; fi; \
	  if [ -n "$$out" ]; then left=1; echo "LEFT $$kind: $$(tr '\n' ' ' <<<"$$out")"; fi; \
	done; \
	if [ $$failed = 1 ]; then exit 2; fi; \
	if [ $$left = 0 ]; then echo "OK   nothing left in $(GCP_PROJECT)"; else exit 1; fi
