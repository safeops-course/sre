#!/usr/bin/env bash
# cluster-conformance.sh - does this cluster give what the platform needs?
#
# The platform runs on any cluster that keeps a short contract (C1-C12): the Kubernetes version Git
# pins, NetworkPolicies that are enforced (egress too), a default StorageClass, a load balancer for
# the ingress, metrics-server, reachable admission webhooks, backups to S3, images for the nodes'
# architecture. This script checks the contract on a running cluster with the platform installed -
# the layer below tests/smoke-test.sh (do the apps answer?). One line per item: PASS, FAIL or SKIP
# with the reason. A SKIP is never a quiet pass: it names what was not checked and why.
#
# Usage: scripts/cluster-conformance.sh            (or: make cluster-conformance KUBE_CONTEXT=...)
#   KUBE_CONTEXT           the cluster (default kind-sre-control-plane); every kubectl call names it
#   EXPECTED_K8S_VERSION   the version Git pins for this cluster (x.y.z). Known for kind and Hetzner
#                          (read from their Terraform variables); required for any other cluster.
#
# Changes: creates the namespace "conformance" (Pod Security restricted) with a few pods, a Service,
# NetworkPolicies and one PersistentVolumeClaim - on a cloud a real disk for about a minute - and
# deletes the namespace at the end, also after a failure. Never touches develop/staging/production:
# the webhook check there is a server-side dry run (nothing is stored). Nothing else changes.
# Needs: kubectl, jq; docker for C11 (else SKIP). Exit code: 0 every item PASS or SKIP, 1 a FAIL,
# 2 the cluster does not answer.
set -Eeuo pipefail

CONTEXT="${KUBE_CONTEXT:-kind-sre-control-plane}"
NS=conformance
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0

# k ARGS... - kubectl against the chosen cluster only (never the current context, Chapter 01).
k() { kubectl --context "$CONTEXT" "$@"; }

# pass|fail|skip ITEM TEXT - one result line; fail counts towards the exit code.
pass() { printf 'PASS  %-4s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-4s %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
skip() { printf 'SKIP  %-4s %s\n' "$1" "$2"; }

# cleanup - delete the test namespace and wait, so a cloud disk is gone before the script ends.
cleanup() { k delete namespace "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || echo "warning: namespace $NS is still being deleted - check: kubectl --context $CONTEXT get ns $NS" >&2; }

# probe [-l key=value]... HOST PORT - "open" or "blocked" from a pod in $NS (scripts/np-probe.sh);
# anything else (DNS failed, the probe pod did not run) is printed as is. k3s applies a new policy
# to a new pod a moment late, so a verdict that differs from WANT is retried twice.
probe() {
  local want="$1"; shift
  local out rc
  for _ in 1 2 3; do
    rc=0; out="$(KUBE_CONTEXT="$CONTEXT" "$ROOT/scripts/np-probe.sh" -n "$NS" "$@" 2>&1)" || rc=$?
    case "$rc" in 0) out=open ;; 1) out=blocked ;; esac
    [ "$out" = "$want" ] && break
    sleep 3
  done
  echo "$out"
}

# expected_version - the Kubernetes version Git pins for this cluster: EXPECTED_K8S_VERSION, else the
# kind node image or the Hetzner k3s version from the Terraform variables; empty when unknown.
expected_version() {
  if [ -n "${EXPECTED_K8S_VERSION:-}" ]; then echo "$EXPECTED_K8S_VERSION"; return; fi
  case "$CONTEXT" in
    kind-*) grep -oE 'kindest/node:v[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/infra/terraform/kind_cluster/variables.tf" | head -1 | sed 's/.*:v//' ;;
    hetzner-*) awk '/variable "k3s_version"/,/^}/' "$ROOT/infra/terraform/hcloud_cluster/variables.tf" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^v//' ;;
  esac
}

if ! k get --raw /readyz >/dev/null 2>&1; then
  echo "cluster $CONTEXT does not answer (kubectl --context $CONTEXT get --raw /readyz)" >&2
  exit 2
fi
echo "Cluster contract - $CONTEXT"
trap cleanup EXIT
cleanup

# C1 - the version Git pins, exactly: an older cluster misses what the policies and charts were
# tested on, a newer one was never tested.
# A command that fails inside a check is that check's FAIL, never the end of the run: each one below
# catches its own error (|| ...), so the remaining checks and the summary always print.
want="$(expected_version)" || want=""
have="$(k version -o json | jq -r .serverVersion.gitVersion | sed -E 's/^v//; s/[+-].*//')" || have=""
if [ -z "$have" ]; then
  fail C1 "could not read the server version (kubectl version)"
elif [ -z "$want" ]; then
  fail C1 "Kubernetes $have - unknown pin for $CONTEXT: set EXPECTED_K8S_VERSION"
elif [ "$have" = "$want" ]; then
  pass C1 "Kubernetes $have = the version Git pins"
else
  fail C1 "Kubernetes $have, Git pins $want"
fi

# The test namespace, with the Pod Security level of the application namespaces.
k create namespace "$NS" >/dev/null
k label namespace "$NS" pod-security.kubernetes.io/enforce=restricted >/dev/null
k -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: server
  labels: { app: server }
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: httpd
      image: busybox:1.38
      command: [httpd, -f, -p, "8080", -h, /tmp]
      ports: [{ containerPort: 8080 }]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts: [{ name: tmp, mountPath: /tmp }]
  volumes: [{ name: tmp, emptyDir: { sizeLimit: 1Mi } }]
---
apiVersion: v1
kind: Service
metadata:
  name: server
spec:
  selector: { app: server }
  ports: [{ port: 8080, targetPort: 8080 }]
EOF
server_ready=true
k -n "$NS" wait --for=condition=Ready pod/server --timeout=120s >/dev/null 2>&1 || server_ready=false

# C2 - NetworkPolicies are enforced, egress included. Four probes from a pod labelled app=client:
# open with no policy; blocked by the platform's own default-deny-all (+ DNS); still blocked once the
# server admits the client (only egress is left closed - proves egress is enforced); open once the
# client may also send. A CNI that ignores policies passes the first probe and fails the second.
np="$ROOT/flux/infrastructure/network-policies/base"
if [ "$server_ready" = false ]; then
  fail C2 "the test server pod was not Ready within 2 min - no probe possible"
else
  r1="$(probe open -l app=client server 8080)"
  k -n "$NS" apply -f "$np/default-deny-all.yaml" -f "$np/allow-dns-egress.yaml" >/dev/null
  r2="$(probe blocked -l app=client server 8080)"
  k -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: server-from-client
spec:
  podSelector: { matchLabels: { app: server } }
  policyTypes: [Ingress]
  ingress: [{ from: [{ podSelector: { matchLabels: { app: client } } }], ports: [{ port: 8080 }] }]
EOF
  r3="$(probe blocked -l app=client server 8080)"
  k -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: client-to-server
spec:
  podSelector: { matchLabels: { app: client } }
  policyTypes: [Egress]
  egress: [{ to: [{ podSelector: { matchLabels: { app: server } } }], ports: [{ port: 8080 }] }]
EOF
  r4="$(probe open -l app=client server 8080)"
  if [ "$r1 $r2 $r3 $r4" = "open blocked blocked open" ]; then
    pass C2 "NetworkPolicies enforced: no policy open, default-deny blocked, ingress-only blocked (egress enforced), both allowed open"
  else
    fail C2 "NetworkPolicies - expected open/blocked/blocked/open, got $r1/$r2/$r3/$r4"
  fi
fi

# C3 - a pod reaches the API server through the platform's own egress rule (the one CloudNativePG
# needs), and only through it. Default-deny is in place, so first a control probe without the rule's
# label: some CNIs never apply policies to the API server (on kind it lives in the node's host
# network - NetworkPolicy leaves that undefined), and then the rule is not exercised at all - SKIP,
# not a pass. Where the control is blocked, the labelled probe must get through: the rule allows TCP
# 6443, so a provider whose API server listens elsewhere (443 on most managed clouds) fails here.
# busybox's nslookup ignores search domains for a dotted name - hence the full name.
api=kubernetes.default.svc.cluster.local
k -n "$NS" apply -f "$np/allow-postgres-egress-apiserver.yaml" >/dev/null
control="$(probe blocked -l app=control "$api" 443)"
if [ "$control" = open ]; then
  skip C3 "API server egress - this CNI does not apply policies to the API server (open under default-deny); the rule is not exercised here"
elif [ "$control" = blocked ]; then
  r="$(probe open -l cnpg.io/cluster=app-postgres "$api" 443)"
  if [ "$r" = open ]; then
    pass C3 "API server: blocked by default-deny, reachable through allow-postgres-egress-apiserver"
  else
    fail C3 "API server not reachable through allow-postgres-egress-apiserver ($r) - its port or address differs here"
  fi
else
  fail C3 "API server egress - no verdict from the control probe: $control"
fi

# C4 - a default StorageClass gives a disk a non-root pod can write. Expansion is checked only where
# the StorageClass allows it (kind's local-path does not; the platform never resizes a disk).
sc="$(k get storageclass -o json | jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")] | .[0] | "\(.metadata.name) \(.allowVolumeExpansion // false)"')" || sc=""
if [ "$sc" = "null false" ] || [ -z "$sc" ]; then
  fail C4 "no default StorageClass"
else
  k -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: disk
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata:
  name: disk-writer
  labels: { app: disk-writer }
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 65532, fsGroup: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: writer
      image: busybox:1.38
      command: [sh, -c, "echo ok > /data/ok && cat /data/ok && sleep 600"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts: [{ name: disk, mountPath: /data }]
  volumes: [{ name: disk, persistentVolumeClaim: { claimName: disk } }]
EOF
  if k -n "$NS" wait --for=condition=Ready pod/disk-writer --timeout=180s >/dev/null 2>&1 && [ "$(k -n "$NS" logs disk-writer 2>/dev/null)" = ok ]; then
    size="$(k -n "$NS" get pvc disk -o jsonpath='{.status.capacity.storage}')"
    pass C4 "default StorageClass ${sc% *}: disk bound ($size), written by a non-root pod"
    if [ "${sc#* }" = true ]; then
      # One Gi more than the disk got (a cloud rounds 1Gi up - Hetzner gives 10Gi).
      gi="$(k -n "$NS" get pvc disk -o jsonpath='{.status.capacity.storage}' | sed -n 's/^\([0-9][0-9]*\)Gi$/\1/p')" || gi=""
      bigger="$((${gi:-0} + 1))Gi"
      if [ -z "$gi" ]; then
        fail C4 "expansion - the disk's capacity is not in Gi ($size)"
      elif ! k -n "$NS" patch pvc disk --type merge -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$bigger\"}}}}" >/dev/null; then
        fail C4 "expansion - the resize to $bigger was refused"
      else
        grown=""
        for _ in $(seq 1 24); do
          grown="$(k -n "$NS" get pvc disk -o jsonpath='{.status.capacity.storage}')" || grown=""
          [ "$grown" = "$bigger" ] && break
          sleep 5
        done
        if [ "$grown" = "$bigger" ]; then pass C4 "disk expanded online to $bigger"; else fail C4 "disk not expanded to $bigger within 2 min (capacity $grown)"; fi
      fi
    else
      skip C4 "expansion - StorageClass ${sc% *} does not allow it (the platform never resizes a disk)"
    fi
  else
    fail C4 "default StorageClass ${sc% *}: the disk was not bound or not writable within 3 min ($(k -n "$NS" get pvc disk -o jsonpath='{.status.phase}'))"
  fi
fi

# C5 - the ingress gets an address: Traefik's Service (Flux) has one from the provider's load balancer.
# No new load balancer is created - it would cost money and could outlive the run.
svc="$(k -n traefik get service traefik -o json 2>/dev/null || echo '{}')"
case "$(jq -r '.spec.type // "missing"' <<<"$svc")" in
  LoadBalancer)
    addr="$(jq -r '.status.loadBalancer.ingress[0].ip // .status.loadBalancer.ingress[0].hostname // empty' <<<"$svc")"
    if [ -n "$addr" ]; then pass C5 "load balancer for the ingress: $addr"; else fail C5 "Traefik's Service has no load balancer address"; fi ;;
  NodePort) skip C5 "kind: Traefik is a NodePort (localhost:8080/8443), no load balancer by design" ;;
  *) fail C5 "no Service traefik/traefik - the ingress is missing" ;;
esac

# C6 - metrics-server answers (kubectl top, the HPA in Chapter 09).
if top="$(k top nodes --no-headers 2>/dev/null)" && [ -n "$top" ]; then
  pass C6 "metrics-server: kubectl top nodes answers ($(grep -c . <<<"$top") nodes)"
else
  fail C6 "metrics-server: kubectl top nodes gives nothing"
fi

# C7 - the API server reaches the admission webhooks: a pod Kyverno must refuse (tag latest), valid
# for Pod Security restricted so only the webhook can refuse it - a server-side dry run in develop,
# nothing is stored.
out="$(k -n develop run conformance-webhook --image=busybox:latest --restart=Never --dry-run=server \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"conformance-webhook","image":"busybox:latest","resources":{"requests":{"cpu":"10m","memory":"64Mi"},"limits":{"cpu":"50m","memory":"64Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' 2>&1 || true)"
if grep -q "disallow-latest-tag" <<<"$out"; then
  pass C7 "admission webhooks reachable: Kyverno refused a latest tag (dry run)"
else
  fail C7 "admission webhooks: expected Kyverno's disallow-latest-tag refusal, got: $(head -c 200 <<<"$out")"
fi

# C8 - API-server OIDC for the Dex roles: a real sign-in needs a browser and a GitHub account.
skip C8 "OIDC sign-in - manual: kubectl oidc-login (CLAUDE.md); kind has none (Chapter 21 uses --as)"

# C9 - backups reach the object storage: every CloudNativePG cluster archives its WAL.
if ! dbs="$(k get clusters.postgresql.cnpg.io -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) \([.status.conditions[]? | select(.type == "ContinuousArchiving")][0].status // "none")"')"; then
  fail C9 "could not list the CloudNativePG clusters (is the operator installed?)"
elif [ -z "$dbs" ]; then
  fail C9 "no CloudNativePG clusters to check the backups of"
elif bad="$(awk '$2 != "True"' <<<"$dbs")" && [ -z "$bad" ]; then
  pass C9 "WAL archiving to object storage: $(awk '{print $1}' <<<"$dbs" | tr '\n' ' ')"
else
  fail C9 "WAL archiving not True: $(tr '\n' ' ' <<<"$bad")"
fi

# C10 - node upgrades are a procedure (Chapter 20), not a state to check.
skip C10 "node upgrades - a procedure, Chapter 20"

# C11 - the platform's own images exist for every node architecture (kind on a Mac is arm64, the
# clouds mostly amd64). Third-party images come from multi-arch charts; ours are built by build.yml.
archs="$(k get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -u)" || archs=""
registry="$(k -n flux-system get configmap cluster-config -o jsonpath='{.data.image_registry}' 2>/dev/null || true)"
if ! command -v docker >/dev/null 2>&1; then
  skip C11 "image architectures - docker not found (nodes: $(tr '\n' ' ' <<<"$archs"))"
elif [ -z "$archs" ]; then
  fail C11 "could not read the nodes' architectures"
elif [ -z "$registry" ]; then
  fail C11 "no image_registry in flux-system/cluster-config"
else
  images="$(k get pods -A -o json | jq -r --arg r "$registry/" '.items[].spec.containers[].image | select(startswith($r))' | sort -u)" || images=""
  missing=""
  for image in $images; do
    platforms="$(docker buildx imagetools inspect "$image" 2>/dev/null | awk '/Platform:/ {print $2}')"
    for arch in $archs; do
      grep -qx "linux/$arch" <<<"$platforms" || missing+=" $image ($arch)"
    done
  done
  if [ -z "$images" ]; then
    fail C11 "no running image from $registry"
  elif [ -z "$missing" ]; then
    pass C11 "$(grep -c . <<<"$images") platform images built for $(tr '\n' ' ' <<<"$archs")"
  else
    fail C11 "images without a build for the nodes:$missing"
  fi
fi

# C12 - nothing billed is left after a destroy: a check after the cluster is gone, not on it.
skip C12 "teardown leftovers - after destroy: scripts/hcloud-leftovers.sh (Hetzner)"

echo
if [ "$FAILS" -eq 0 ]; then echo "Contract kept on $CONTEXT"; else echo "$FAILS item(s) FAIL on $CONTEXT"; fi
[ "$FAILS" -eq 0 ]
