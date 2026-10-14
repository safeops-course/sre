# Upgrading the kind cluster

Every version this module installs is pinned, so a rebuild gives the same cluster:

| What | Where | Pinned to |
|---|---|---|
| Terraform providers | `main.tf` (`required_providers`) | kind ~> 0.11, helm ~> 3.3, kubernetes ~> 3.2, null, random, local, time |
| Kubernetes | `variables.tf` `kind_node_image` | `kindest/node:v1.36.4@sha256:...` (one minor behind Hetzner until the kind provider supports 1.37 - see the variable) |
| Flux Operator | `variables.tf` `flux_operator_version` | `0.61.0` (install.yaml of that GitHub release) |
| Flux | `variables.tf` `flux_version` | `2.9.6` |
| metrics-server chart | `variables.tf` `metrics_server_chart_version` | `3.14.0` |

To upgrade one of them: change the default (or set it in `terraform.tfvars`), then plan, read, apply:

```bash
cd infra/terraform/kind_cluster
terraform init -upgrade
terraform plan        # read every replace/destroy before you apply
terraform apply
```

- A new `kind_node_image` means a **new cluster**, and that is a destroy, then an apply - not one
  plan. The Kubernetes and Helm providers are configured from the cluster being replaced: in one plan
  they have no address, and refreshing the objects in the old cluster fails with `connection refused`
  on `localhost` (seen on the v1.36 -> v1.37 upgrade, 2026-10-11). So:

  ```bash
  make kind-destroy                  # the lab's databases go with it; age.agekey and .minio-data (backups) stay
  make kind-plan && make kind-apply  # expect: everything to add, nothing to change or destroy
  ```

  The generated passwords are new (their `random_password` goes with the state); Flux rebuilds
  everything else from your fork.
- A new `flux_operator_version` or `flux_version` re-applies the operator or the FluxInstance.
- After the apply: `flux get kustomizations -A` (all Ready), `make smoke-test` (9/9), and
  `terraform plan -detailed-exitcode` returns `0`.

## One-time step: upgrade of 2026-09 (Kubernetes v1.36, providers kubernetes v3 / helm v3)

This upgrade replaces the deprecated `kubernetes_secret` / `kubernetes_namespace` /
`kubernetes_config_map` with their `_v1` versions **and** recreates the cluster for Kubernetes v1.36.
Terraform cannot do both in one plan: the old resources need the old cluster's API, which is being
replaced (the plan fails with `connection refused` on `localhost` or a dependency cycle).

If your cluster was built before this change, remove the old addresses from the state once - the
objects themselves disappear with the old cluster:

```bash
cd infra/terraform/kind_cluster
cp terraform.tfstate terraform.tfstate.pre-v1.36    # your own backup
terraform state list | grep -E '^kubernetes_(namespace|secret|config_map)\.' \
  | while read -r addr; do terraform state rm "$addr"; done
terraform init -upgrade
terraform plan    # expect: kind_cluster.sre must be replaced, everything else created
terraform apply
```

A fresh clone does not need this step. Rebuilding from scratch also works: `terraform destroy` with
the old version, then pull and `terraform apply`.
