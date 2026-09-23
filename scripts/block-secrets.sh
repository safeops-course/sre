#!/bin/bash
echo "BLOCKED: Sensitive file detected in commit!"
echo "Files matching: kubeconfig, .key, .pem, credentials, .env"
exit 1
