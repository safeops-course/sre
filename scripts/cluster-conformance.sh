#!/usr/bin/env bash
# cluster-conformance.sh - does this cluster give what the platform needs?
#
# The platform runs on any cluster that keeps a short contract (C1-C13): the Kubernetes version Git
# pins (on a managed cluster without a pin: the platform's minor), NetworkPolicies that are enforced (egress too), a default StorageClass, a load balancer for
# the ingress, metrics-server, reachable admission webhooks, backups to S3, images for the nodes'
# architecture, and the address families the provider promises (C13: cluster-config ip_stack - "dual",
# IPv4 and IPv6 for every node, pod and Service, where the provider has IPv6 by default; "ipv4" where it
# has not; on "dual" C2 and C5 check both families - even when IPv6 is gone, so they fail too). This script checks the contract on a running cluster with the platform installed -
# the layer below tests/smoke-test.sh (do the apps answer?). One line per item: PASS, FAIL or SKIP
# with the reason. A SKIP is never a quiet pass: it names what was not checked and why.
#
# Usage: scripts/cluster-conformance.sh            (or: make cluster-conformance KUBE_CONTEXT=...)
#   KUBE_CONTEXT           the cluster (default kind-sre-control-plane); every kubectl call names it
#   EXPECTED_K8S_VERSION   the version Git pins for this cluster (x.y.z). Known for kind, Hetzner and SKS (auto_upgrade = false)
#                          (read from their Terraform variables). Without one (a managed cluster runs
#                          the version its provider offers) C1 checks the minor against kind's pin.
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
# kind node image, the Hetzner k3s_version - terraform.tfvars when it sets one, else the variable's
# default (never its description, which carries an example) - or the SKS kubernetes_version; empty when unknown.
expected_version() {
  if [ -n "${EXPECTED_K8S_VERSION:-}" ]; then echo "$EXPECTED_K8S_VERSION"; return; fi
  local hcloud="$ROOT/infra/terraform/hcloud_cluster" sks="$ROOT/infra/terraform/sks_cluster" pin
  case "$CONTEXT" in
    kind-*) grep -oE 'kindest/node:v[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/infra/terraform/kind_cluster/variables.tf" | head -1 | sed 's/.*:v//' ;;
    hetzner-*)
      pin="$(grep -E '^k3s_version *=' "$hcloud/terraform.tfvars" 2>/dev/null || true)"
      [ -n "$pin" ] || pin="$(awk '/variable "k3s_version"/,/^}/' "$hcloud/variables.tf" | grep -E '^ *default *=')"
      grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' <<<"$pin" | head -1 | sed 's/^v//' ;;
    sks-*)
      # SKS keeps the release Git pins only while Exoscale may not upgrade it (auto_upgrade = false, the
      # course's choice); with auto_upgrade it picks the patch, and C1 checks the minor as for GKE.
      grep -qE '^auto_upgrade *= *false' "$sks/terraform.tfvars" 2>/dev/null || return 0
      grep -E '^kubernetes_version *=' "$sks/terraform.tfvars" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 ;;
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
# tested on, a newer one was never tested. A cluster without a pin in Git (a managed one: the
# provider picks the patch) must run the platform's minor - the one kind pins and every check is
# tested on.
# A command that fails inside a check is that check's FAIL, never the end of the run: each one below
# catches its own error (|| ...), so the remaining checks and the summary always print.
want="$(expected_version)" || want=""
have="$(k version -o json | jq -r .serverVersion.gitVersion | sed -E 's/^v//; s/[+-].*//')" || have=""
if [ -z "$have" ]; then
  fail C1 "could not read the server version (kubectl version)"
elif [ -z "$want" ]; then
  minor="$(CONTEXT=kind-sre-control-plane expected_version | cut -d. -f1,2)"
  if [ -z "$minor" ]; then
    fail C1 "Kubernetes $have - no pin for $CONTEXT and could not read kind's pin"
  elif [ "$(cut -d. -f1,2 <<<"$have")" = "$minor" ]; then
    pass C1 "Kubernetes $have - no pin in Git for $CONTEXT, the platform's minor $minor (the provider picks the patch)"
  else
    fail C1 "Kubernetes $have - no pin in Git for $CONTEXT, the platform runs $minor (kind's pin)"
  fi
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
  # Both families where the cluster has them (C13 reads its clusterIPs); one where it has not.
  ipFamilyPolicy: PreferDualStack
  selector: { app: server }
  ports: [{ port: 8080, targetPort: 8080 }]
EOF
server_ready=true
k -n "$NS" wait --for=condition=Ready pod/server --timeout=120s >/dev/null 2>&1 || server_ready=false

# Dual-stack (C13, printed last): every node has a pod range of each family (or its pods have addresses of
# each - below), and the test Service got an address of each. Decided here, with the provider's promise
# below, because C2 and C5 depend on it.
families_of() { local v4=no v6=no x; for x in $1; do case "$x" in *:*) v6=yes ;; *.*) v4=yes ;; esac; done; echo "$v4 $v6"; }
# nodes_not FAMILIES - the nodes whose pod ranges are not FAMILIES (a families_of answer, e.g. "yes yes").
nodes_not() { local name cidrs; while read -r name cidrs; do [ -z "$name" ] && continue; [ "$(families_of "$cidrs")" = "$1" ] || echo "$name"; done <<<"$node_cidrs"; }
node_cidrs="$(k get nodes -o json | jq -r '.items[] | "\(.metadata.name) \((.spec.podCIDRs // []) | join(" "))"')" || node_cidrs=""
# A CNI that hands out pod addresses itself leaves spec.podCIDRs empty (EKS's VPC CNI; Azure CNI Overlay
# with Cilium on AKS). For such a node the families come from its pods' own addresses, pod by pod: one pod
# without both families makes the node single-stack (its addresses stand for the node), otherwise any pod's
# do. hostNetwork pods have the node's addresses and are left out; a node with no other pod (a fresh one,
# or one running only DaemonSets on the host network) proves nothing and is left out too. Listed only when
# some node needs it - on the other clusters every node has its ranges.
if grep -qE '^[^ ]+ *$' <<<"$node_cidrs"; then
  pod_ips="$(k get pods -A -o json | jq -r '
    [.items[] | select(.spec.hostNetwork != true and .spec.nodeName != null and ((.status.podIPs // []) | length) > 0)
     | {node: .spec.nodeName, ips: [.status.podIPs[].ip]}
     | .both = ((.ips | any(test(":"))) and (.ips | any(test(":") | not)))]
    | group_by(.node)[] | (map(select(.both | not)) + map(select(.both)))[0] | "\(.node) \(.ips | join(" "))"')" || pod_ips=""
  node_cidrs="$(while read -r name cidrs; do
    [ -z "$name" ] && continue
    [ -z "$cidrs" ] && { cidrs="$(awk -v n="$name" '$1 == n { $1 = ""; print }' <<<"$pod_ips")"; [ -z "${cidrs// /}" ] && continue; }
    echo "$name $cidrs"
  done <<<"$node_cidrs")"
fi
single_nodes="$(nodes_not "yes yes")"
svc_ips="$(k -n "$NS" get service server -o jsonpath='{.spec.clusterIPs[*]}' 2>/dev/null)" || svc_ips=""
dual=false
[ -n "$node_cidrs" ] && [ -z "$single_nodes" ] && [ "$(families_of "$svc_ips")" = "yes yes" ] && dual=true
# The promise: cluster-config ip_stack, written by the module's Terraform ("dual" where the provider has
# IPv6 by default, "ipv4" where it has not). A dual-stack promise makes C2 and C5 test both families even
# when IPv6 is gone - they fail then too, not only C13. An unreadable ConfigMap is not "no promise".
# stderr apart from the JSON: a kubectl warning must not break the parse (or end the run).
ip_stack_note="" ip_stack="" errf="$(mktemp)"
if cluster_config="$(k -n flux-system get configmap cluster-config -o json 2>"$errf")"; then
  ip_stack="$(jq -r '.data.ip_stack // ""' <<<"$cluster_config" 2>/dev/null)" || ip_stack_note="flux-system/cluster-config is not JSON"
else
  cluster_config="{}"; ip_stack_note="could not read flux-system/cluster-config: $(head -c 150 "$errf")"
fi
rm -f "$errf"
want_dual="$dual"
case "$ip_stack" in dual) want_dual=true ;; ipv4) want_dual=false ;; esac
families=4; [ "$want_dual" = true ] && families="4 6"

# C2 - NetworkPolicies are enforced, egress included. Four probes from a pod labelled app=client:
# open with no policy; blocked by the platform's own default-deny-all (+ DNS); still blocked once the
# server admits the client (only egress is left closed - proves egress is enforced); open once the
# client may also send. A CNI that ignores policies passes the first probe and fails the second.
np="$ROOT/flux/infrastructure/network-policies/base"
if [ "$server_ready" = false ]; then
  fail C2 "the test server pod was not Ready within 2 min - no probe possible"
else
  r1=""; for f in $families; do r1+="$(probe open -l app=client "-$f" server 8080) "; done
  k -n "$NS" apply -f "$np/default-deny-all.yaml" -f "$np/allow-dns-egress.yaml" >/dev/null
  r2=""; for f in $families; do r2+="$(probe blocked -l app=client "-$f" server 8080) "; done
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
  r3=""; for f in $families; do r3+="$(probe blocked -l app=client "-$f" server 8080) "; done
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
  r4=""; for f in $families; do r4+="$(probe open -l app=client "-$f" server 8080) "; done
  # One verdict per family in each step; every family must give the same answer.
  want=""; for step in open blocked blocked open; do for f in $families; do want+="$step "; done; done
  fams="IPv${families// /, IPv}"
  if [ "$r1$r2$r3$r4" = "$want" ]; then
    pass C2 "NetworkPolicies enforced ($fams): no policy open, default-deny blocked, ingress-only blocked (egress enforced), both allowed open"
  else
    fail C2 "NetworkPolicies ($fams) - expected open/blocked/blocked/open per family, got ${r1% }/${r2% }/${r3% }/${r4% }"
  fi
fi

# C3 - a pod reaches the API server through the platform's own egress rule (the one CloudNativePG
# needs), and only through it. Default-deny is in place, so first a control probe without the rule's
# label: some CNIs never apply policies to the API server (on kind it lives in the node's host
# network - NetworkPolicy leaves that undefined), and then the rule is not exercised at all - SKIP,
# not a pass. Where the control is blocked, the labelled probe must get through: the rule allows TCP
# 6443 (kind, k3s), 443 (managed clouds) and cluster-config api_server_port (SKS: a port of Exoscale's own,
# read by the module's Terraform); a provider whose API server listens elsewhere fails here.
# The rule is applied as Flux applies it: ${api_server_port:=443} substituted from cluster-config, 443
# where the key is missing (Flux's default).
# busybox's nslookup ignores search domains for a dotted name - hence the full name.
api=kubernetes.default.svc.cluster.local
api_server_port="$(jq -r '.data.api_server_port // "443"' <<<"$cluster_config" 2>/dev/null)" || api_server_port=443
sed "s/\${api_server_port:=443}/${api_server_port}/" "$np/allow-postgres-egress-apiserver.yaml" | k -n "$NS" apply -f - >/dev/null
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
        # Up to 4 minutes: Azure Disk took 156 s on AKS (2026-10-21) - the disk itself first, then the file system.
        grown=""
        for _ in $(seq 1 48); do
          grown="$(k -n "$NS" get pvc disk -o jsonpath='{.status.capacity.storage}')" || grown=""
          [ "$grown" = "$bigger" ] && break
          sleep 5
        done
        if [ "$grown" = "$bigger" ]; then pass C4 "disk expanded online to $bigger"; else fail C4 "disk not expanded to $bigger within 4 min (capacity $grown)"; fi
      fi
    else
      skip C4 "expansion - StorageClass ${sc% *} does not allow it (the platform never resizes a disk)"
    fi
  else
    fail C4 "default StorageClass ${sc% *}: the disk was not bound or not writable within 3 min ($(k -n "$NS" get pvc disk -o jsonpath='{.status.phase}'))"
  fi
fi

# lb_hostnames ADDRS - the load balancer entries that are names, not IP addresses (one per line).
lb_hostnames() { tr ' ' '\n' <<<"$1" | grep -v ':' | grep '[a-zA-Z]' || true; }

# C5 - the ingress gets an address: Traefik's Service (Flux) has one from the provider's load balancer.
# No new load balancer is created - it would cost money and could outlive the run.
svc="$(k -n traefik get service traefik -o json 2>/dev/null || echo '{}')"
case "$(jq -r '.spec.type // "missing"' <<<"$svc")" in
  LoadBalancer)
    addrs="$(jq -r '[.status.loadBalancer.ingress[]? | .ip // .hostname] | join(" ")' <<<"$svc")"
    if [ -z "$addrs" ]; then
      fail C5 "Traefik's Service has no load balancer address"
    elif [ "$want_dual" = true ] && [ -n "$(lb_hostnames "$addrs")" ]; then
      # A hostname (AWS NLB): each one must resolve to an IPv4 and an IPv6 address.
      if ! command -v dig >/dev/null 2>&1; then
        skip C5 "load balancer for the ingress: $addrs - a hostname, dig not found to check its A and AAAA records"
      else
        missing=""
        for h in $(lb_hostnames "$addrs"); do
          [ -n "$(dig +short A "$h" | grep -E '^[0-9.]+$' || true)" ] || missing+=" $h (A)"
          [ -n "$(dig +short AAAA "$h" | grep ':' || true)" ] || missing+=" $h (AAAA)"
        done
        if [ -z "$missing" ]; then
          pass C5 "load balancer for the ingress: $addrs (A and AAAA records)"
        else
          fail C5 "load balancer for the ingress - the cluster is dual-stack, records missing:$missing"
        fi
      fi
    elif [ "$want_dual" = true ] && [ "$(families_of "$addrs")" != "yes yes" ]; then
      fail C5 "load balancer for the ingress has one family only ($addrs) - the cluster is dual-stack, the ingress must be too"
    else
      pass C5 "load balancer for the ingress: $addrs"
    fi ;;
  NodePort) skip C5 "kind: Traefik is a NodePort (localhost:8080/8443), no load balancer by design" ;;
  *) fail C5 "no Service traefik/traefik - the ingress is missing" ;;
esac

# C5 - the DNS records of the ingress have an owner of this provider: external-dns's owner ID is
# k8s-external-dns-<cluster_name>-<cloud_provider> (cluster-config). Flux leaves a missing key empty
# without an error - an ID ending in "-" would share records with any other cluster missing it.
owner="$(k -n external-dns get deployment external-dns -o json 2>/dev/null | jq -r '.spec.template.spec.containers[0].args[]? | select(startswith("--txt-owner-id=")) | sub("^--txt-owner-id="; "")')" || owner=""
if ! k -n external-dns get deployment external-dns >/dev/null 2>&1; then
  skip C5 "DNS owner - no external-dns on this cluster"
elif [ -z "$owner" ] || [ "${owner%-}" != "$owner" ]; then
  fail C5 "DNS owner '${owner}' - cluster-config needs cloud_provider (the module's Terraform writes it)"
else
  pass C5 "DNS records owned by $owner"
fi

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
registry="$(jq -r '.data.image_registry // ""' <<<"$cluster_config" 2>/dev/null || true)"
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
skip C12 "teardown leftovers - after destroy: the provider's check (Hetzner: scripts/hcloud-leftovers.sh, GKE: make -C infra/terraform/gke_cluster leftovers, EKS: make -C infra/terraform/eks_cluster leftovers, AKS: make -C infra/terraform/aks_cluster leftovers, DOKS: make -C infra/terraform/doks_cluster leftovers, SKS: make -C infra/terraform/sks_cluster leftovers; kind: nothing billed)"

# C13 - the address families the provider promises: cluster-config ip_stack, written by the module's
# Terraform. "dual": IPv4 and IPv6 for every node's pods and for Services (decided before C2) - a provider
# with IPv6 by default never loses it quietly. "ipv4": a provider without it (docs/providers.md); a
# cluster that is dual-stack after all fails too, so the promise in Git stays true.
# On "ipv4" a node must not have an IPv6 pod range; one without pod ranges is fine - a CNI that hands out
# pod addresses itself (EKS's VPC CNI) leaves spec.podCIDRs empty.
v6_nodes="$(while read -r name cidrs; do case "$cidrs" in *:*) echo "$name" ;; esac; done <<<"$node_cidrs")"
# The apps' and Traefik's Services take their policy from cluster-config service_ip_family_policy
# (RequireDualStack unless a module sets it): on a dual-stack cluster none may ask for less, or IPv6 goes
# missing without an error.
svcs_read=true
weak_svcs="$(k get services -A -o json | jq -r '.items[] | select(((.metadata.namespace | test("^(develop|staging|production)$")) and (.metadata.name == "frontend" or .metadata.name == "backend")) or (.metadata.namespace == "traefik" and .metadata.name == "traefik")) | select(.spec.ipFamilyPolicy != "RequireDualStack") | "\(.metadata.namespace)/\(.metadata.name)"')" || svcs_read=false
if [ -n "$ip_stack_note" ]; then
  fail C13 "address families - $ip_stack_note"
elif [ "$ip_stack" = ipv4 ]; then
  if [ "$dual" = true ]; then
    fail C13 "cluster-config says ip_stack ipv4, but the cluster is dual-stack (a Service gets $svc_ips) - set ip_stack dual"
  elif [ -z "$node_cidrs" ]; then
    fail C13 "IPv4 only - could not read the nodes"
  elif [ -n "$v6_nodes" ]; then
    fail C13 "cluster-config says ip_stack ipv4, but these nodes have an IPv6 pod range: $(tr '\n' ' ' <<<"$v6_nodes")"
  elif [ "$(families_of "$svc_ips")" = "yes no" ]; then
    pass C13 "IPv4 only, as cluster-config ip_stack promises (the provider has no IPv6 by default); a Service gets $svc_ips"
  else
    fail C13 "cluster-config says ip_stack ipv4, but a Service got ${svc_ips:-no address}"
  fi
elif [ -z "$ip_stack" ]; then
  fail C13 "cluster-config has no ip_stack - the module's Terraform writes it (a cluster from before it: terraform apply once)"
elif [ "$ip_stack" != dual ]; then
  fail C13 "cluster-config ip_stack '${ip_stack}' is not supported - dual or ipv4"
elif [ "$dual" = true ] && [ "$svcs_read" = false ]; then
  fail C13 "dual-stack - could not read the Services to check their family policy"
elif [ "$dual" = true ] && [ -n "$weak_svcs" ]; then
  fail C13 "dual-stack, but these Services do not require both families: $(tr '\n' ' ' <<<"$weak_svcs")- cluster-config service_ip_family_policy is only for ip_stack ipv4"
elif [ "$dual" = true ]; then
  pass C13 "dual-stack: every node has IPv4 and IPv6 pod addresses; a Service gets $svc_ips"
elif [ -z "$node_cidrs" ]; then
  fail C13 "dual-stack - could not read the nodes' pod ranges"
elif [ -n "$single_nodes" ]; then
  fail C13 "not dual-stack: nodes without a pod range of each family: $(tr '\n' ' ' <<<"$single_nodes")"
else
  fail C13 "not dual-stack: a PreferDualStack Service got ${svc_ips:-no address} - one family only"
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "Contract kept on $CONTEXT"; else echo "$FAILS item(s) FAIL on $CONTEXT"; fi
[ "$FAILS" -eq 0 ]
