#!/usr/bin/env bash
# lab-pod.sh - run a one-off or long-lived test pod that the environment
# namespaces accept.
#
# develop/staging/production enforce Pod Security "restricted", so a plain
# `kubectl run busybox` is rejected before it starts. This wrapper adds the
# required securityContext, waits for the pod, prints its logs and returns its
# exit code - the labs use it instead of hand-written overrides.
#
# Usage:
#   scripts/lab-pod.sh -n <namespace> [-i <image>] [-l key=value]... [-u <uid>] -- <command...>
#   scripts/lab-pod.sh -n <namespace> [-i <image>] [-l key=value]... --daemon [<name>]
#
# Examples:
#   # probe the backend the way the frontend does (app=frontend passes the NetworkPolicies)
#   scripts/lab-pod.sh -n develop -i curlimages/curl -l app=frontend -- curl -sf -m 5 http://backend/healthz
#   # long-lived debug pod, then: kubectl -n develop exec np-debug -- nc -w 2 backend 80
#   scripts/lab-pod.sh -n develop --daemon np-debug
#
# Defaults: image busybox:1.36, uid 65532, read-only root filesystem with a
# writable /tmp. Pods are deleted after a one-off run; --daemon pods stay until
# you delete them.
set -euo pipefail

NAMESPACE=""
IMAGE="busybox:1.36"
UID_NUM="65532"
LABELS=()
DAEMON=0
NAME=""
TIMEOUT="${LAB_POD_TIMEOUT:-120}"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n) NAMESPACE="$2"; shift 2 ;;
    -i) IMAGE="$2"; shift 2 ;;
    -l) LABELS+=("$2"); shift 2 ;;
    -u) UID_NUM="$2"; shift 2 ;;
    --daemon) DAEMON=1; shift; if [ $# -gt 0 ] && [ "$1" != "--" ]; then NAME="$1"; shift; fi ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done
[ -n "$NAMESPACE" ] || { echo "-n <namespace> is required" >&2; usage; }

if [ "$DAEMON" -eq 1 ]; then
  [ -n "$NAME" ] || NAME="lab-debug"
  CMD_JSON='["sh","-c","sleep infinity"]'
else
  [ $# -gt 0 ] || { echo "command after -- is required (or use --daemon)" >&2; usage; }
  NAME="lab-$(date +%s)-$RANDOM"
  CMD_JSON="$(printf '%s\n' "$@" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split("\n")[:-1]))')"
fi

LABEL_JSON="{}"
if [ ${#LABELS[@]} -gt 0 ]; then
  LABEL_JSON="$(printf '%s\n' "${LABELS[@]}" | python3 -c 'import json,sys; print(json.dumps(dict(l.split("=",1) for l in sys.stdin.read().split("\n") if l)))')"
fi

OVERRIDES="$(cat <<JSON
{
  "metadata": {"labels": ${LABEL_JSON}},
  "spec": {
    "restartPolicy": "Never",
    "securityContext": {
      "runAsNonRoot": true,
      "runAsUser": ${UID_NUM},
      "runAsGroup": ${UID_NUM},
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "containers": [{
      "name": "${NAME}",
      "image": "${IMAGE}",
      "command": ${CMD_JSON},
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "readOnlyRootFilesystem": true,
        "capabilities": {"drop": ["ALL"]}
      },
      "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}]
    }],
    "volumes": [{"name": "tmp", "emptyDir": {}}]
  }
}
JSON
)"

kubectl -n "$NAMESPACE" run "$NAME" --image="$IMAGE" --restart=Never --overrides="$OVERRIDES" >/dev/null

if [ "$DAEMON" -eq 1 ]; then
  kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$NAME" --timeout="${TIMEOUT}s" >/dev/null
  echo "$NAME"
  exit 0
fi

phase=""
for _ in $(seq 1 "$TIMEOUT"); do
  phase="$(kubectl -n "$NAMESPACE" get pod "$NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Succeeded|Failed) break ;; esac
  sleep 1
done

kubectl -n "$NAMESPACE" logs "$NAME" 2>/dev/null || true
exit_code="$(kubectl -n "$NAMESPACE" get pod "$NAME" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo 1)"
kubectl -n "$NAMESPACE" delete pod "$NAME" --wait=false >/dev/null 2>&1 || true

if [ "$phase" != "Succeeded" ] && [ "$phase" != "Failed" ]; then
  echo "lab-pod: timed out after ${TIMEOUT}s (phase=${phase:-unknown})" >&2
  exit 124
fi
exit "${exit_code:-1}"
