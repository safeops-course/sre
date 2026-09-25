#!/bin/bash
set -e
# Validate every Terraform module the course uses: the local kind cluster
# (core track) and the Hetzner cluster (cloud track).
for dir in infra/terraform/kind_cluster infra/terraform/hcloud_cluster; do
    echo "terraform validate: ${dir}"
    # Always init: an existing but stale .terraform (a provider or module
    # added since the last init) makes validate fail with "Missing required
    # provider". -backend=false never touches the state or its backend.
    terraform -chdir="${dir}" init -input=false -backend=false >/dev/null
    terraform -chdir="${dir}" validate
done
