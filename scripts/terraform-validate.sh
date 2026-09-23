#!/bin/bash
set -e
cd infra/terraform/hcloud_cluster
if [ ! -d .terraform ]; then
    terraform init -input=false -backend=false
fi
terraform validate
