#!/usr/bin/env bash
# Test of infra/terraform/hcloud_cluster/audit-policy.yaml, the k3s API server's audit policy.
#
# 1. The file has no double quote, dollar sign, backtick or backslash: kube-hetzner 3.2.1 pastes it
#    unescaped into a double-quoted string of a root shell script on the control plane nodes.
# 2. The k3s version the Hetzner cluster pins (terraform.tfvars k3s_version) starts with the policy, with
#    the flags kube-hetzner adds - a typo in the policy would stop the API server there.
# 3. The log keeps what the policy promises (a Secret read, a change, kubectl exec) and drops what it
#    promises to drop (other reads, leases, probes, request bodies, the Secret's value).
#
# Runs k3s in a throw-away Docker container; kubectl runs inside it, no kubeconfig is touched. Needs
# Docker and the network (the k3s and busybox images).
# Usage: tests/k3s-audit-policy.test.sh
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="${ROOT}/infra/terraform/hcloud_cluster/audit-policy.yaml"
TFVARS="${ROOT}/infra/terraform/hcloud_cluster/terraform.tfvars"
NAME="k3s-audit-policy-test-$$"
FAILED=0

# fail MESSAGE - report one failed check and remember it (the script exits non-zero at the end).
fail() {
  echo "FAIL: $*"
  FAILED=1
}

# cleanup - remove the container, also when a command above fails.
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# k ARGS... - kubectl inside the k3s container.
k() {
  docker exec "$NAME" kubectl "$@"
}

# 1. Characters the module's shell script cannot take.
policy=$(<"$POLICY")
if grep -nE '["$`\\]' <<<"$policy"; then
  fail "audit-policy.yaml has a double quote, dollar sign, backtick or backslash (lines above)"
fi

# 2. Start k3s with the policy. The image tag is the version with - instead of + (v1.36.4+k3s1 -> v1.36.4-k3s1).
version=$(sed -nE 's/^k3s_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TFVARS")
[[ -n "$version" ]] || { echo "FAIL: no k3s_version in $TFVARS"; exit 1; }
image="rancher/k3s:${version/+/-}"
echo "k3s: $image"
docker run -d --name "$NAME" --privileged \
  -v "$POLICY":/etc/rancher/k3s/audit-policy.yaml:ro \
  "$image" server --disable=traefik,metrics-server \
  --kube-apiserver-arg=audit-policy-file=/etc/rancher/k3s/audit-policy.yaml \
  --kube-apiserver-arg=audit-log-path=/var/log/k3s-audit/audit.log \
  --kube-apiserver-arg=audit-log-maxage=30 \
  --kube-apiserver-arg=audit-log-maxbackup=10 \
  --kube-apiserver-arg=audit-log-maxsize=100 >/dev/null

ready=false
for _ in $(seq 1 90); do
  if k get --raw /readyz >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  docker logs "$NAME" 2>&1 | grep -iE 'audit|error' | tail -20
  echo "FAIL: the API server did not start with the policy"
  exit 1
fi
# A pod needs the namespace's default ServiceAccount, which a controller creates just after start.
for _ in $(seq 1 30); do
  k get serviceaccount default >/dev/null 2>&1 && break
  sleep 2
done

# 3. Requests whose records the log must, or must not, have.
k create secret generic audit-probe --from-literal=password=audit-probe-value >/dev/null
k get secret audit-probe -o name >/dev/null
k create configmap audit-cm --from-literal=a=b >/dev/null
k get configmap audit-cm -o name >/dev/null
k delete configmap audit-cm >/dev/null
k run audit-pod --image=busybox:1.37 --restart=Never -- sleep 600 >/dev/null
k wait --for=condition=Ready pod/audit-pod --timeout=180s >/dev/null
k exec audit-pod -- true
sleep 3
log=$(docker exec "$NAME" cat /var/log/k3s-audit/audit.log)

for want in '"verb":"create".*"resource":"secrets".*"name":"audit-probe"' \
            '"verb":"get".*"resource":"secrets".*"name":"audit-probe"' \
            '"verb":"create".*"resource":"configmaps".*"name":"audit-cm"' \
            '"verb":"delete".*"resource":"configmaps".*"name":"audit-cm"' \
            '"name":"audit-pod".*"subresource":"exec"'; do
  grep -Eq "$want" <<<"$log" || fail "not in the audit log: $want"
done

# The Secret's value in plain text and in base64 ("audit-probe-value").
for unwanted in '"verb":"get".*"resource":"configmaps".*"name":"audit-cm"' '"resource":"leases"' \
                '"requestURI":"/readyz' '"requestObject"' '"responseObject"' \
                'audit-probe-value' 'YXVkaXQtcHJvYmUtdmFsdWU'; do
  if grep -Eq "$unwanted" <<<"$log"; then fail "in the audit log, but should not be: $unwanted"; fi
done

echo "audit log: $(wc -l <<<"$log") lines"
if [[ "$FAILED" -ne 0 ]]; then exit 1; fi
echo "OK: the policy loads in $image and logs what it promises"
