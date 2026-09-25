#!/bin/bash
set -e
# Validate every Terraform module the course uses: the local kind cluster
# (core track) and the Hetzner cluster (cloud track).
for dir in infra/terraform/kind_cluster infra/terraform/hcloud_cluster; do
    echo "terraform validate: ${dir}"
    if [ ! -d "${dir}/.terraform" ]; then
        terraform -chdir="${dir}" init -input=false -backend=false >/dev/null
    fi
    terraform -chdir="${dir}" validate
done
