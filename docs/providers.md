# Adding a cloud provider

The platform runs the same way on every provider: kind locally, Hetzner, GKE, AWS, Azure, DigitalOcean, Exoscale - and, by the
same pattern, any other. A new provider is a checklist, not a new design. GKE
(`infra/terraform/gcp_foundation`, `infra/terraform/gke_cluster`, `docs/gcp.md`), AWS
(`infra/terraform/aws_foundation`, `infra/terraform/eks_cluster`, `docs/aws.md`) and Azure
(`infra/terraform/azure_foundation`, `infra/terraform/aks_cluster`, `docs/azure.md`) are full examples to copy from;
DigitalOcean (`infra/terraform/doks_cluster`, `docs/digitalocean.md`) and Exoscale (`infra/terraform/sks_cluster`,
`docs/exoscale.md`) are ones without a foundation module.

## Terraform

- [ ] **Two modules when the provider needs account-level setup:** a foundation applied once by a
  person (APIs, identities, CI federation, alerts, budget - nothing billed) and a cluster module
  created and destroyed per cycle. Without an API for that setup (DigitalOcean: two-factor sign-in, spend
  alerts and tokens are console-only; Exoscale: the cycle's key is allowed compute only, never IAM) the cluster
  module alone, and the runbook lists the steps by hand.
- [ ] **Runs from a laptop and from CI, with the same targets** - each its own make call:
  `make -C infra/terraform/<module> preflight`, then `plan`, `apply`, `destroy`, `leftovers`. Plan is saved
  through `scripts/guard-terraform-plan.sh`; apply applies only that plan.
- [ ] **One git-ignored settings file per provider** (`.env.<provider>`, template
  `.env.<provider>.example`): identities, credential file paths, the R2 state key. Secrets are read from
  files, never typed into a command or committed.
- [ ] **preflight fails loudly before anything runs:** every setting present; the identity Terraform
  runs as is the expected one (a plan-time postcondition); the CLI identity kubectl signs in with is the
  same; the age key's public key is a recipient in `.sops.yaml` (no default key path).
- [ ] **Inputs, not hard-coded values;** course choices (sizes, Spot, deletion protection) live in
  `terraform.tfvars`, production-shaped defaults in `variables.tf`.
- [ ] **`make leftovers`** lists everything billable that can outlive the cluster (disks, load
  balancers, addresses, firewall rules, networks) and exits non-zero when anything is left.

## Flux

- [ ] **The same bootstrap as the providers before it, same names and order:** namespaces, `cluster-config`,
  `cluster-secrets`, `backup-s3`, `sops-age` (write-only), the production database password, Flux
  Operator, a FluxInstance on the provider's profile, and a pre-destroy hook that deletes the volumes and
  the namespace of the LoadBalancer Service before the nodes go.
- [ ] **A profile, `flux/bootstrap/profiles/<provider>`:** the provider-neutral base + the components
  the cluster can run + patches only for what is provider-specific (load balancer annotations, ...).
  The base never names a provider.
- [ ] **Clusters of different providers never run at the same time:** they share the DNS names and image
  automation writes to the same branch. The module still writes `cloud_provider` to cluster-config (required:
  the external-dns owner ID is `k8s-external-dns-<cluster_name>-<cloud_provider>`), so if two do run, the
  first keeps the names and the other skips them instead of both rewriting them every minute. The
  pre-destroy hook (`flux-pre-destroy.sh`) deletes the DNS records before the cluster goes.
- [ ] **Backups go to Cloudflare R2,** the same target for every provider.
- [ ] **IPv6 where the provider has it by default** - never switched off, never forced. With it, dual-stack: IPv4 and
  IPv6 for nodes, pods and Services (conformance C13); the load balancer gets both families
  (C5); the module writes its pod IPv6 range to cluster-config `cluster_ipv6_range`, which
  `allow-backend-egress-https` cuts out of `::/0` (on GKE it is global, not in fc00::/7). Every app pod answers on
  both of its addresses (`make smoke-test`: an image that listens on IPv4 only fails there, not as a 502 later).
  Without it by default (EKS gives a cluster IPv4 or IPv6, not both; DOKS IPv6 only on load balancers; SKS none - its cloud
  controller has no IPv6 setting for the load balancer), the module writes `ip_stack = "ipv4"` and
  `service_ip_family_policy = "PreferDualStack"` to cluster-config (`"dual"` and the default `RequireDualStack`
  everywhere else): the apps' and Traefik's Services read the policy (no
  `ipFamilies` - a listed IPv6 would be refused) - a written exception, and conformance C13 checks the promise.
- [ ] **The API server's port:** `allow-postgres-egress-apiserver` opens 443 and 6443, and Cilium checks it against
  the address behind the Service `kubernetes`. Where that is another port (SKS: one of Exoscale's own), the
  module reads it from the EndpointSlice `default/kubernetes` and writes cluster-config `api_server_port`;
  conformance C3 fails when CloudNativePG cannot reach the API server.

## Proof

- [ ] A full cycle: apply, every Flux Kustomization Ready, `make cluster-conformance` (C1-C13, PASS /
  FAIL / SKIP with a reason), destroy, `make leftovers` clean.
- [ ] A runbook `docs/<provider>.md`: what each module creates and why, the cycle, troubleshooting.
