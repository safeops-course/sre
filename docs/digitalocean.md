# DigitalOcean (DOKS) - runbook

The DigitalOcean side of the platform is one Terraform module:

| Module | Lifetime | Who applies it | Costs |
|---|---|---|---|
| `infra/terraform/doks_cluster` | per cycle: created, tested, destroyed | a person (no CI yet - below) | while it exists |

There is no foundation module, unlike GKE, EKS and AKS. What DigitalOcean keeps per account - two-factor
sign-in, the spend alert, the token - has no API to manage it, so it is done once by hand (Setup, below).

## Setup

### 1. The account, by hand

- A DigitalOcean account (team) for the platform only, with **two-factor authentication**.
- **Billing → Spend alerts:** an alert at, for example, 10 USD a month. It only e-mails; it never stops
  spending. There is no API or Terraform resource for it.
- **API → Tokens → Generate new token**, with an expiry and custom scopes - only what the module and
  `make leftovers` use: `kubernetes` (all), `vpc` (all), `load_balancer` (read, delete), `block_storage`
  (read, delete), `block_storage_snapshot` (read, delete), `droplet` (read), `regions` / `sizes` /
  `actions` / `account` (read). Scopes cannot be changed later: a missing one is a new token. The token
  is shown once - it goes straight into step 2, never into a file you keep, a chat or a repository.
- **The region's default VPC**, once, after step 2 (free; `region` in `terraform.tfvars`, ams3):
  `doctl vpcs create --name default-ams3 --region ams3` - DigitalOcean picks its range. The first VPC of a
  region becomes its default, and a default VPC cannot be deleted: without this one the cycle's own VPC
  would be the first, and its destroy would fail. `doctl vpcs list` shows whether the region has one
  already (a droplet or cluster made there earlier creates it); the plan fails while it has none.

### 2. Prerequisites and sign-in - in a config file of its own

- `doctl` (2.0 or later: earlier versions could write a token from the environment into the config file),
  `terraform`, `kubectl`, `jq`, `yq` (v4), `age-keygen` and `make`.

```bash
export DIGITALOCEAN_CONFIG=~/.config/doctl-platform/config.yaml   # never doctl's default config
doctl auth init                     # paste the token; the "default" context of that file
doctl account get --format UUID,Email
```

doctl keeps the token in `DIGITALOCEAN_CONFIG`. A file of its own keeps this account apart from any other
the machine knows; the Makefile gives Terraform the token from it (`DIGITALOCEAN_TOKEN`), and the kubeconfig's
exec names the same file. Use the file's `default` context: under a named context doctl ignores a token in
the environment. The file holds the token - protect it like a key. doctl also caches the cluster's
short-lived tokens in its own cache directory (`~/Library/Application Support/doctl/cache` on macOS); they
expire by themselves.

### 3. Settings

```bash
cp .env.doks.example .env.doks       # git-ignored
```

Fill in `DIGITALOCEAN_CONFIG` (a full path), your account UUID, the R2 key, the backup bucket, the age key
file and the Uptrace DSN. The non-personal settings (region, sizes, ranges) are in
`infra/terraform/doks_cluster/terraform.tfvars`.

## A cluster cycle

### What it builds, and why

| Piece | What | Why |
|---|---|---|
| Identity check | The plan fails unless the token belongs to `TF_VAR_expected_account_uuid` | A token of another account or team would build everything there. |
| Network | A VPC of its own (`<cluster_name>-doks`); a VPC-native cluster: pods and Services get ranges routable in the VPC | Cilium with eBPF in place of kube-proxy; set at creation, the ranges cannot grow later. |
| IP families | **IPv4 only** for nodes, pods and Services; Traefik's load balancer has IPv4 and IPv6 | DOKS gives a cluster no IPv6 - only its load balancers. The written exception of `docs/providers.md`, as on EKS: cluster-config `ip_stack = "ipv4"`, `service_ip_family_policy = "PreferDualStack"`. |
| Control plane | Public endpoint; by default HA ($40 a month) and patch upgrades in a weekly window; the course's tfvars turns both off | HA is DigitalOcean's default from 1.36 and cannot be turned off once on - so the module always sets it. |
| Version | The newest release of `kubernetes_version`'s minor, chosen at creation only | Read again on every plan, a newly published patch would upgrade the cluster at the next apply of anything. A minor upgrade is `doctl kubernetes cluster upgrade`, one minor at a time; until then every plan fails and says so. |
| Node pools | `platform` (the cluster's default pool) and `apps`, fixed size | Split by role, as on the other clouds. |
| Storage | DOKS's own StorageClass `do-block-storage` (expandable) is the default | Nothing to add. |
| metrics-server | Helm chart, as on kind | DOKS has none; `kubectl top` and the HPA need it. |
| Load balancer | `REGIONAL`, dual-stack (`flux/bootstrap/profiles/doks`) | The default type (`REGIONAL_NETWORK`) is IPv4 only on DOKS. |
| kubeconfig | `kubeconfig.yaml`, context `doks-sre-control-plane`, doctl as the exec plugin with `DIGITALOCEAN_CONFIG` | A short-lived token per call; no credentials in the file. |

What a deleted cluster leaves on DigitalOcean: its load balancers, volumes and volume snapshots, billed.
The destroy removes them three ways: the pre-destroy hook deletes the volumes and Traefik's Service while
the cluster runs, the course's tfvars sets `destroy_all_associated_resources`, and `make leftovers` names
whatever is still there. A production cluster keeps `destroy_all_associated_resources = false`: a volume
is data.

### Run a cycle

Two s-4vcpu-8gb nodes, the regional load balancer and the volumes cost roughly $0.17 an hour (list prices,
2026-10), with the control plane free (no HA).

```bash
make -C infra/terraform/doks_cluster plan            # read it
make -C infra/terraform/doks_cluster apply           # the VPC, the cluster, the pools, metrics-server, Flux
kubectl --kubeconfig infra/terraform/doks_cluster/kubeconfig.yaml get nodes
KUBECONFIG=infra/terraform/doks_cluster/kubeconfig.yaml make cluster-conformance KUBE_CONTEXT=doks-sre-control-plane
make -C infra/terraform/doks_cluster destroy         # asks first, then lists leftovers
```

A cycle that tests a branch (pushed first) plans with `TF_VAR_flux_git_repository_branch=<branch>`.

`make leftovers` (`scripts/doks-leftovers.sh`) lists Kubernetes clusters, droplets, load balancers,
volumes, volume snapshots and the cycle's VPC in the team. It fails when anything is left, or when a query
fails - never "nothing left" on an error. Delete what it names, then run it again. After a successful
destroy it checks again for up to 2 minutes (`--settle`): DigitalOcean deletes the load balancers and
volumes in the background, so they can be listed for a while after the destroy returned.

### CI

Not yet. DigitalOcean has no federation for GitHub Actions (no short-lived token from the workflow's
OIDC identity), so CI would need a long-lived token as a repository secret. Until that is worth it, a
person runs the cycle.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `The DigitalOcean token belongs to account X, expected Y` (plan) | `DIGITALOCEAN_CONFIG` holds another account's token | `doctl auth init` with the right `DIGITALOCEAN_CONFIG`, or fix `TF_VAR_expected_account_uuid`. |
| `no access-token in ...` (make) | The token is in a named doctl context, or yq is missing | `doctl auth init` without `--context`, so the file's `default` context has it. |
| `doctl cannot sign in` (make) | The token expired or was revoked | A new token (step 1), then `doctl auth init` again. |
| The VPC or the cluster is refused for overlapping ranges | `vpc_cidr`, `cluster_subnet` or `service_subnet` overlaps another VPC of the team - the default VPCs included: DigitalOcean makes one per region the team uses, a /16 out of 10.0.0.0/8, which is why the ranges are in 172.16.0.0/12 | Other ranges in `terraform.tfvars` (`doctl vpcs list` shows the team's). |
| `unable to find default VPC in <region> region` (plan) | The region has no default VPC yet | Create it (step 1, the region's default VPC). |
| `<cluster_name>-doks is the default VPC of <region>` (plan), or `Can not delete default VPCs` (destroy) | The cycle's VPC was the region's first, so DigitalOcean made it the default | `doctl vpcs create --name default-<region> --region <region>`, then `doctl vpcs update <its id> --default=true`, then `make destroy` again. |
| 403 on create or delete | The token lacks a scope | A new token with the scope (step 1) - scopes cannot be added. |
| Traefik's Service has no external address | The cloud controller refused the annotations | `kubectl -n traefik describe service traefik` shows its events. |
