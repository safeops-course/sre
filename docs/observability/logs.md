# Logs - what is collected, and where it goes

Two OpenTelemetry collectors send the cluster's logs to Uptrace (the project the DSN names), on every
cloud cluster - the component `flux/bootstrap/components/opentelemetry` is in each cloud profile. kind runs
neither: its logs stay on the nodes (`kubectl logs`).

| Collector | Where | Reads |
|---|---|---|
| `otel-collector` (DaemonSet, one per node) | `flux/infrastructure/observability/opentelemetry-collector/release.yaml` | stdout/stderr of every container on its node (`/var/log/pods`), every namespace, `kube-system` included; also traces and metrics the apps send over OTLP, and kubelet metrics |
| `otel-events` (Deployment, one replica) | `.../release-events.yaml` | Kubernetes Events of the whole cluster: reason, Normal/Warning, the object, how many times |

Each record carries the cluster (`k8s.cluster.name`), and the pod logs their namespace, pod, container and node.

## Not collected

| Source | Why | Where to look instead |
|---|---|---|
| Services outside pods: kubelet, containerd, and on k3s the control plane (API server, scheduler, controller manager, etcd run inside the `k3s` service) | They write to journald, not to `/var/log/pods`. Reading journald needs a collector running as root with the node's root filesystem mounted - not taken on yet | `journalctl -u k3s` / `-u kubelet` on the node |
| The control plane of a managed cluster (GKE, EKS) | It runs at the provider, not on our nodes | The provider's logging (Cloud Logging on GKE) |
| The API server's audit log (who changed what) | Not turned on | - |

On kind the control plane runs as static pods, so its logs are among the pod logs.

## Not lost

- **Restarts:** the DaemonSet keeps each file's read position on the node (`storeCheckpoints`), so a restarted
  collector goes on where it stopped instead of skipping what was written meanwhile.
- **Uptrace unreachable:** each collector queues batches and retries without end; a full queue drops the
  newest batches - the collector's log says so.
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
