#!/usr/bin/env bash
# np-probe.sh - is a connection allowed? Answers the two questions separately: does the name
# resolve (DNS), and does a TCP connection to the port open?
#
# "nc ... && echo OPEN || echo BLOCKED" mixes them up: a name that does not resolve, a Service
# without endpoints and a NetworkPolicy all print BLOCKED. This probe prints both answers, so a
# blocked connection with working DNS points at the rules - and a failing DNS lookup does not.
#
# Usage: scripts/np-probe.sh -n <namespace> [-c <context>] [-l key=value]... [-4|-6] <host> <port>
#   -n  the namespace the probe pod runs in (its NetworkPolicies apply to it)
#   -l  labels of the probe pod - the "identity" NetworkPolicies select (repeatable)
#   -c  the cluster: -c, else $KUBE_CONTEXT, else kind-sre-control-plane
#   -4|-6  one family only: the A (IPv4) or AAAA (IPv6) address, and TCP to that address - a dual-stack
#          cluster can allow one family and block the other. Without it: the first address the name gives
# Example: scripts/np-probe.sh -n develop -l app=frontend backend 80
#
# Output, one line: "DNS ok (10.96.1.73), TCP open" | "DNS ok (...), TCP blocked" | "DNS FAILED".
# Exit code: 0 TCP open, 1 TCP blocked, 2 DNS failed, 3 usage error, 4 no verdict (the probe pod
# did not run - its output is printed).
# Runs a one-off pod through scripts/lab-pod.sh (Pod Security restricted, deleted afterwards).
# Changes nothing else. Needs kubectl and jq (for lab-pod.sh). Chapter 06.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=""
CONTEXT="${KUBE_CONTEXT:-kind-sre-control-plane}"
LABEL_ARGS=()
FAMILY=""

# usage - print the header comment (lines 2-21) as help, then exit 3.
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    # An option without its value is a usage error (exit 3), never a probe with an empty argument.
    -n) [ $# -ge 2 ] || usage; NAMESPACE="$2"; shift 2 ;;
    -c) [ $# -ge 2 ] || usage; CONTEXT="$2"; shift 2 ;;
    -l) [ $# -ge 2 ] || usage; LABEL_ARGS+=(-l "$2"); shift 2 ;;
    -4|-6) FAMILY="${1#-}"; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done
[ -n "${NAMESPACE}" ] && [ $# -eq 2 ] || usage
HOST="$1"
PORT="$2"
# A port is a number from 1 to 65535 - anything else would fail inside the pod and read as "TCP blocked".
# Digits only, at most 5 of them - checked before the numeric test, which would fail (and count as
# false) on a number too large for the shell.
case "${PORT}" in
  ''|*[!0-9]*) echo "np-probe: invalid port '${PORT}'" >&2; usage ;;
esac
if [ "${#PORT}" -gt 5 ] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
  echo "np-probe: invalid port '${PORT}'" >&2; usage
fi

# Inside the pod (busybox): resolve first and stop there if it fails; then try TCP to the port. With
# a family ($2 = 4 or 6) the lookup asks for that record type only and nc connects to the address
# itself, so the verdict is about that family. The exit code carries the answer out of the pod -
# lab-pod.sh returns the command's own.
# shellcheck disable=SC2016  # expanded by the shell inside the pod
PROBE='
case "$2" in 4) type="-type=a" ;; 6) type="-type=aaaa" ;; *) type="" ;; esac
ip="$(nslookup $type "$0" 2>/dev/null | awk "/^Name:/ {n=1} n && /^Address/ {print \$2; exit}")"
if [ -z "$ip" ]; then echo "DNS FAILED"; exit 2; fi
target="$0"; [ -n "$2" ] && target="$ip"
if nc -z -w 3 "$target" "$1" 2>/dev/null; then echo "DNS ok ($ip), TCP open"; exit 0; fi
echo "DNS ok ($ip), TCP blocked"; exit 1
'

rc=0
out="$("${SCRIPT_DIR}/lab-pod.sh" -c "${CONTEXT}" -n "${NAMESPACE}" ${LABEL_ARGS[@]+"${LABEL_ARGS[@]}"} \
  -- sh -c "${PROBE}" "${HOST}" "${PORT}" "${FAMILY}" 2>&1)" || rc=$?
# lab-pod.sh prints the pod's log; the probe's verdict is its last line. Exit 0/1/2 only with a
# verdict that matches it - anything else (the pod did not start, an image pull failed, a timeout)
# is an error of its own (4), shown in full, never read as "TCP blocked".
verdict="$(printf '%s\n' "${out}" | tail -1)"
case "${rc}:${verdict}" in
  "0:DNS ok ("*"), TCP open" | "1:DNS ok ("*"), TCP blocked" | "2:DNS FAILED")
    echo "${verdict}"
    exit "${rc}"
    ;;
esac
echo "np-probe: no verdict from the probe pod (exit ${rc}):" >&2
printf '%s\n' "${out}" >&2
exit 4
