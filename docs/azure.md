# Azure (AKS) - runbook

The Azure side of the platform comes in two Terraform modules:

| Module | Lifetime | Who applies it | Costs |
|---|---|---|---|
| `infra/terraform/azure_foundation` | once per subscription, stays | a person, from a workstation | nothing |
| `infra/terraform/aks_cluster` | per cycle: created, tested, destroyed | a person today; later GitHub Actions, with approval | while it exists |

This page covers the foundation (what it creates, why, and the one-command setup), then a cluster cycle.

## What the foundation creates, and why

| Piece | What | Why |
|---|---|---|
| Subscription and identity check | The provider sends every call to `TF_VAR_subscription_id` in `TF_VAR_tenant_id`. The plan fails unless Terraform runs as `TF_VAR_expected_principal_object_id`. | `az login` can hold several tenants and accounts. Applying as the wrong one would build in the wrong place. |
| Resource providers | Only what the clusters use: ContainerService, Compute, Network, Storage, ManagedIdentity, OperationalInsights, Insights, Consumption | A subscription can create a resource type only after its provider is registered. azurerm 5 registers none by itself; registering is free. |
| Resource group `sre-aks` | Empty between cycles; the cluster module builds in it | Every role below is scoped to this one group, so they reach nothing else in the subscription. |
| Kubernetes admin for the person | `Azure Kubernetes Service RBAC Cluster Admin` on the group | The cluster has no local accounts and uses Azure RBAC for Kubernetes: owning the subscription gives no access to the Kubernetes API. Assigned before any cluster exists, so the Flux bootstrap never waits for it to propagate. |
| GitHub deployer `terraform-aks` | A user-assigned managed identity in a group of its own, `sre-ci`, with a federated credential for `repo:safeops-course/sre:ref:refs/heads/main` | GitHub signs a short-lived token per run, and Microsoft Entra exchanges it for a token of the identity. No client secret is stored anywhere. Pull request code never matches. |
| Deployer rights | `Contributor` and `Azure Kubernetes Service RBAC Cluster Admin`, both on `sre-aks` only | Enough to build and delete a cluster in that group and bootstrap Flux. Contributor cannot assign roles, and the identity is in `sre-ci`, where it has no rights - in `sre-aks` its Contributor role could add a federated credential to itself. So a workflow run cannot give itself more rights than this module does. It can delete `sre-aks`; applying the module again puts it back. |
| Monthly budget | 10 USD; e-mail at 50, 90 and 100 % of spend and at 100 % of the forecast | A budget only warns, it never stops spending. A test cycle costs about a dollar; a cluster left running costs about 6 a day. |

These are free. Cost starts with the cluster: nodes, their disks, the load balancer and its addresses.

**The federated credential trusts a name, not an id.** Azure compares the token's whole subject - `repo:OWNER/REPO:ref:REF` - and checks no other claim, unlike the AWS and Google locks, which use the repository's numeric id. If the repository is deleted, someone else could register its name and match. Keep the repository, or delete the credential with it. A job with an approval `environment:` gets the subject `repo:OWNER/REPO:environment:NAME` and needs a credential of its own.

Azure creates no default network in a subscription, so - unlike AWS and Google Cloud - there is nothing to delete.

## Setup

### 1. Prerequisites

- An Azure **pay-as-you-go** subscription. A free trial cannot raise quotas.
- `az` (Azure CLI), `terraform`, `kubectl`, `jq`, `yq` (v4), `age-keygen` and `make` on your machine.
- **Azure kubelogin** - the tool kubectl gets the cluster's Entra token from. Homebrew's `kubelogin` is a different tool with the same name (int128's OIDC plugin, used for Dex), so install Azure's next to it and give its full path in `.env.azure` (`AZURE_KUBELOGIN`):
  ```bash
  az aks install-cli --install-location ~/bin/azure/kubectl --kubelogin-install-location ~/bin/azure/kubelogin
  ```
  `make preflight` refuses a `kubelogin` that is not Azure's.
- The Cloudflare R2 key for the Terraform state, the same one as for the other modules.

### 2. Sign in - in a directory of its own

```bash
export AZURE_CONFIG_DIR=~/.azure-platform      # never the default ~/.azure
az login --tenant TENANT_ID                    # browser: password + MFA
az account show --query '{subscription:id, tenant:tenantId, user:user.name}'
```

The Azure CLI keeps its sign-in and token cache in `AZURE_CONFIG_DIR`. A directory of its own keeps this subscription apart from any other tenant the machine is signed in to, and the Makefiles export the same directory to Terraform and kubelogin. The cache holds refresh tokens: protect it like a key and never copy it into a repository, a backup or a chat.

### 3. Settings

```bash
cp .env.azure.example .env.azure     # git-ignored
```

Fill in the CLI directory, the subscription and tenant ids, your object id (`az ad signed-in-user show --query id -o tsv`), the alert e-mail and the R2 key. The non-personal settings (location, budget, cluster name, GitHub repository) are in `infra/terraform/azure_foundation/terraform.tfvars`, so change them there for your own subscription.

The Makefile exports the R2 key as `AWS_ACCESS_KEY_ID`, because the S3 state backend reads that name; nothing on Azure reads it. It also removes any `ARM_*` credentials from Terraform's environment: they would win over the CLI sign-in.

### 4. One command

```bash
make -C infra/terraform/azure_foundation bootstrap
```

It runs, in order:
1. **preflight**: names any missing setting, and checks that the CLI is signed in to this subscription in this tenant;
2. **plan**: saved, with the identity check (the provider registers the resource providers here);
3. **question**: apply this plan?
4. **apply**: exactly that plan;
5. **verify**: no drift.

Azure does not ask to confirm the budget e-mail address.

### 5. Later

```bash
make -C infra/terraform/azure_foundation verify    # still as the code says?
make -C infra/terraform/azure_foundation plan      # after a change: read it ...
make -C infra/terraform/azure_foundation apply     # ... then apply exactly that plan
```

## Check it by hand

Every command names the subscription: the CLI's default one may be another, when `az login` holds several.
Only the two values come from `.env.azure` (the repository root), not its keys.

```bash
export AZURE_CONFIG_DIR="$(sed -n 's/^AZURE_CONFIG_DIR=//p' .env.azure)"
sub="$(sed -n 's/^TF_VAR_subscription_id=//p' .env.azure)"
az provider list --subscription "$sub" --query "[?registrationState=='Registered'].namespace" -o tsv
az group show --subscription "$sub" --name sre-aks --query '{name:name, location:location}'
az role assignment list --subscription "$sub" --resource-group sre-aks --query '[].{role:roleDefinitionName, who:principalName}' -o table
az identity federated-credential list --subscription "$sub" --identity-name terraform-aks --resource-group sre-ci --query '[].subject'
az consumption budget list --subscription "$sub" --query '[].{name:name, amount:amount}'
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Resource postcondition failed ... Terraform authenticates as object id X, expected Y` | The CLI is signed in as someone else | `az login` as the right user with `AZURE_CONFIG_DIR` set, or fix `TF_VAR_expected_principal_object_id`. |
| `not signed in to subscription ...` from preflight | `AZURE_CONFIG_DIR` points at a directory without this sign-in, or the session ended | `az login --tenant ...` with that directory exported (step 2). |
| `RequestDisallowedByAzure ... The selected region is currently not accepting new customers` | Azure turns new subscriptions away from regions short of capacity (West Europe, 2026-10) | Another region (`location` in `azure_foundation/terraform.tfvars` - the cluster is built in the foundation's group, so it follows); check the size and the quota there first (below). |
| A size is refused, or `az vm list-usage` shows 0 for its family | New subscriptions get quota for some families only (2026-10: none for the v5 sizes, 10 vCPU for v6/v7) | `az vm list-usage -l LOCATION -o table`, pick a family with quota, or request more (Quotas in the portal). |
| A resource type fails with `MissingSubscriptionRegistration` | Its resource provider is not registered | Add it to `resource_providers_to_register` (azure_foundation/versions.tf), spelled as `az provider list` shows it - azurerm matches the name exactly and skips a different spelling silently (`microsoft.insights`). |
| The budget fails on a new subscription | Budgets become available up to 48 hours after the subscription | Apply again later; the rest of the foundation is already there. |
| `... is not Azure kubelogin` from preflight | `AZURE_KUBELOGIN` (or PATH) finds Homebrew's int128 kubelogin | Install Azure's (prerequisites) and set its full path. |

## A cluster cycle

`infra/terraform/aks_cluster` builds an AKS cluster for a test cycle, and the cluster is destroyed after it. It needs the foundation (the resource group and your Kubernetes admin role) and reads the same `.env.azure`.

### What it builds, and why

| Piece | What | Why |
|---|---|---|
| Network | Azure CNI Overlay powered by Cilium, dual-stack: nodes, pods and Services get IPv4 and IPv6; the node network is the one AKS manages | Cilium enforces the platform's NetworkPolicies (egress too); it is the only policy engine AKS offers with dual-stack. Overlay: pods do not use addresses of the node network. Nothing else is connected to it, so AKS's own network is enough. |
| Egress | The Standard load balancer's outbound rules, one IPv4 and one IPv6 address | The documented way out for a dual-stack cluster; a managed NAT gateway is IPv4 only. Nodes have no public address. |
| Control plane | Public endpoint; Microsoft Entra ID tokens only, authorized by Azure RBAC; no local accounts | The way in for a laptop and a GitHub runner alike, as on GKE and EKS. Without local accounts no admin certificate exists that a leaked kubeconfig could carry, and `az aks get-credentials --admin` is refused. |
| Upgrades | By default: Kubernetes patches (`patch` channel - the minor stays `kubernetes_version`'s) and a new node image every week, inside a weekly window | Security fixes without a person. The course's tfvars turns both off: an upgrade must not start in the middle of a check. |
| Node pools | `platform` (the system pool: AKS's own pods and the platform's) and `apps` (a user pool), on-demand, fixed size, managed OS disk | Split by role. Spot is possible only for a user pool, and AKS taints Spot nodes, so every app pod would need a toleration. AKS adds no nodes unless the cluster autoscaler is on: a pool grows by its `node_count`. |
| Storage | AKS's own StorageClass `default` (Azure Disk CSI, Standard SSD, `WaitForFirstConsumer`, expandable - the same as `managed-csi`) is the default | Nothing to add. An online expansion took about 2.5 minutes (2026-10-21). |
| Load balancer | AKS's cloud controller gives Traefik's Service frontends on the cluster's Standard load balancer, IPv4 and IPv6 | The base Service requires both families. Deleted with the Service. |
| Logs | Control-plane logs (kube-apiserver, kube-audit-admin, guard) to a Log Analytics workspace, 90 days, by default | kube-audit-admin is the record of who changed what on AKS. Billed per GiB; the course's test cycles turn them off in `terraform.tfvars`. A cluster that matters keeps them. |
| kubeconfig | `kubeconfig.yaml`, context `aks-sre-control-plane` | The endpoint and Azure kubelogin (`get-token --login azurecli`): a short-lived Entra token of whoever is signed in to the CLI. No credentials in the file. |

AKS keeps the nodes, their disks, the load balancer and its addresses in a resource group of its own, `sre-aks-nodes`, and deletes it with the cluster.

### Run a cycle

The cluster costs money from the first minute: two D2as_v7 nodes, their disks, the load balancer and its addresses - roughly $0.25 an hour in Sweden Central (list prices, 2026-10), with the control plane on the Free tier. Check the region's quota for the node size's family first: `az vm list-usage -l swedencentral -o table`.

```bash
make -C infra/terraform/aks_cluster plan            # read it
make -C infra/terraform/aks_cluster apply           # the cluster, the pools, then Flux
kubectl --kubeconfig infra/terraform/aks_cluster/kubeconfig.yaml get nodes
make -C infra/terraform/aks_cluster destroy         # asks first, then runs make leftovers
```

The first cycle (2026-10-21) took about 8 minutes to apply (cluster 5.5, apps pool 1.5) and 7 more until every Flux Kustomization was Ready; the destroy took about 10 minutes, and `make leftovers` found nothing. Conformance: 12 PASS, C8, C10 and C12 SKIP. Measured then: the nodes' requests 1.5 and 1.1 of 1.9 allocatable cores (AKS's own pods ask for a lot; about 0.15 cores used per node), memory used 75 and 84 % of 5.7 GiB - memory, not CPU, is what a bigger cluster would need first. The Free tier's API server dropped a few connections under load: a retry worked.

A cycle that tests a branch (pushed first) plans with `TF_VAR_flux_git_repository_branch=<branch>`: Flux then follows that branch from the first reconcile. Without it Flux follows `main`, where a new profile does not exist yet.

**Flux.** As on GKE and EKS: Terraform writes the namespaces, `cluster-config`, `cluster-secrets`, `backup-s3`, the age key `sops-age` and the production database password (`flux.tf`), then Flux follows the platform repository and reconciles `flux/bootstrap/profiles/aks`. The same settings, in `.env.azure`: `SOPS_AGE_KEY_FILE`, `TF_VAR_uptrace_dsn` and the backup bucket's `TF_VAR_backup_s3_*`.

- **kubectl, Terraform's kubernetes provider and the azurerm provider** all sign in through the Azure CLI in `AZURE_CONFIG_DIR`, so the plan's identity check covers them all.
- **Destroy:** the Makefile first writes `kubeconfig.yaml` again from the live cluster (with Azure kubelogin by its full path). Before the pools go, `flux-pre-destroy.sh` suspends Flux and deletes the workload namespaces with their volumes, and the `traefik` namespace with its LoadBalancer Service, while the CSI driver and the cloud controller still run, and external-dns deletes the DNS records. A disk or an address left behind keeps costing; `make leftovers` names it.

`make leftovers` lists what can outlive a cluster in the subscription: AKS clusters, anything in `sre-aks` (empty between cycles), the node resource group, disks and snapshots, public IPs, load balancers, virtual networks and Log Analytics workspaces. It exits 1 when anything is left. Delete what it names, then run it again.
