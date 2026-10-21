# The AKS cluster - created for a test cycle and destroyed after it (docs/azure.md). Settings come from
# ENV_FILE (default .env.azure in the repository root, git-ignored; template .env.azure.example) or your
# shell: AZURE_CONFIG_DIR, TF_VAR_subscription_id, TF_VAR_tenant_id, TF_VAR_expected_principal_object_id,
# the R2 state key (R2_* or AWS_*), SOPS_AGE_KEY_FILE (the platform's age key Flux decrypts flux/secrets
# with), TF_VAR_uptrace_dsn, the backup bucket's TF_VAR_backup_s3_* and AZURE_KUBELOGIN.
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

ENV_FILE ?= ../../../.env.azure
-include $(ENV_FILE)
export TF_VAR_subscription_id TF_VAR_tenant_id TF_VAR_expected_principal_object_id TF_VAR_uptrace_dsn
# The CNPG backup bucket (Cloudflare R2) and its bucket-scoped key.
export TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key
# The Azure CLI's own directory (see azure_foundation/Makefile): Terraform, kubelogin and so kubectl sign in through it.
export AZURE_CONFIG_DIR
# Azure kubelogin: a full path when Homebrew's int128 kubelogin comes first in PATH (variables.tf).
AZURE_KUBELOGIN ?= kubelogin
export TF_VAR_kubelogin := $(AZURE_KUBELOGIN)
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
# Azure credentials in the environment would win over the CLI sign-in (see azure_foundation/Makefile).
unexport ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_CLIENT_CERTIFICATE_PATH ARM_USE_OIDC ARM_USE_MSI ARM_OIDC_TOKEN ARM_SUBSCRIPTION_ID ARM_TENANT_ID

CLUSTER := $(shell sed -n 's/^cluster_name *= *"\([^"]*\)".*/\1/p' terraform.tfvars)
# The foundation's resource group, and the one AKS keeps the nodes in (main.tf local.node_resource_group).
RG       := $(CLUSTER)-aks
NODES_RG := $(CLUSTER)-aks-nodes
AZ       := az --subscription "$(TF_VAR_subscription_id)" --output tsv

.PHONY: help settings keycheck preflight init plan apply destroy leftovers

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

# What Terraform needs for any run.
settings: ## Check that every setting is there (no cloud calls)
	@missing=""; \
	for v in AZURE_CONFIG_DIR TF_VAR_subscription_id TF_VAR_tenant_id TF_VAR_expected_principal_object_id AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
	         TF_VAR_uptrace_dsn TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key; do \
	  [ -n "$${!v:-}" ] || missing="$$missing $$v"; done; \
	[ -n "$${TF_VAR_sops_age_key:-}" ] || missing="$$missing SOPS_AGE_KEY_FILE($(if $(SOPS_AGE_KEY_FILE),$(SOPS_AGE_KEY_FILE) not readable,not set))"; \
	[ -z "$$missing" ] || { echo "missing:$$missing - set them in $(ENV_FILE) (template: .env.azure.example)" >&2; exit 2; }
	@test -n "$(CLUSTER)" || { echo "no cluster_name in terraform.tfvars" >&2; exit 2; }

# The key Terraform sends must decrypt what this cluster's Flux decrypts (see gke_cluster/Makefile).
keycheck: settings ## The age key is a recipient of every platform rule in .sops.yaml (no cloud calls)
	@command -v age-keygen >/dev/null || { echo "missing: age-keygen (to check the age key against .sops.yaml)" >&2; exit 2; }
	@command -v yq >/dev/null || { echo "missing: yq v4 (to read .sops.yaml)" >&2; exit 2; }
	@recipient="$$(printf '%s\n' "$$TF_VAR_sops_age_key" | age-keygen -y)" && [ -n "$$recipient" ] || { echo "the age key (TF_VAR_sops_age_key, or the first key in SOPS_AGE_KEY_FILE) could not be read by age-keygen" >&2; exit 2; }; \
	rules="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not)] | length' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	missing="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not) | select((.age // "") | split(",") | map(trim) | any_c(. == strenv(R)) | not) | .path_regex] | join(" ")' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ "$$rules" -gt 0 ] || { echo "no platform rules in $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ -z "$$missing" ] || { echo "the age key is $$recipient - not a recipient of: $$missing (.sops.yaml): Flux could not decrypt flux/secrets" >&2; exit 2; }

# Terraform (versions.tf) and kubectl (kubeconfig.yaml) sign in through the same Azure CLI sign-in, so one
# identity check - the plan's postcondition - covers both. Here only what is local: the tools, the CLI's
# subscription and tenant (its local cache), and that AZURE_KUBELOGIN is Azure's kubelogin - int128's
# tool of the same name has no `get-token --server-id` and would fail every kubectl call.
preflight: keycheck ## The settings and age key, the tools, the Azure CLI sign-in and Azure kubelogin (no cloud calls)
	@for t in az kubectl jq; do command -v $$t >/dev/null || { echo "missing: $$t (docs/azure.md, prerequisites)" >&2; exit 2; }; done
	@account="$$(az account show --subscription "$$TF_VAR_subscription_id" --output json 2>/dev/null)" \
	  || { echo "the Azure CLI (AZURE_CONFIG_DIR=$$AZURE_CONFIG_DIR) is not signed in to subscription $$TF_VAR_subscription_id - az login --tenant $$TF_VAR_tenant_id (docs/azure.md, step 2)" >&2; exit 2; }; \
	tenant="$$(jq -r .tenantId <<<"$$account")"; \
	[ "$$tenant" = "$$TF_VAR_tenant_id" ] || { echo "subscription $$TF_VAR_subscription_id is in tenant $$tenant, expected $$TF_VAR_tenant_id" >&2; exit 2; }
	@help="$$("$(AZURE_KUBELOGIN)" get-token --help 2>&1)" || { echo "AZURE_KUBELOGIN=$(AZURE_KUBELOGIN) does not run get-token - install Azure kubelogin (docs/azure.md, prerequisites)" >&2; exit 2; }; \
	grep -q -- '--server-id' <<<"$$help" || { echo "AZURE_KUBELOGIN=$(AZURE_KUBELOGIN) is not Azure kubelogin (no get-token --server-id) - Homebrew's kubelogin is int128's; set a full path (docs/azure.md, prerequisites)" >&2; exit 2; }

init: ## Terraform init (state in R2)
	@$(TF) init -input=false >/dev/null

plan: preflight init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan
	@$(TF) show -no-color tfplan | grep -E '^Plan:|^No changes' || true

apply: preflight ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)

# Terraform asks before it destroys; AUTO_APPROVE=1 skips the question (CI, or a confirmed teardown).
# The order mirrors eks_cluster's destroy:
#   0. kubeconfig.yaml, written again from the live cluster - the hook below reaches the cluster only
#      through it, and a file this checkout lacks (it is git-ignored) or kept from an earlier cluster of
#      the same name (another endpoint and CA) would leave the volumes and the DNS records behind. The
#      Azure CLI writes it to a new file (read-only calls; on a failure the old file is left as it was),
#      kubectl then gives its user Azure kubelogin by AZURE_KUBELOGIN's path - `az aks get-credentials`
#      names a bare `kubelogin`, which may be int128's. Never `terraform apply -target=local_file.kubeconfig`:
#      a target brings the cluster into an apply nobody planned or approved;
#   1. the pre-destroy hook alone (flux.tf: volumes, Traefik's load balancer Service, Flux) while the
#      cluster and its CSI driver run;
#   2. the Kubernetes objects and the Flux null_resources leave the state - the cluster goes anyway, and
#      an unreachable API must not stop the destroy of what is billed (nodes, load balancer, addresses);
#   3. terraform destroy;
#   4. leftovers, whatever the destroy returned; a failed destroy keeps its own exit status.
destroy: settings init ## Destroy the cluster (asks; AUTO_APPROVE=1 does not), then look for leftovers
	@for t in az kubectl jq; do command -v $$t >/dev/null || echo "WARNING: no $$t - the pre-destroy hook cannot clean the cluster (volumes, DNS records); check make leftovers" >&2; done
	@{ \
	  $(AZ) aks get-credentials --resource-group "$(RG)" --name "$(CLUSTER)" --file kubeconfig.yaml.new \
	    --context "aks-$(CLUSTER)-control-plane" --overwrite-existing >/dev/null && \
	  user="$$(kubectl config view --kubeconfig kubeconfig.yaml.new -o jsonpath='{.contexts[0].context.user}')" && [ -n "$$user" ] && \
	  kubectl config set-credentials "$$user" --kubeconfig kubeconfig.yaml.new \
	    --exec-api-version client.authentication.k8s.io/v1beta1 --exec-command "$(AZURE_KUBELOGIN)" \
	    --exec-arg=get-token --exec-arg=--login --exec-arg=azurecli \
	    --exec-arg=--server-id --exec-arg=6dae42f8-4368-4678-94ff-3960e28e3630 >/dev/null && \
	  chmod 600 kubeconfig.yaml.new && mv kubeconfig.yaml.new kubeconfig.yaml; \
	} || { rm -f kubeconfig.yaml.new; echo "WARNING: could not write kubeconfig.yaml (no cluster $(CLUSTER)?) - the pre-destroy hook cannot reach the cluster; check make leftovers" >&2; }
	@$(TF) destroy -target='terraform_data.flux_pre_destroy' $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,)
	@for r in $$($(TF) state list | grep -E '^(kubernetes_|null_resource\.flux_)'); do $(TF) state rm "$$r" >/dev/null; done
	@rc=0; $(TF) destroy $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,) || rc=$$?; \
	$(MAKE) --no-print-directory leftovers; check=$$?; \
	if [ $$rc -ne 0 ]; then exit $$rc; fi; exit $$check

# What can outlive a cluster and keep costing, in the whole subscription: the cluster itself, anything in
# its group but the foundation's deployer identity (the log workspace), the node resource group (nodes,
# load balancer, addresses), and - wherever they are - disks and snapshots (a PersistentVolume's disk),
# public IPs, load balancers, virtual networks and Log Analytics workspaces. The subscription holds
# nothing else billable, so whatever these list is a leftover. Exit 1 when anything is left, 2 when a
# query failed: an error never reads as "nothing left".
leftovers: ## List billable leftovers in the subscription (exit 1 when any, 2 when a query failed)
	@left=0; failed=0; \
	check() { \
	  local what="$$1" out; shift; \
	  if ! out="$$($(AZ) "$$@")"; then failed=1; echo "FAIL could not list $$what (az error above)" >&2; return; fi; \
	  if [ -n "$$out" ]; then left=1; echo "LEFT $$what: $$(tr '\t\n' '  ' <<<"$$out")"; fi; \
	}; \
	check "AKS clusters"            aks list --query '[].name'; \
	check "resources in $(RG)"      resource list --resource-group "$(RG)" --query "[?type!='Microsoft.ManagedIdentity/userAssignedIdentities'].name"; \
	check "node resource group"     group list --query "[?name=='$(NODES_RG)'].name"; \
	check "disks"                   disk list --query '[].name'; \
	check "snapshots"               snapshot list --query '[].name'; \
	check "public IPs"              network public-ip list --query '[].name'; \
	check "load balancers"          network lb list --query '[].name'; \
	check "virtual networks"        network vnet list --query '[].name'; \
	check "Log Analytics workspaces" monitor log-analytics workspace list --query '[].name'; \
	if [ $$failed = 1 ]; then exit 2; fi; \
	if [ $$left = 0 ]; then echo "OK   nothing left in subscription $$TF_VAR_subscription_id"; else exit 1; fi
