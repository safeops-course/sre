# Logs - what is collected, and where it goes

Two OpenTelemetry collectors send the cluster's logs to Uptrace (the project the DSN names). They run on
every cluster - the component `flux/bootstrap/components/opentelemetry` is in every profile. On kind they
read the same and send to their own log instead (the debug exporter prints how many records each batch
held), so what is collected can be checked there for free:

```bash
kubectl --context kind-sre-control-plane -n observability logs -l app.kubernetes.io/name=opentelemetry-collector --tail=20
```

| Collector | Where | Reads |
|---|---|---|
| `otel-collector` (DaemonSet, one per node) | `flux/infrastructure/observability/opentelemetry-collector/release.yaml` | stdout/stderr of every container on its node (`/var/log/pods`), every namespace, `kube-system` included; also traces and metrics the apps send over OTLP, and kubelet metrics |
| `otel-events` (Deployment, one replica) | `.../release-events.yaml` | Kubernetes Events of the whole cluster: reason, Normal/Warning, the object, how many times |

Each record carries the cluster (`k8s.cluster.name`), and the pod logs their namespace, pod, container and node.
The DaemonSet skips its own log but reads `otel-events`' - like any other pod's.

## Not collected

| Source | Why | Where to look instead |
|---|---|---|
| Services outside pods: kubelet, containerd, and on k3s the control plane (API server, scheduler, controller manager, etcd run inside the `k3s` service) | They write to journald, not to `/var/log/pods`. Reading journald needs a collector running as root with the node's root filesystem mounted - not taken on yet | `journalctl -u k3s` / `-u kubelet` on the node |
| The control plane of a managed cluster (GKE, EKS) | It runs at the provider, not on our nodes | The provider's logging (Cloud Logging on GKE) |
| The API server's audit log (who changed what) | On k3s it is written on each control plane node (`k3s_audit_log`, rules in `infra/terraform/hcloud_cluster/audit-policy.yaml`: every change, every Secret access, exec and port-forward; no request bodies), but not shipped yet. A managed cluster has the provider's own (always on for GKE, turned on per cluster for EKS) | k3s: `/var/log/k3s-audit/audit.log` on the node; a managed cluster: the provider's logging |

On kind the control plane runs as static pods, so its logs are among the pod logs; on k3s it does not.

## What survives, and what does not

- **A restart of the DaemonSet:** it keeps each file's read position and the batches waiting for Uptrace on
  the node (`storeCheckpoints`, and `sending_queue.storage`), so it goes on where it stopped. Lost: files
  it has never seen - a pod started and gone, or a log rotated, while it was down - are most likely read
  from their end (`start_at: end`; not tested). The events collector keeps nothing on disk: Events of the minutes it is down are not sent.
- **Uptrace unreachable:** each collector queues batches and retries without end; a full queue refuses new
  batches - the collector's log says so.
- **A wrong DSN:** Uptrace refuses it, the refusal is not retried, and the log says `Exporting failed.
  Dropping data.` (seen on kind with a fake DSN).
- **No DSN:** the Terraform plan fails (`uptrace_dsn` is required) - a collector without one would drop
  everything it reads.

## Provider logging

The collectors are the same on every provider. A provider's own logging comes on top:

| Provider | Its own logging | In our test cycles |
|---|---|---|
| GKE | Cloud Logging: system components (GKE's agents, kube-system) and workloads (`logging_components`, both by default) | system components only (`terraform.tfvars`) - workload logs are in Uptrace |
| Hetzner | none | - |

The test cycles turn a billed copy off to save money while the course is built; a cluster that matters
keeps the defaults.

## Check it

```bash
# both collectors run, and their logs show no export errors
kubectl -n observability get pods -l app.kubernetes.io/name=opentelemetry-collector
kubectl -n observability logs -l app.kubernetes.io/name=opentelemetry-collector --tail=100 | grep -i -E 'error|dropp'
```

In Uptrace, under Logs, filter by `k8s.cluster.name`: pod logs (with `k8s.namespace.name`) and Events (with
`k8s.event.reason`) both have to be there.
