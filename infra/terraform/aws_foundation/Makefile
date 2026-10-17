# The AWS foundation - applied once, by a person, from a workstation (it creates the identity CI deploys
# with). docs/aws.md walks through it; `make bootstrap` does the whole first setup.
#
# Settings come from ENV_FILE (default: .env.aws in the repository root, git-ignored; template
# .env.aws.example) or, without that file, from your shell: TF_VAR_account_id, TF_VAR_aws_profile,
# TF_VAR_expected_principal_arn, TF_VAR_alert_email, and the R2 state key (R2_ACCESS_KEY_ID /
# R2_SECRET_ACCESS_KEY, or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
SHELL := /bin/bash
TF    := terraform

GUARD_TF   := ../../../scripts/guard-terraform-plan.sh
TF_MAX_AGE ?= 60

ENV_FILE ?= ../../../.env.aws
-include $(ENV_FILE)
export TF_VAR_account_id TF_VAR_aws_profile TF_VAR_expected_principal_arn TF_VAR_alert_email
# The S3 backend reads AWS_*; the R2 key is named R2_* in the env files. The aws provider does not take
# it: its profile wins over these variables (versions.tf).
ifneq ($(R2_ACCESS_KEY_ID),)
export AWS_ACCESS_KEY_ID     := $(R2_ACCESS_KEY_ID)
export AWS_SECRET_ACCESS_KEY := $(R2_SECRET_ACCESS_KEY)
endif
# Leftovers of another AWS session in the shell never reach Terraform or the CLI: a session token would be
# paired with the R2 key by the backend; the provider and the CLI name their profile themselves.
unexport AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE

AWS_REGION := $(shell sed -n 's/^region *= *"\(.*\)".*/\1/p' terraform.tfvars)
# The AWS CLI as the foundation's profile, never with the R2 key: an explicit --profile already beats
# AWS_ACCESS_KEY_ID, and the key is taken out of its environment as well, so no command can sign with it.
AWS := env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY aws --profile "$(TF_VAR_aws_profile)" --region "$(AWS_REGION)"

.PHONY: help init preflight plan apply verify delete-default-vpc bootstrap

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

# Every setting present before Terraform runs - a missing one is named, not discovered half-way.
# The identity itself is checked by the plan (main.tf): only AWS can say who the credentials are.
preflight: ## Check that every setting is there (no cloud calls)
	@missing=""; \
	for v in TF_VAR_account_id TF_VAR_aws_profile TF_VAR_expected_principal_arn TF_VAR_alert_email AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do \
	  [ -n "$${!v:-}" ] || missing="$$missing $$v"; \
	done; \
	[ -z "$$missing" ] || { echo "missing:$$missing - set them in $(ENV_FILE) (template: .env.aws.example)" >&2; exit 2; }
	@test -n "$(AWS_REGION)" || { echo "no region in terraform.tfvars" >&2; exit 2; }
	@for t in aws jq; do command -v $$t >/dev/null || { echo "$$t is not installed (docs/aws.md, prerequisites)" >&2; exit 2; }; done
	@profiles="$$(aws configure list-profiles)" || { echo "could not list the AWS CLI profiles (aws error above)" >&2; exit 2; }; \
	grep -qxF -- "$$TF_VAR_aws_profile" <<<"$$profiles" || { echo "no AWS CLI profile '$$TF_VAR_aws_profile' in $${AWS_CONFIG_FILE:-~/.aws/config} (docs/aws.md, step 2)" >&2; exit 2; }
	@echo "account $$TF_VAR_account_id, region $(AWS_REGION), profile $$TF_VAR_aws_profile, expected identity $$TF_VAR_expected_principal_arn"

init: ## Terraform init (state in R2)
	@$(TF) init -input=false >/dev/null

plan: preflight init ## Terraform plan, saved to tfplan (read it before apply)
	@$(GUARD_TF) plan --dir . --out tfplan
	@$(TF) show -no-color tfplan | grep -E '^Plan:|^No changes' || true

apply: preflight ## Apply exactly the saved tfplan (refused when older than TF_MAX_AGE minutes)
	@$(GUARD_TF) apply --dir . --out tfplan --max-age-minutes $(TF_MAX_AGE)

# The account matches the code (no drift) and holds no default VPC in the region. 0 = yes, 1 = not.
# `describe-vpcs` prints nothing when there is no such VPC and exits non-zero on any error (expired
# login) - an error never reads as "no default VPC".
# Drift = a resource the plan would create, change or delete (see gcp_foundation/Makefile for why not
# -detailed-exitcode: the data source in the check block is re-read on every plan).
verify: preflight init ## The foundation matches the code and the region has no default VPC
	@$(TF) plan -input=false -lock=false -out=verify.tfplan >/dev/null || { echo "FAIL the plan did not run" >&2; rm -f verify.tfplan; exit 1; }
	@set -o pipefail; \
	changes="$$($(TF) show -json verify.tfplan | jq -er '[.resource_changes[]? | select(.mode == "managed" and .change.actions != ["no-op"]) | .address] | join(" ")')" \
	  || { echo "FAIL could not read the plan (terraform show / jq error above)" >&2; rm -f verify.tfplan; exit 1; }; \
	rm -f verify.tfplan; \
	if [ -n "$$changes" ]; then echo "FAIL drift: $$changes - run make plan and read it" >&2; exit 1; fi; \
	echo "OK   no drift: the account matches the code"
	@vpc="$$($(AWS) ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[].VpcId' --output text)" || { echo "FAIL could not list the VPCs of $(AWS_REGION) (aws error above)" >&2; exit 1; }; \
	if [ -n "$$vpc" ]; then echo "FAIL $(AWS_REGION) has a default VPC ($$vpc): make delete-default-vpc CONFIRM=yes" >&2; exit 1; fi; \
	echo "OK   no default VPC in $(AWS_REGION)"

# The default VPC AWS creates in every region has public subnets; nothing here uses it (main.tf, check
# "no_default_vpc"). A VPC is deleted only without its internet gateway and subnets, so they go first; its
# route table, network ACL and security group go with it. Not undone by Terraform, so it asks for CONFIRM=yes.
# Every lookup is read into a variable first (set -e stops on a failed one): a failed lookup (an expired
# login) must stop the target, not run an empty loop and blame the VPC's contents.
# Only var.region: the other regions' default VPCs stay - nothing of the platform runs there.
delete-default-vpc: preflight ## One-time: delete the default VPC of the region (CONFIRM=yes)
	@test "$(CONFIRM)" = yes || { echo "deletes the default VPC of $(AWS_REGION) - run again with CONFIRM=yes" >&2; exit 2; }
	@set -e; \
	vpc="$$($(AWS) ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[].VpcId' --output text)"; \
	if [ -z "$$vpc" ]; then echo "no default VPC in $(AWS_REGION)"; exit 0; fi; \
	igws="$$($(AWS) ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$$vpc --query 'InternetGateways[].InternetGatewayId' --output text)"; \
	subnets="$$($(AWS) ec2 describe-subnets --filters Name=vpc-id,Values=$$vpc --query 'Subnets[].SubnetId' --output text)"; \
	for igw in $$igws; do \
	  $(AWS) ec2 detach-internet-gateway --internet-gateway-id $$igw --vpc-id $$vpc; \
	  $(AWS) ec2 delete-internet-gateway --internet-gateway-id $$igw; \
	done; \
	for subnet in $$subnets; do \
	  $(AWS) ec2 delete-subnet --subnet-id $$subnet; \
	done; \
	$(AWS) ec2 delete-vpc --vpc-id $$vpc; \
	echo "deleted the default VPC $$vpc of $(AWS_REGION)"

# The whole first setup, in order. One question - the plan is shown and must be confirmed.
bootstrap: plan ## First setup: plan, confirm, apply, delete the default VPC, verify
	@read -r -p "Apply this plan to AWS account $$TF_VAR_account_id? [y/N] " answer; [ "$$answer" = y ] || { echo "not applied"; exit 1; }
	@$(MAKE) --no-print-directory apply
	@$(MAKE) --no-print-directory delete-default-vpc CONFIRM=yes
	@$(MAKE) --no-print-directory verify
