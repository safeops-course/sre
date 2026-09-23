#!/bin/bash
set -e
if command -v checkov &>/dev/null; then
    checkov -d infra/terraform/hcloud_cluster --framework terraform --quiet --compact
else
    echo "WARNING: checkov not installed — skipping security scan"
    echo "Install with: pip install checkov"
fi
