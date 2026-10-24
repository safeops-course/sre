# The SKS cluster (Exoscale) - created for a test cycle and destroyed after it (docs/exoscale.md). Settings come
# from ENV_FILE (default .env.sks in the repository root, git-ignored; template .env.sks.example) or your shell:
# EXOSCALE_CONFIG (exo's config file with the API key), TF_VAR_expected_default_security_group_id, the R2 state
# key (R2_* or AWS_*), SOPS_AGE_KEY_FILE (the platform's age key Flux decrypts flux/secrets with),
# TF_VAR_uptrace_dsn, the backup bucket's TF_VAR_backup_s3_* and EXO.
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

ENV_FILE ?= ../../../.env.sks
-include $(ENV_FILE)
export TF_VAR_expected_default_security_group_id TF_VAR_uptrace_dsn
# The CNPG backup bucket (Cloudflare R2) and its bucket-scoped key.
export TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key
# exo's own config file - never its default one. exo reads the variable itself; the kubeconfig's exec names
# it (variables.tf exo_config), and Terraform's provider gets the key from it below.
export EXOSCALE_CONFIG
export TF_VAR_exo_config := $(EXOSCALE_CONFIG)
# exo itself (.env.sks EXO, a full path, or exo on PATH) - exported for scripts/sks-leftovers.sh too.
# $(or): an EXO= line left empty in .env.sks means exo on PATH, never an empty command.
EXO := $(or $(EXO),exo)
export EXO
export TF_VAR_exo := $(EXO)
# The API key and secret of the config's default account: Terraform's provider reads EXOSCALE_API_KEY and
# EXOSCALE_API_SECRET. Read from the file, never typed, never in .env.sks. An account named in the
# environment would make exo read another one - the config's default account is the one place.
ifneq ($(wildcard $(EXOSCALE_CONFIG)),)
EXO_ACCOUNT_QUERY := .defaultaccount as $$d | .accounts[] | select(.name == $$d)
export EXOSCALE_API_KEY    := $(shell yq -p toml -o yaml '$(EXO_ACCOUNT_QUERY) | .key // ""' "$(EXOSCALE_CONFIG)" 2>/dev/null)
export EXOSCALE_API_SECRET := $(shell yq -p toml -o yaml '$(EXO_ACCOUNT_QUERY) | .secret // ""' "$(EXOSCALE_CONFIG)" 2>/dev/null)
endif
unexport EXOSCALE_ACCOUNT
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
ZONE      := $(shell sed -n 's/^zone *= *"\([^"]*\)".*/\1/p' terraform.tfvars)
VERSION   := $(shell sed -n 's/^kubernetes_version *= *"\([^"]*\)".*/\1/p' terraform.tfvars)
LEFTOVERS := ../../../scripts/sks-leftovers.sh

.PHONY: help settings keycheck access release preflight init plan apply destroy leftovers

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

# What Terraform needs for any run.
settings: ## Check that every setting is there (no cloud calls)
	@missing=""; \
	for v in EXOSCALE_CONFIG TF_VAR_expected_default_security_group_id AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
	         TF_VAR_uptrace_dsn TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key; do \
	  [ -n "$${!v:-}" ] || missing="$$missing $$v"; done; \
	[ -n "$${TF_VAR_sops_age_key:-}" ] || missing="$$missing SOPS_AGE_KEY_FILE($(if $(SOPS_AGE_KEY_FILE),$(SOPS_AGE_KEY_FILE) not readable,not set))"; \
	[ -z "$$missing" ] || { echo "missing:$$missing - set them in $(ENV_FILE) (template: .env.sks.example)" >&2; exit 2; }
	@test -n "$(CLUSTER)" && test -n "$(ZONE)" && test -n "$(VERSION)" || { echo "no cluster_name, zone or kubernetes_version in terraform.tfvars" >&2; exit 2; }
	@case "$$EXOSCALE_CONFIG" in /*) ;; *) echo "EXOSCALE_CONFIG must be a full path (it is written into kubeconfig.yaml): $$EXOSCALE_CONFIG" >&2; exit 2 ;; esac
	@[ -f "$$EXOSCALE_CONFIG" ] || { echo "no exo config at $$EXOSCALE_CONFIG - EXOSCALE_CONFIG=... exo config add (docs/exoscale.md, step 2)" >&2; exit 2; }
	@[ -n "$${EXOSCALE_API_KEY:-}" ] && [ -n "$${EXOSCALE_API_SECRET:-}" ] || { echo "no key and secret of the default account in $$EXOSCALE_CONFIG (or no yq v4 to read it) - exo config add with EXOSCALE_CONFIG set (docs/exoscale.md, step 2)" >&2; exit 2; }

# The key Terraform sends must decrypt what this cluster's Flux decrypts (see gke_cluster/Makefile).
keycheck: settings ## The age key is a recipient of every platform rule in .sops.yaml (no cloud calls)
	@command -v age-keygen >/dev/null || { echo "missing: age-keygen (to check the age key against .sops.yaml)" >&2; exit 2; }
	@command -v yq >/dev/null || { echo "missing: yq v4 (to read .sops.yaml)" >&2; exit 2; }
	@recipient="$$(printf '%s\n' "$$TF_VAR_sops_age_key" | age-keygen -y)" && [ -n "$$recipient" ] || { echo "the age key (TF_VAR_sops_age_key, or the first key in SOPS_AGE_KEY_FILE) could not be read by age-keygen" >&2; exit 2; }; \
	rules="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not)] | length' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	missing="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not) | select((.age // "") | split(",") | map(trim) | any_c(. == strenv(R)) | not) | .path_regex] | join(" ")' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ "$$rules" -gt 0 ] || { echo "no platform rules in $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ -z "$$missing" ] || { echo "the age key is $$recipient - not a recipient of: $$missing (.sops.yaml): Flux could not decrypt flux/secrets" >&2; exit 2; }

# Terraform (the key from EXOSCALE_CONFIG) and kubectl (exo with the same file) use one key, so the plan's
# identity check covers both. Here the tools and that exo answers for the expected organization - read-only
# calls. destroy needs the same before its pre-destroy hook: without exo the hook reaches nothing, and the
# volumes, the load balancer and the DNS records stay behind.
access: settings ## The tools and exo's organization (read-only calls)
	@for t in "$(EXO)" kubectl jq yq; do command -v "$$t" >/dev/null || { echo "missing: $$t (docs/exoscale.md, prerequisites)" >&2; exit 2; }; done
	@sg="$$("$(EXO)" compute security-group show default -O json 2>/dev/null | jq -r '.id // ""')" && [ -n "$$sg" ] \
	  || { echo "exo cannot sign in with $$EXOSCALE_CONFIG (key revoked, or its role lacks compute?) - docs/exoscale.md, steps 1-2" >&2; exit 2; }; \
	[ "$$sg" = "$$TF_VAR_expected_default_security_group_id" ] || { echo "exo's key belongs to the organization with default security group $$sg, expected $$TF_VAR_expected_default_security_group_id" >&2; exit 2; }

# SKS still offers kubernetes_version in the zone - for a new cluster only (plan, apply). Never for destroy:
# Exoscale drops a release when a newer patch comes, and a running cluster must stay destroyable. exo's
# answer is read first, then searched: a failed call says so, never "no longer offers".
release: settings ## SKS still offers kubernetes_version in the zone (one read-only call)
	@json="$$("$(EXO)" compute sks versions --zone "$(ZONE)" -O json)" || { echo "could not list the SKS versions of $(ZONE) (exo error above)" >&2; exit 2; }; \
	versions="$$(jq -r '.[].version' <<<"$$json")" && [ -n "$$versions" ] || { echo "could not read the SKS versions of $(ZONE): $$json" >&2; exit 2; }; \
	grep -qxF "$(VERSION)" <<<"$$versions" || { echo "SKS in $(ZONE) no longer offers kubernetes_version $(VERSION) - it offers: $$(tr '\n' ' ' <<<"$$versions")(terraform.tfvars)" >&2; exit 2; }

preflight: keycheck access release ## The settings and age key, the tools, exo's organization and the release

init: ## Terraform init (state in R2)
	@$(TF) init -input=false >/dev/null

plan: preflight init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan
	@$(TF) show -no-color tfplan | grep -E '^Plan:|^No changes' || true

apply: preflight ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)

# Terraform asks before it destroys; AUTO_APPROVE=1 skips the question (CI, or a confirmed teardown).
# The order mirrors doks_cluster's destroy:
#   0. kubeconfig.yaml, written again from the live cluster - the hook below reaches the cluster only
#      through it, and a file this checkout lacks (it is git-ignored) or kept from an earlier cluster of
#      the same name (another endpoint and CA) would leave the volumes, the load balancer and the DNS
#      records behind. exo reads the endpoint and the control plane's certificate authority (read-only
#      calls); kubectl writes a new file with the same exec as main.tf's kubeconfig (exo, its arguments and
#      EXOSCALE_CONFIG) and the fixed context name; the new file must reach the API before it replaces the
#      old one (on a failure the old file is left as it was). Never `terraform apply
#      -target=local_file.kubeconfig`: a target brings the cluster into an apply nobody planned or approved;
#   1. the pre-destroy hook alone (flux.tf: volumes, Traefik's load balancer Service, Flux) while the
#      cluster, its CSI driver and cloud controller run; -refresh=false: a refresh would read the
#      Kubernetes objects it depends on, and an unreachable API would stop the whole teardown here;
#   2. the Kubernetes objects and the Flux null_resources leave the state - the cluster goes anyway, and an
#      unreachable API must not stop the destroy of what is billed;
#   3. terraform destroy with read_cluster_api=false: the API server's port (flux.tf) is not read, so an
#      unreachable API cannot stop it; then kubeconfig.yaml goes - step 0 rewrote it, so local_file no longer
#      knows it;
#   4. leftovers, whatever the destroy returned - the script itself, so its own exit status counts; after a
#      successful destroy with --settle (Exoscale may still be deleting the load balancer and the volumes);
#      a failed destroy keeps its own exit status.
# `access` first: no destroy starts without the tools and the key the hook needs.
destroy: access init ## Destroy the cluster (asks; AUTO_APPROVE=1 does not), then look for leftovers
	@{ \
	  rm -f kubeconfig.yaml.new kubeconfig.ca.pem && \
	  show="$$("$(EXO)" compute sks show "$(CLUSTER)" --zone "$(ZONE)" -O json)" && \
	  id="$$(jq -r '.id // ""' <<<"$$show")" && endpoint="$$(jq -r '.endpoint // ""' <<<"$$show")" && \
	  [ -n "$$id" ] && [ -n "$$endpoint" ] && \
	  "$(EXO)" compute sks authority-cert "$$id" control-plane --zone "$(ZONE)" > kubeconfig.ca.pem && \
	  kubectl config set-cluster "sks-$(CLUSTER)" --kubeconfig kubeconfig.yaml.new --server "https://$$endpoint:443" \
	    --certificate-authority kubeconfig.ca.pem --embed-certs >/dev/null && \
	  kubectl config set-credentials "sks-$(CLUSTER)" --kubeconfig kubeconfig.yaml.new \
	    --exec-api-version client.authentication.k8s.io/v1beta1 --exec-command "$(EXO)" \
	    --exec-arg=compute --exec-arg=sks --exec-arg=kubeconfig --exec-arg="$$id" --exec-arg=admin \
	    --exec-arg=--zone=$(ZONE) --exec-arg=--exec-credential \
	    --exec-env "EXOSCALE_CONFIG=$$EXOSCALE_CONFIG" --exec-interactive-mode Never >/dev/null && \
	  kubectl config set-context "sks-$(CLUSTER)-control-plane" --kubeconfig kubeconfig.yaml.new \
	    --cluster "sks-$(CLUSTER)" --user "sks-$(CLUSTER)" >/dev/null && \
	  kubectl config use-context "sks-$(CLUSTER)-control-plane" --kubeconfig kubeconfig.yaml.new >/dev/null && \
	  kubectl version --kubeconfig kubeconfig.yaml.new --request-timeout=30s >/dev/null && \
	  chmod 600 kubeconfig.yaml.new && mv kubeconfig.yaml.new kubeconfig.yaml && rm -f kubeconfig.ca.pem; \
	} || { rm -f kubeconfig.yaml.new kubeconfig.ca.pem; echo "WARNING: could not write kubeconfig.yaml (no cluster $(CLUSTER) in $(ZONE)?) - the pre-destroy hook cannot reach the cluster; check make leftovers" >&2; }
	@$(TF) destroy -refresh=false -target='terraform_data.flux_pre_destroy' $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,)
	@for r in $$($(TF) state list | grep -E '^(kubernetes_|null_resource\.flux_)'); do $(TF) state rm "$$r" >/dev/null; done
	@rc=0; $(TF) destroy -var read_cluster_api=false $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,) || rc=$$?; \
	if [ $$rc -eq 0 ]; then rm -f kubeconfig.yaml; settle=--settle; else settle=; fi; \
	$(LEFTOVERS) $$settle "$(CLUSTER)" "$(ZONE)"; check=$$?; \
	if [ $$rc -ne 0 ]; then exit $$rc; fi; exit $$check

# What can outlive a cluster and keep costing, in the cycle's zone - scripts/sks-leftovers.sh lists it
# (exit 1 when anything is left, 2 when a query failed; make itself then exits 2 either way).
leftovers: ## List billable leftovers in the cycle's zone (fails when any is left or a query failed)
	@$(LEFTOVERS) "$(CLUSTER)" "$(ZONE)"
