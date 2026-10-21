# The EKS cluster - created for a test cycle and destroyed after it (docs/aws.md). Settings come from
# ENV_FILE (default .env.aws in the repository root, git-ignored; template .env.aws.example) or your
# shell: TF_VAR_account_id, TF_VAR_aws_profile, TF_VAR_expected_principal_arn, the R2 state key (R2_* or
# AWS_*), SOPS_AGE_KEY_FILE (the platform's age key Flux decrypts flux/secrets with), TF_VAR_uptrace_dsn
# and the backup bucket's TF_VAR_backup_s3_*.
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

ENV_FILE ?= ../../../.env.aws
-include $(ENV_FILE)
export TF_VAR_account_id TF_VAR_aws_profile TF_VAR_expected_principal_arn TF_VAR_uptrace_dsn
# The CNPG backup bucket (Cloudflare R2) and its bucket-scoped key.
export TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key
# The age key, from the file, as an ephemeral variable - see gke_cluster/Makefile for why only the first
# AGE-SECRET-KEY- line, and why there is no default path.
ifndef TF_VAR_sops_age_key
TF_VAR_sops_age_key := $(if $(SOPS_AGE_KEY_FILE),$(shell grep -m1 -oE 'AGE-SECRET-KEY-[A-Z0-9-]+' "$(SOPS_AGE_KEY_FILE)" 2>/dev/null))
endif
export TF_VAR_sops_age_key
SOPS_CONFIG := ../../../.sops.yaml
# The S3 backend reads AWS_*; the R2 key is named R2_* in the env files. The aws provider, the kubernetes
# and helm providers and kubectl do not take it: each names its profile (versions.tf, kubeconfig.yaml).
ifneq ($(R2_ACCESS_KEY_ID),)
export AWS_ACCESS_KEY_ID     := $(R2_ACCESS_KEY_ID)
export AWS_SECRET_ACCESS_KEY := $(R2_SECRET_ACCESS_KEY)
endif
# Leftovers of another AWS session in the shell never reach Terraform or the CLI: a session token would be
# paired with the R2 key by the backend; the provider and the CLI name their profile themselves.
unexport AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE

AWS_REGION := $(shell sed -n 's/^region *= *"\([^"]*\)".*/\1/p' terraform.tfvars)
CLUSTER    := $(shell sed -n 's/^cluster_name *= *"\([^"]*\)".*/\1/p' terraform.tfvars)
# The AWS CLI as the profile, never with the R2 key (see aws_foundation/Makefile).
AWS := env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY aws --profile "$(TF_VAR_aws_profile)" --region "$(AWS_REGION)"

.PHONY: help settings keycheck preflight init plan apply destroy leftovers

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

# What Terraform needs for any run.
settings: ## Check that every setting is there (no cloud calls)
	@missing=""; \
	for v in TF_VAR_account_id TF_VAR_aws_profile TF_VAR_expected_principal_arn AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
	         TF_VAR_uptrace_dsn TF_VAR_backup_s3_bucket TF_VAR_backup_s3_access_key_id TF_VAR_backup_s3_secret_access_key; do \
	  [ -n "$${!v:-}" ] || missing="$$missing $$v"; done; \
	[ -n "$${TF_VAR_sops_age_key:-}" ] || missing="$$missing SOPS_AGE_KEY_FILE($(if $(SOPS_AGE_KEY_FILE),$(SOPS_AGE_KEY_FILE) not readable,not set))"; \
	[ -z "$$missing" ] || { echo "missing:$$missing - set them in $(ENV_FILE) (template: .env.aws.example)" >&2; exit 2; }
	@test -n "$(AWS_REGION)" || { echo "no region in terraform.tfvars" >&2; exit 2; }

# The key Terraform sends must decrypt what this cluster's Flux decrypts (see gke_cluster/Makefile).
keycheck: settings ## The age key is a recipient of every platform rule in .sops.yaml (no cloud calls)
	@command -v age-keygen >/dev/null || { echo "missing: age-keygen (to check the age key against .sops.yaml)" >&2; exit 2; }
	@command -v yq >/dev/null || { echo "missing: yq v4 (to read .sops.yaml)" >&2; exit 2; }
	@recipient="$$(printf '%s\n' "$$TF_VAR_sops_age_key" | age-keygen -y)" && [ -n "$$recipient" ] || { echo "the age key (TF_VAR_sops_age_key, or the first key in SOPS_AGE_KEY_FILE) could not be read by age-keygen" >&2; exit 2; }; \
	rules="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not)] | length' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	missing="$$(R="$$recipient" yq '[.creation_rules[] | select(.path_regex | contains("flux/secrets/local") | not) | select((.age // "") | split(",") | map(trim) | any_c(. == strenv(R)) | not) | .path_regex] | join(" ")' "$(SOPS_CONFIG)")" || { echo "could not read $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ "$$rules" -gt 0 ] || { echo "no platform rules in $(SOPS_CONFIG)" >&2; exit 2; }; \
	[ -z "$$missing" ] || { echo "the age key is $$recipient - not a recipient of: $$missing (.sops.yaml): Flux could not decrypt flux/secrets" >&2; exit 2; }

# Terraform (versions.tf) and kubectl (kubeconfig.yaml) sign in with the same profile, so one identity
# check - the plan's postcondition - covers both. Here only what is local: the tools and the profile.
preflight: keycheck ## The settings and age key, the tools and the AWS CLI profile (no cloud calls)
	@for t in aws kubectl jq; do command -v $$t >/dev/null || { echo "missing: $$t (docs/aws.md, prerequisites)" >&2; exit 2; }; done
	@profiles="$$(aws configure list-profiles)" || { echo "could not list the AWS CLI profiles (aws error above)" >&2; exit 2; }; \
	grep -qxF -- "$$TF_VAR_aws_profile" <<<"$$profiles" || { echo "no AWS CLI profile '$$TF_VAR_aws_profile' in $${AWS_CONFIG_FILE:-~/.aws/config} (docs/aws.md, step 2)" >&2; exit 2; }

init: ## Terraform init (state in R2)
	@$(TF) init -input=false >/dev/null

plan: preflight init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan
	@$(TF) show -no-color tfplan | grep -E '^Plan:|^No changes' || true

apply: preflight ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)

# Terraform asks before it destroys; AUTO_APPROVE=1 skips the question (CI, or a confirmed teardown).
# The order mirrors gke_cluster's destroy:
#   0. kubeconfig.yaml, if this checkout has none (it is git-ignored: a destroy from another checkout than
#      the apply's) - the hook below reaches the cluster only through it. The AWS CLI writes it (read-only
#      calls), never `terraform apply -target=local_file.kubeconfig`: a target brings its dependencies -
#      the cluster and the VPC - into an apply nobody planned or approved;
#   1. the pre-destroy hook alone (flux.tf: volumes, the NLB, Flux) while the cluster, the EBS CSI driver
#      and the Load Balancer Controller run;
#   2. the Kubernetes objects, the controller's Helm release and the Flux null_resources leave the
#      state - the cluster goes anyway, and an unreachable API must not stop the destroy of what is
#      billed (nodes, NAT gateway, VPC);
#   3. terraform destroy;
#   4. leftovers, whatever the destroy returned; a failed destroy keeps its own exit status.
destroy: settings init ## Destroy the cluster and its network (asks; AUTO_APPROVE=1 does not), then look for leftovers
	@for t in aws kubectl jq; do command -v $$t >/dev/null || echo "WARNING: no $$t - the pre-destroy hook cannot clean the cluster (NLB, volumes); check make leftovers" >&2; done
	@test -f kubeconfig.yaml || $(AWS) eks update-kubeconfig --name "$(CLUSTER)" --kubeconfig kubeconfig.yaml --alias "eks-$(CLUSTER)-control-plane" >/dev/null || echo "WARNING: could not write kubeconfig.yaml (no cluster $(CLUSTER)?) - the pre-destroy hook cannot reach the cluster; check make leftovers" >&2
	@$(TF) destroy -target='terraform_data.flux_pre_destroy' $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,)
	@for r in $$($(TF) state list | grep -E '^(kubernetes_|helm_release\.|null_resource\.flux_)'); do $(TF) state rm "$$r" >/dev/null; done
	@rc=0; $(TF) destroy $(if $(filter 1,$(AUTO_APPROVE)),-auto-approve,) || rc=$$?; \
	$(MAKE) --no-print-directory leftovers; check=$$?; \
	if [ $$rc -ne 0 ]; then exit $$rc; fi; exit $$check

# What can outlive a cluster and keep costing, in the region: the cluster itself, instances, EBS volumes
# and snapshots (a PersistentVolume's disk), load balancers and their target groups (the NLB of a
# LoadBalancer Service), NAT gateways and Elastic IPs, network interfaces left by a controller (they
# also block deleting the VPC), the VPC with its security groups, and log groups. The account holds
# nothing else, so whatever these list is a leftover. Exit 1 when anything is left, 2 when a query
# failed: an error never reads as "nothing left".
leftovers: ## List billable leftovers in the region (exit 1 when any, 2 when a query failed)
	@left=0; failed=0; \
	check() { \
	  local what="$$1" out; shift; \
	  if ! out="$$($(AWS) "$$@" --output text)"; then failed=1; echo "FAIL could not list $$what (aws error above)" >&2; return; fi; \
	  if [ -n "$$out" ]; then left=1; echo "LEFT $$what: $$(tr '\t\n' '  ' <<<"$$out")"; fi; \
	}; \
	check "EKS clusters"           eks list-clusters --query 'clusters[]'; \
	check "instances"              ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId'; \
	check "EBS volumes"            ec2 describe-volumes --query 'Volumes[].VolumeId'; \
	check "EBS snapshots"          ec2 describe-snapshots --owner-ids self --query 'Snapshots[].SnapshotId'; \
	check "load balancers"         elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'; \
	check "target groups"          elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName'; \
	check "classic load balancers" elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName'; \
	check "NAT gateways"           ec2 describe-nat-gateways --filter Name=state,Values=pending,available,deleting --query 'NatGateways[].NatGatewayId'; \
	check "Elastic IPs"            ec2 describe-addresses --query 'Addresses[].PublicIp'; \
	check "network interfaces"     ec2 describe-network-interfaces --query 'NetworkInterfaces[].NetworkInterfaceId'; \
	check "VPCs"                   ec2 describe-vpcs --query 'Vpcs[].VpcId'; \
	check "log groups"             logs describe-log-groups --query 'logGroups[].logGroupName'; \
	if [ $$failed = 1 ]; then exit 2; fi; \
	if [ $$left = 0 ]; then echo "OK   nothing left in $(AWS_REGION)"; else exit 1; fi
