# AWS (EKS) - runbook

The AWS side of the platform comes in two Terraform modules:

| Module | Lifetime | Who applies it | Costs |
|---|---|---|---|
| `infra/terraform/aws_foundation` | once per account, stays | a person, from a workstation | nothing |
| `infra/terraform/eks_cluster` | per cycle: created, tested, destroyed | a person today; later GitHub Actions, with approval | while it exists (not built yet) |

This page covers the foundation: what it creates, why, and the one-command setup.

## What the foundation creates, and why

| Piece | What | Why |
|---|---|---|
| Account and identity check | The provider refuses every account but `TF_VAR_account_id`. The plan fails unless Terraform runs as `TF_VAR_expected_principal_arn`. | A workstation often holds other AWS accounts and profiles. Applying as the wrong one would build in the wrong place. |
| Cluster IAM roles | `<cluster>-eks-cluster` (AmazonEKSClusterPolicy), `<cluster>-eks-nodes` (worker node, ECR pull-only, VPC CNI), `<cluster>-ebs-csi` and `<cluster>-aws-lbc` (EKS Pod Identity) | Made once, like `gke-nodes` on Google Cloud. AWS-managed policies where AWS has one. The cluster module uses them and never creates an IAM role. |
| GitHub OIDC provider + `terraform-eks` deployer | GitHub Actions of one repository and its owner (numeric ids), on `refs/heads/main` only, with or without an approval environment | GitHub signs a short-lived token per run, and STS exchanges it for the deployer's credentials. No access key is stored anywhere. A repository name can be registered again by anyone, its id cannot. Pull request code never gets in. |
| Deployer rights | EKS on this cluster only; EC2 (network, nodes) and read-only load balancer, autoscaling, logs and tags, all in one region; the EKS AMI parameters; `iam:PassRole` on the four roles above, to EKS, EC2 and Pod Identity only. An explicit Deny keeps it from undoing the account defaults below or making a snapshot or image public. | Enough for a cluster, nothing more. It cannot create a role or attach a policy, so a workflow run cannot give itself more rights than this module does. No CloudWatch Logs writes, KMS keys or IRSA: the cluster module turns them off, and turning one on means adding its rights here first. |
| Monthly budget | 10 USD; e-mail at 50, 90 and 100 % of spend and at 100 % of the forecast | A budget only warns, it never stops spending. The alert is the signal to destroy what was forgotten. A test cycle costs a few dollars; a cluster left running costs about 9 a day. |
| S3 public access block | Account-wide | No bucket or object can be made public, by any tool. |
| EBS encryption by default | In the region, with the AWS-managed key | Every new disk is encrypted. A key of your own is billed and buys nothing here. |
| IMDS defaults | In the region: IMDSv2 required, hop limit 1 | A pod cannot read its node's credentials from the metadata service. |

These are free. Cost starts with the cluster: control plane, nodes, NAT gateway, load balancer.

### What AWS creates on its own, and what we remove

Every region of a new account has a **default VPC with public subnets**. An instance launched without a subnet lands there with a public address. Nothing of the platform uses it, because the cluster builds its own VPC. Terraform cannot delete what it did not create, so `make delete-default-vpc CONFIRM=yes` deletes the one in the platform's region once. A `check` in the module warns on every plan if it comes back. The other regions' default VPCs stay, because nothing runs there.

## Setup

### 1. Prerequisites

- An AWS account, and `aws` (CLI 2.32 or newer, for `aws login`), `terraform`, `jq` and `make` on your machine.
- An IAM user with console sign-in, MFA (a passkey) and the managed policies `AdministratorAccess` and
  `SignInLocalDevelopmentAccess`. Not the root user: root keeps only its own passkey and stays unused.
- The Cloudflare R2 key for the Terraform state, the same one as for the other modules.

### 2. Sign in - short-lived credentials, no access key

```bash
aws login --profile platform        # browser: password + passkey
aws sts get-caller-identity --profile platform
```

`aws login` gives temporary credentials that refresh every 15 minutes and end after at most 12 hours. Run it again when they end. No long-lived IAM access key exists. The temporary credentials and the refresh token are cached on your machine (`~/.aws/login/cache`), and until they end they work for anyone who copies them: protect that directory like a key, and never copy it into a repository, a backup or a chat.

If this machine also holds other AWS accounts, keep this account's profile in a config file of its own (`export AWS_CONFIG_FILE=...` before `aws login`, in every terminal you use for it).

### 3. Settings

```bash
cp .env.aws.example .env.aws        # git-ignored
```

Fill in the account id, the profile, the expected identity (`aws sts get-caller-identity --profile platform --query Arn --output text`), the alert e-mail and the R2 key. The non-personal settings (region, budget, cluster name, GitHub repository ids) are in `infra/terraform/aws_foundation/terraform.tfvars`, so change them there for your own account.

The Makefile exports the R2 key as `AWS_ACCESS_KEY_ID`, because the S3 state backend reads that name. The aws provider never signs with it: a profile set in the provider block beats those variables. Every AWS CLI call in the Makefile runs with `--profile` and without the R2 key in its environment.

### 4. One command

```bash
make -C infra/terraform/aws_foundation bootstrap
```

It runs, in order:
1. **preflight**: names any missing setting or unknown profile before anything runs;
2. **first question**: delete the default VPC of the region?
3. **delete-default-vpc**: first, so the plan below carries no warning about it;
4. **plan**: saved, with the account and identity checks;
5. **second question**: apply this plan?
6. **apply**: exactly that plan;
7. **verify**: no drift and no default VPC.

Run `make ... plan` before `delete-default-vpc` and the plan warns `Check block assertion failed` for `no_default_vpc`: that is the check doing its job, and the warning goes away once the VPC is deleted.

AWS does not ask to confirm the budget e-mail address. The first e-mail arrives when spending crosses 50 %.

### 5. Later

```bash
make -C infra/terraform/aws_foundation verify      # still as the code says?
make -C infra/terraform/aws_foundation plan        # after a change: read it ...
make -C infra/terraform/aws_foundation apply       # ... then apply exactly that plan
```

## Check it by hand

```bash
P="--profile platform --region eu-central-1"
aws iam list-roles $P --query 'Roles[?starts_with(RoleName, `sre-`) || RoleName == `terraform-eks`].RoleName'
aws iam list-access-keys $P --query 'AccessKeyMetadata'                   # expect: []
aws s3control get-public-access-block $P --account-id ACCOUNT_ID
aws ec2 get-ebs-encryption-by-default $P                                  # expect: true
aws ec2 get-instance-metadata-defaults $P
aws ec2 describe-vpcs $P --filters Name=is-default,Values=true            # expect: no VPCs
aws budgets describe-budgets $P --account-id ACCOUNT_ID --query 'Budgets[].[BudgetName,BudgetLimit]'
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Resource postcondition failed ... Terraform authenticates as X, expected Y` | The profile signs in as someone else | `aws login --profile ...` as the right user, or fix `TF_VAR_expected_principal_arn`. |
| `AWS account ID not allowed` | The profile points at another account | Use this account's profile (`TF_VAR_aws_profile`). |
| `Your session has expired. Please reauthenticate using 'aws login'` | The `aws login` session ended (at most 12 hours) | `aws login --profile ...` again. |
| `missing: ...` or `no AWS CLI profile` from preflight | A setting is not in `.env.aws` or your shell, or the profile is not in the AWS config file | Add it (template: `.env.aws.example`, step 2). |
| `profile ... is X, expected Y - nothing deleted` from `delete-default-vpc` | The profile signs in as another user or account | As the first row. |
| `network interface(s) - ... nothing deleted` or `DependencyViolation` from `delete-default-vpc` | Something runs in the default VPC (an instance, an ENI) | Find it (`aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=VPC_ID`), move or delete it, run again. |
