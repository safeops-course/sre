# Exoscale (SKS) - runbook

The Exoscale side of the platform is one Terraform module:

| Module | Lifetime | Who applies it | Costs |
|---|---|---|---|
| `infra/terraform/sks_cluster` | per cycle: created, tested, destroyed | a person (no CI yet - below) | while it exists |

There is no foundation module, as on DigitalOcean. What Exoscale keeps per organization - two-factor
sign-in, the low-credit alert, the IAM role and its API key - is set once by hand (Setup, below): the key the
module runs with is allowed the compute service class only, so it cannot manage IAM itself.

## Setup

### 1. The organization, by hand

- An Exoscale organization for the platform only, with **two-factor authentication**.
- **Billing:** a low-credit alert. It only e-mails; it never stops spending.
- **IAM → Roles → Add:** a role (for example `sre-sks`) whose policy allows the compute service class and
  denies everything else:

  ```json
  {
    "default-service-strategy": "deny",
    "services": { "compute": { "type": "allow" } }
  }
  ```

  SKS, instances, security groups, load balancers and block storage are all in compute. A role without
  compute fails every call with `Forbidden by role policy for compute`.
- **IAM → Keys → Add:** an API key with that role. The secret is shown once - it goes straight into step 2,
  never into a file you keep, a chat or a repository.

### 2. Prerequisites and sign-in - in a config file of its own

- `exo` (github.com/exoscale/cli), `terraform`, `kubectl`, `jq`, `yq` (v4), `age-keygen` and `make`.

```bash
export EXOSCALE_CONFIG=~/.config/exoscale-platform/exoscale.toml   # never exo's default config
touch "$EXOSCALE_CONFIG" && chmod 600 "$EXOSCALE_CONFIG"           # exo refuses a file that does not exist
exo config add                       # the key and secret; the default zone (bg-sof-1)
exo compute security-group show default -O json | jq -r .id        # TF_VAR_expected_default_security_group_id
```

exo keeps the key in `EXOSCALE_CONFIG`. A file of its own keeps this organization apart from any other the
machine knows; the Makefile gives Terraform the key of the file's default account (`EXOSCALE_API_KEY`,
`EXOSCALE_API_SECRET`), and the kubeconfig's exec names the same file. The file holds the secret - protect it
like a key.

### 3. Settings

```bash
cp .env.sks.example .env.sks         # git-ignored
```

Fill in `EXOSCALE_CONFIG` (a full path), the organization's default security group id (step 2), the R2 key,
the backup bucket, the age key file and the Uptrace DSN. The non-personal settings (zone, release, sizes) are
in `infra/terraform/sks_cluster/terraform.tfvars`.

## A cluster cycle

### What it builds, and why

| Piece | What | Why |
|---|---|---|
| Identity check | The plan fails unless the organization's default security group is `TF_VAR_expected_default_security_group_id` | A key of another organization would build everything there. A compute-only key cannot read the organization from IAM; the default security group's id is unique to it and cannot be deleted. |
| Network | A security group of its own for the nodes (`<cluster_name>-sks-nodes`): Cilium's VXLAN (UDP 8472), health checks (TCP 4240, ping), the kubelet (TCP 10250) and node-exporter (TCP 9100) between the nodes; NodePorts (TCP 30000-32767) from anywhere for the load balancer | Exoscale drops every inbound packet a security group does not allow, between the nodes too. The Cilium list is Exoscale's own; node-exporter listens on the node's address, outside the overlay. The nodes have public addresses, and the load balancer has none of its own to allow - so **every** NodePort or LoadBalancer Service is reachable from the internet on them, not only Traefik's (the platform creates no other). The namespaces' default-deny NetworkPolicies still decide which pods answer. |
| IP families | **IPv4 only** for pods, Services and the load balancer | SKS gives pods and Services no IPv6, and its cloud controller has no IPv6 setting for the load balancer. The written exception of `docs/providers.md`, as on EKS and DOKS: cluster-config `ip_stack = "ipv4"`, `service_ip_family_policy = "PreferDualStack"`. |
| Control plane | Public endpoint; by default `pro` (highly available, an SLA) and patch upgrades by Exoscale; the course's tfvars sets `starter` (free, no SLA) and no upgrades | The service level is set at creation: starter can be upgraded to pro later, never the reverse. |
| Version | `kubernetes_version`, a release SKS offers (`exo compute sks versions`), chosen at creation only | `make access` fails when SKS no longer offers it. A minor upgrade is `exo compute sks upgrade`, one minor at a time; until then every plan fails and says so. |
| Add-ons | Cilium, the Exoscale cloud controller (load balancers), the CSI driver (volumes) and metrics-server - all from SKS | Exoscale's default CNI is Calico; Cilium is the platform's everywhere. |
| Node pools | `platform` and `apps`, fixed size | Split by role, as on the other clouds. |
| Storage | A StorageClass `sbs` (Exoscale Block Storage, waits for the pod), the default; no volume expansion | The CSI driver's own class is not the default. Exoscale resizes a volume only while it is detached, so conformance C4 skips the expansion check with that reason. |
| Load balancer | A network load balancer sending to the `platform` pool (`flux/bootstrap/profiles/sks`) | A load balancer sends to one instance pool; without one named, the cloud controller refuses the Service once Traefik runs in both pools. |
| API server port | cluster-config `api_server_port`, read from the EndpointSlice `default/kubernetes` at apply | Behind the Service `kubernetes` the API server listens on a port of Exoscale's own, not 443; `allow-postgres-egress-apiserver` opens it, or CloudNativePG cannot reach the API and no database starts. A port changed later (a control plane upgrade) needs another apply. |
| kubeconfig | `kubeconfig.yaml`, context `sks-sre-control-plane`, exo as the exec plugin with `EXOSCALE_CONFIG` | A short-lived client certificate per call; no credentials in the file. |

What a deleted cluster leaves on Exoscale: its network load balancers and block storage volumes, billed. The
pre-destroy hook deletes the volumes and Traefik's Service while the cluster runs, and `make leftovers` names
whatever is still there. SKS creates an IAM role and key per add-on (cloud controller, CSI) and deletes them
with the cluster; the module's key cannot read IAM, so `make leftovers` does not list them - the console
does (IAM → Keys, names `sks-...`).

### Run a cycle

Two standard.large nodes and the load balancer cost roughly EUR 0.22 an hour, plus the volumes (list prices,
2026-10), with the control plane free (starter).

```bash
make -C infra/terraform/sks_cluster plan             # read it
make -C infra/terraform/sks_cluster apply            # the security group, the cluster, the pools, Flux
kubectl --kubeconfig infra/terraform/sks_cluster/kubeconfig.yaml get nodes
KUBECONFIG=infra/terraform/sks_cluster/kubeconfig.yaml make cluster-conformance KUBE_CONTEXT=sks-sre-control-plane
make -C infra/terraform/sks_cluster destroy          # asks first, then lists leftovers
```

A cycle that tests a branch (pushed first) plans with `TF_VAR_flux_git_repository_branch=<branch>`.

`make leftovers` (`scripts/sks-leftovers.sh`) lists SKS clusters, instance pools, instances, load balancers,
block storage volumes and their snapshots in the cycle's zone, and the cycle's security group. It fails when
anything is left, or when a query fails - never "nothing left" on an error. Delete what it names, then run
it again. After a successful destroy it checks again for up to 2 minutes (`--settle`). Only the cycle's zone:
everything the cycle creates is there, and a listing of every zone fails whenever one zone does not answer.

### CI

Not yet. A run from GitHub Actions would need the API key as a repository secret - a long-lived credential.
Until that is worth it, a person runs the cycle.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `The Exoscale key belongs to the organization whose default security group is X, expected Y` (plan) | `EXOSCALE_CONFIG` holds another organization's key | `exo config add` with the right `EXOSCALE_CONFIG`, or fix `TF_VAR_expected_default_security_group_id`. |
| `Forbidden by role policy for compute` (make, plan) | The key's role does not allow compute | The role's policy (step 1); the key keeps working after the change. |
| `no key and secret of the default account in ...` (make) | The file has no default account, or yq is missing | `exo config add` with `EXOSCALE_CONFIG` set; `yq --version` (v4). |
| `SKS in <zone> no longer offers kubernetes_version` (make plan) | Exoscale dropped that release | A release it lists, in `terraform.tfvars`. `make destroy` does not check it: a running cluster stays destroyable. |
| `app-postgres-1-initdb` pods fail, `dial tcp 10.96.0.1:443: i/o timeout` | The API server's port changed since the last apply | `make plan` / `apply` - it reads the port again (`kubectl get endpointslice -n default kubernetes`). |
| Uptrace: `ProtocolError when calling kubernetes: Response ended prematurely` from `grafana-sc-dashboard` and `grafana-sc-datasources`, once, 15-30 minutes after the cluster was created | SKS closed the open connections to the API server once (seen in both test cycles, 2026-10-24; in the first one Flux and cilium-operator lost theirs too). The clients reconnect by themselves | Nothing, if it does not repeat. Repeated: `kubectl -n observability logs deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard`, and ask Exoscale support about the control plane. |
| Traefik's Service has no external address | The cloud controller refused the annotations | `kubectl -n traefik describe service traefik` shows its events. |
| A volume stays `Pending` after a resize | Exoscale resizes only detached volumes | Not done by the platform (the StorageClass refuses expansion); scale the workload down to resize by hand. |
