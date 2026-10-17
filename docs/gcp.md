# Google Cloud (GKE) - runbook

The Google Cloud side of the platform comes in two Terraform modules:

| Module | Lifetime | Who applies it | Costs |
|---|---|---|---|
| `infra/terraform/gcp_foundation` | once per project, stays | a person, from a workstation | nothing |
| `infra/terraform/gke_cluster` | per cycle: created, tested, destroyed | a person today; later GitHub Actions, with approval | while it exists |

This page covers the foundation (what it creates, why, one-command setup) and then [a cluster cycle](#a-cluster-cycle).

## What the foundation creates, and why

| Piece | What | Why |
|---|---|---|
| Identity check | The plan fails unless Terraform runs as `TF_VAR_expected_principal` | A workstation often holds other Google identities (client work, an impersonated service account). Applying as the wrong one would build in the wrong place. |
| APIs | Only what the clusters need (GKE, Compute, IAM, STS, logging, monitoring, budgets) | Enabling an API is free, using it costs. They are never turned off on destroy, because that can delete what other tools created. |
| `gke-nodes` service account | `roles/container.defaultNodeServiceAccount` only | Google's documented minimum for nodes: write logs and metrics. Nodes never run as the Compute default account. |
| `terraform-gke` deployer | `container.admin`, `compute.networkAdmin`, `compute.securityAdmin`, alert policies; `serviceAccountUser` on `gke-nodes` only | What CI runs as: enough for a cluster and its network. No owner or editor, no IAM admin, no keys. |
| Workload Identity Federation | GitHub Actions of one repository (numeric id), its owner, on `refs/heads/main` only | GitHub signs a short-lived token per run, and Google exchanges it for the deployer's credentials. No key is stored anywhere. A repository name can be registered again by anyone, its id cannot. Pull request code never gets in. |
| Alert e-mail channel | One Cloud Monitoring channel | Budget and Cloud NAT alerts go here. |
| Monthly budget | Alerts at 50, 90 and 100 % of spend and at 100 % of the forecast | A budget only warns, it never stops spending. The alert is the signal to destroy what was forgotten. |

### What Google creates on its own, and what we remove

Turning the Compute API on creates two things in a project that has no organization policy against them:

1. **The Compute Engine default service account, with `roles/editor`** on the whole project. The foundation takes Editor away (`google_project_iam_member_remove`), and every plan checks that it stays away.
2. **A `default` VPC whose firewall opens SSH (22), RDP (3389) and ICMP to `0.0.0.0/0`.** Terraform cannot delete what it did not create, so `make delete-default-network CONFIRM=yes` deletes it once. A `check` in the module warns on every plan if it comes back.

Both are on the CIS Google Cloud Benchmark's list. In a Google Cloud organization, the policies `iam.automaticIamGrantsForDefaultServiceAccounts` and `compute.skipDefaultNetworkCreation` stop them from being created at all. A project without an organization has to clean up after the fact.

## Setup

### 1. Prerequisites

- A Google Cloud project with billing enabled, and `gcloud`, `terraform`, `jq` and `make` on your machine.
- The Cloudflare R2 key for the Terraform state, the same one as for the Hetzner cluster.

### 2. Sign in - as the right identity

```bash
gcloud auth login
gcloud auth application-default login     # the credentials Terraform uses
```

If this machine also holds other Google identities, for example client work, keep this project's gcloud in its own directory. Do it before signing in, in every terminal you use for it:

```bash
export CLOUDSDK_CONFIG="$HOME/.config/gcloud-platform"      # any directory of your own
gcloud auth login --no-launch-browser                        # open the link in a private window
gcloud auth application-default login --no-launch-browser
gcloud config set project YOUR_PROJECT_ID
```

The google Terraform provider **ignores `CLOUDSDK_CONFIG`**: it reads `GOOGLE_APPLICATION_CREDENTIALS` or gcloud's default directory. Point `GOOGLE_APPLICATION_CREDENTIALS` at `$CLOUDSDK_CONFIG/application_default_credentials.json` (step 3). Otherwise Terraform silently runs as whatever the default directory holds. The identity check catches that, but it is better not to get there.

### 3. Settings

```bash
cp .env.gcp.example .env.gcp        # git-ignored
```

Fill in the expected identity, its ADC file, the billing account, the alert e-mail and the R2 key. The non-personal settings (project, region, budget, GitHub repository ids) are in `infra/terraform/gcp_foundation/terraform.tfvars`, so change them there for your own project.

### 4. One command

```bash
make -C infra/terraform/gcp_foundation bootstrap
```

It runs, in order:
1. **preflight**: names any missing setting before anything runs;
2. **plan**: saved, with the identity check;
3. **one question**: apply this plan?
4. **apply**: exactly that plan;
5. **delete-default-network**: only now does the default VPC exist, because the apply turned the Compute API on;
6. **verify**: no drift and no default VPC.

Expected on a fresh project: `Plan: 24 to add`, then `OK no drift` and `OK no default VPC`.

Google confirms nothing by e-mail for an e-mail notification channel. The first budget e-mail arrives when spending crosses 50 %.

### 5. Later

```bash
make -C infra/terraform/gcp_foundation verify      # still as the code says?
make -C infra/terraform/gcp_foundation plan        # after a change: read it ...
make -C infra/terraform/gcp_foundation apply       # ... then apply exactly that plan
```

## Check it by hand

```bash
gcloud iam service-accounts list --format='value(email)'
gcloud iam workload-identity-pools providers describe github-actions \
  --workload-identity-pool=github --location=global --format='value(state,attributeCondition)'
gcloud projects get-iam-policy YOUR_PROJECT_ID --flatten='bindings[].members' \
  --filter='bindings.members:compute@developer' --format='value(bindings.role)'   # expect: nothing
gcloud compute networks list                                                      # expect: nothing
gcloud billing budgets list --billing-account=YOUR_BILLING_ACCOUNT
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Resource postcondition failed ... Terraform authenticates as X, expected Y` | The credentials are someone else's | Set `GOOGLE_APPLICATION_CREDENTIALS` to the right ADC file (step 2). |
| `SERVICE_DISABLED` right after the first apply | Enabling an API takes a minute to reach every Google system | Run `make plan` again after a minute. |
| `missing: ...` from preflight | A setting is not in `.env.gcp` or your shell | Add it (template: `.env.gcp.example`). |
| A deleted Workload Identity pool or provider "already exists" | Google keeps a deleted pool or provider for 30 days | Restore it (`gcloud iam workload-identity-pools undelete`) or wait. The foundation is applied once, not per cycle. |

## A cluster cycle

`infra/terraform/gke_cluster` builds a GKE Standard cluster for a test cycle, and the cluster is destroyed after it. It needs the foundation (the APIs, the `gke-nodes` account, the alert e-mail channel) and reads the same `.env.gcp`.

### What it builds, and why

| Piece | What | Why |
|---|---|---|
| Network | Its own VPC `sre`, one subnet with named Pod and Service ranges, Private Google Access | Never the `default` VPC. VPC-native: firewall rules and NetworkPolicies see real Pod IPs. Nodes reach Google APIs without NAT. |
| Egress | Private nodes (no public IP); Cloud NAT with dynamic ports, error logs only, two alerts | No node can be reached from the internet. The alerts mean that connections out are failing right now. |
| Control plane | DNS endpoint only, no IP endpoint | IAM decides who gets in, from a laptop or a GitHub runner alike. No IP allow-list to keep up to date. |
| Cluster | Dataplane V2, Workload Identity, shielded nodes with secure boot, no kubelet read-only port, no client certificates, anonymous access limited to health checks | Google's hardening guide. Dataplane V2 enforces NetworkPolicies, egress included. |
| Node pools | `platform` (fixed size) and `apps` (autoscaling), both running as `gke-nodes` | Split by role. `spot` is a setting per pool, `true` in the course's tfvars only because the cluster lives for one cycle. A cluster that matters sets `false`. |
| Webhooks | No firewall rule, no NetworkPolicy | With the DNS endpoint only, GKE reaches admission webhooks through Konnectivity: Pod to Pod from `konnectivity-agent` (kube-system). Default-deny covers only develop, staging, production and minio, where no webhook runs, so nothing more is needed; cluster-conformance C7 checks it every cycle. |
| kubeconfig | `kubeconfig.yaml`, context `gke-sre-control-plane` | The DNS endpoint and `gke-gcloud-auth-plugin`, which gets a short-lived token for whoever runs kubectl. No credentials in the file. |

Not here, on purpose:
- **Customer-managed encryption keys (Cloud KMS).** Google encrypts etcd and disks by default. An own key is a compliance requirement, not a security gain for this platform, and it is billed per key and per operation.
- **Google Managed Prometheus.** The platform runs its own Prometheus, and running both would collect everything twice.

### Run a cycle

The cluster costs money from the first minute: nodes, their disks and the NAT gateway. GKE's free tier credit covers the fee of one zonal cluster per billing account.

```bash
gcloud components install gke-gcloud-auth-plugin   # once
make -C infra/terraform/gke_cluster plan            # read it
make -C infra/terraform/gke_cluster apply           # the cluster, then Flux
kubectl --kubeconfig infra/terraform/gke_cluster/kubeconfig.yaml get nodes
make -C infra/terraform/gke_cluster destroy         # asks first, then runs make leftovers
```

**Flux.** The apply ends with Flux following the platform repository and reconciling `flux/bootstrap/profiles/gke` - the same platform as on Hetzner: the provider-neutral base and every component (the platform's secrets, Cloudflare DNS and Origin CA, Dex, Headlamp, image automation, alert routing, OpenTelemetry). Before Flux starts, Terraform writes what it expects (`flux.tf`): the namespaces, `cluster-config`, `cluster-secrets`, `backup-s3`, the age key `sops-age` and the production database password. A GKE and a Hetzner cluster never run at the same time: they share the DNS names, and image automation writes to the same branch.

- **Settings:** `SOPS_AGE_KEY_FILE` (the platform's age key - no default; `make settings` checks that its public key is a recipient in `.sops.yaml`, so a wrong key stops here, not inside the cluster) and `TF_VAR_uptrace_dsn` (where the OpenTelemetry collectors send logs, traces and metrics - the plan fails without it), in `.env.gcp`.
- **kubectl** goes through `gke-gcloud-auth-plugin`, which signs in as gcloud's active account. `make preflight` (before plan, apply and destroy) stops when that account is not `TF_VAR_expected_principal`.
- **Backups** go to Cloudflare R2 (the plan for every provider): a bucket of its own, not the state bucket, with a key scoped to it. The endpoint and region `auto` are in `terraform.tfvars`; `TF_VAR_backup_s3_bucket`, `TF_VAR_backup_s3_access_key_id` and `TF_VAR_backup_s3_secret_access_key` are required in `.env.gcp` (`make settings` names a missing one). An empty endpoint fails the plan: the CNPG ObjectStore would reject it and no database would be created.
- **Destroy:** before the node pools go, `flux-pre-destroy.sh` suspends Flux and deletes the workload namespaces with their volumes, and the `traefik` namespace with its LoadBalancer Service - GKE deletes the load balancer's forwarding rule, address and firewall rules only with the Service. A persistent disk or a load balancer left behind keeps costing; `make leftovers` names it.

`make leftovers` lists what can outlive a cluster and keep costing money: disks of PersistentVolumes, load balancer forwarding rules and addresses, NEGs, firewall rules, routers, networks and clusters. It exits 1 when anything is left. Delete what it names, then run it again.
