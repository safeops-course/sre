# AWS (EKS) - runbook

The AWS side of the platform comes in two Terraform modules:

| Module | Lifetime | Who applies it | Costs |
|---|---|---|---|
| `infra/terraform/aws_foundation` | once per account, stays | a person, from a workstation | nothing |
| `infra/terraform/eks_cluster` | per cycle: created, tested, destroyed | a person today; later GitHub Actions, with approval | while it exists |

This page covers the foundation (what it creates, why, and the one-command setup), then a cluster cycle.

## What the foundation creates, and why

| Piece | What | Why |
|---|---|---|
| Account and identity check | The provider refuses every account but `TF_VAR_account_id`. The plan fails unless Terraform runs as `TF_VAR_expected_principal_arn`. | A workstation often holds other AWS accounts and profiles. Applying as the wrong one would build in the wrong place. |
| Cluster IAM roles | `<cluster>-eks-cluster` (AmazonEKSClusterPolicy), `<cluster>-eks-nodes` (worker node, ECR pull-only, VPC CNI), `<cluster>-ebs-csi` and `<cluster>-aws-lbc` (EKS Pod Identity), `<cluster>-vpc-flow-logs` (writes only into the flow-log groups) | Made once, like `gke-nodes` on Google Cloud. AWS-managed policies where AWS has one. The cluster module uses them and never creates an IAM role. |
| GitHub OIDC provider + `terraform-eks` deployer | GitHub Actions of one repository and its owner (numeric ids), on `refs/heads/main` only, with or without an approval environment | GitHub signs a short-lived token per run, and STS exchanges it for the deployer's credentials. No access key is stored anywhere. A repository name can be registered again by anyone, its id cannot. Pull request code never gets in. |
| Deployer rights | EKS on this cluster only; EC2 (network, nodes) and read-only load balancer, autoscaling and logs, all in one region; the EKS AMI parameters; CloudWatch Logs only for the cluster's own log groups (control-plane logs, VPC Flow Logs); `iam:PassRole` on the five roles above, to EKS, EC2, Pod Identity and VPC Flow Logs only. An explicit Deny keeps it from undoing the account defaults below or making a snapshot or image public. | Enough for a cluster, nothing more. It cannot create a role or attach a policy, so a workflow run cannot give itself more rights than this module does. No KMS keys or IRSA: the cluster module uses neither, and turning one on means adding its rights here first. |
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

## A cluster cycle

`infra/terraform/eks_cluster` builds an EKS Standard cluster for a test cycle, and the cluster is destroyed after it. It needs the foundation (the IAM roles - the module creates none) and reads the same `.env.aws`.

### What it builds, and why

| Piece | What | Why |
|---|---|---|
| Network | Its own VPC `sre` in two zones: a private `/19` per zone for nodes and pods, a public `/24` per zone for the load balancer and the NAT gateway; an S3 gateway endpoint | Never the default VPC. The subnet tags tell the Load Balancer Controller where an internet-facing load balancer goes. ECR image layers come from S3, through the free endpoint instead of the NAT gateway. |
| Egress | Private nodes (no public IP); a NAT gateway per zone by default, one in the course's tfvars | No node can be reached from the internet. One gateway is a single point of failure: when its zone goes down, the other zone loses the internet too. |
| Control plane | Public endpoint (IAM decides) plus a private one for the nodes; access entries only, no `aws-auth` ConfigMap; standard support only | The way in for a laptop and a GitHub runner alike, as on GKE. The identity that creates the cluster - the plan checks it is `TF_VAR_expected_principal_arn` - gets cluster admin, nobody else. Extended support would start by itself when a version's standard support ends, at six times the price. |
| Cluster | VPC CNI with NetworkPolicy (egress too) and prefix delegation, EKS Pod Identity (no IRSA), Kubernetes API data encrypted with an AWS-owned key | NetworkPolicy enforces the platform's default-deny. Prefix delegation gives a node a `/28` per network interface slot instead of one address, so the interfaces do not cap its pods. A key of our own would be billed and left pending deletion by every cycle. |
| Node groups | `platform` and `apps`, managed, AL2023, IMDSv2 with hop limit 1, gp3 root disks; a fixed size each | Split by role. A pod cannot read the node role's credentials; the add-ons that need AWS get them through Pod Identity. EKS adds no nodes by itself (that takes a cluster autoscaler or Karpenter, neither runs here): a group grows by its `node_count`. `spot` is a setting per group, `true` in the course's tfvars only because the cluster lives for one cycle. |
| Add-ons | VPC CNI, CoreDNS, kube-proxy, Pod Identity agent, EBS CSI driver, metrics-server; StorageClass `gp3` (default, encrypted, `WaitForFirstConsumer`) | What GKE and k3s have built in. EKS creates no default StorageClass. |
| Load balancer | The AWS Load Balancer Controller (Helm, by Terraform) gives Traefik's Service a Network Load Balancer with IP targets that keep the source address | Installed before Flux, so Traefik's Service finds it, and removed after the pre-destroy hook, so it can still delete the NLB. The legacy in-tree controller would make a Classic Load Balancer. Traefik sees the address that connected, without the PROXY protocol: behind the Cloudflare proxy that is a Cloudflare edge, and the visitor's address is in its CF-Connecting-IP header. |
| Logs | Control-plane logs (api, audit, authenticator) and VPC Flow Logs to CloudWatch Logs, 90 days, by default | The audit log is the only record of who did what on EKS. Both are billed per GiB; the course's test cycles turn them off in `terraform.tfvars`. A cluster that matters keeps them. |
| kubeconfig | `kubeconfig.yaml`, context `eks-sre-control-plane` | The endpoint and `aws eks get-token` with the profile: a short-lived token of whoever is signed in. No credentials in the file. |

**IPv4 only - the written exception.** An EKS cluster gives pods and Services IPv4 or IPv6, not both (`docs/providers.md`). The module writes `ip_stack = "ipv4"` and `service_ip_family_policy = "PreferDualStack"` to `cluster-config`; the apps' and Traefik's Services read the policy (derived from `ip_stack`), and conformance C13 checks the promise.

### Run a cycle

The cluster costs money from the first minute: the control plane, the nodes, their disks, the NAT gateway and the load balancer - roughly $0.40 an hour with Spot nodes in Frankfurt (list prices, 2026-10). Check the account's vCPU quota for Spot instances first (Service Quotas, `L-34B43A08`): a new account gets 5, and a node group that needs more fails to create. The course's `terraform.tfvars` stays at 4 vCPU (two 2 vCPU nodes) for that reason.

```bash
aws login --profile platform                        # browser: password + passkey
make -C infra/terraform/eks_cluster plan            # read it
make -C infra/terraform/eks_cluster apply           # the cluster, the controller, then Flux
kubectl --kubeconfig infra/terraform/eks_cluster/kubeconfig.yaml get nodes
make -C infra/terraform/eks_cluster destroy         # asks first, then runs make leftovers
```

A cycle that tests a branch (pushed first) plans with `TF_VAR_flux_git_repository_branch=<branch>`: Flux then follows that branch from the first reconcile. Without it Flux follows `main`, where a new profile does not exist yet.

**Flux.** As on GKE (`docs/gcp.md`, "Run a cycle"): Terraform writes the namespaces, `cluster-config`, `cluster-secrets`, `backup-s3`, the age key `sops-age` and the production database password (`flux.tf`), then Flux follows the platform repository and reconciles `flux/bootstrap/profiles/eks`. The same settings, in `.env.aws`: `SOPS_AGE_KEY_FILE`, `TF_VAR_uptrace_dsn` and the backup bucket's `TF_VAR_backup_s3_*`.

- **kubectl, Terraform's kubernetes and helm providers and the AWS provider** all sign in with `TF_VAR_aws_profile`, so the plan's identity check covers them all. Each names the profile itself: the R2 key the Makefile exports as `AWS_ACCESS_KEY_ID` never signs an AWS call.
- **Destroy:** before the node groups go, `flux-pre-destroy.sh` suspends Flux and deletes the workload namespaces with their volumes, and the `traefik` namespace with its LoadBalancer Service, while the EBS CSI driver and the Load Balancer Controller still run - the controller deletes the NLB, its target groups and security groups only with the Service. An EBS volume or a load balancer left behind keeps costing; `make leftovers` names it.

`make leftovers` lists what can outlive a cluster in the region: EKS clusters, instances, EBS volumes and snapshots, load balancers and target groups, NAT gateways, Elastic IPs, network interfaces, VPCs and log groups. The account holds nothing else, so anything listed is a leftover. It fails when anything is left, or when a query fails - never "nothing left" on an error. Delete what it names, then run it again.
