# CNPG clusters (app-postgres per environment)

One CloudNativePG cluster per environment (`develop`, `staging`, `production`), named `app-postgres`,
database and owner `app`, credentials in the Secret `app-postgres-app`.

- **Flux never prunes them:** `kustomize.toolkit.fluxcd.io/prune: disabled` on each Cluster. A database
  that leaves Git - a moved folder, a profile that no longer includes it, a bad revert - stays with its
  data; deleting one on purpose is a `kubectl delete`.

## Backups

- **Continuous WAL archiving and a daily base backup** (`scheduled-backup.yaml`), through the Barman
  Cloud plugin (`cnpg-operator/plugin-barman-cloud.yaml`) to the ObjectStore `app-postgres-backups`
  (`object-store.yaml`): `s3://${BACKUP_S3_BUCKET}/cnpg-backups/<namespace>/app-postgres`.
  Retention: 7 days in develop, 14 in staging, 30 in production (the ObjectStore's `retentionPolicy`).
  The plugin runs as a sidecar in the database pod; its resources are in the ObjectStore.
- **Where:** MinIO inside the cluster on kind (bucket `sre`), its data in a directory on the laptop
  (`infra/terraform/kind_cluster/.minio-data`) - it survives `make kind-destroy`, not the loss of the
  laptop; Hetzner Object Storage on the platform. The endpoint and bucket come from Terraform
  (ConfigMap substitution); the keys from the Secret `cnpg-backup-s3`.
- **One archive per cluster:** the server name is `app-postgres-pg18-<BACKUP_CLUSTER_ID>`, the day
  and time Terraform created the Kubernetes cluster. A rebuilt cluster writes a new archive - the
  plugin refuses a used one ("Expected empty archive": the database runs, without backups) - and the
  old one stays for a restore (Chapter 22). Retention prunes only the live cluster's archive; old
  ones are deleted by hand once no longer needed.
- **Moved from the in-tree `barmanObjectStore`** (deprecated since CNPG 1.26, removed in 1.31) with the
  same path and server name, so the backups taken before the move still restore.
- **Watched by** `PostgresWALArchivingFailing`, `PostgresBackupFailed`, `PostgresBackupTooOld` and
  `PostgresNeverBackedUp`
  (`observability/kube-prometheus-stack/monitoring/backup-alerts.yaml`).

## Restore

A restore is a **new cluster next to the old one**, never an overwrite: `app-postgres-restore` in the
same namespace, bootstrapped from the base backup and the archived WAL - to the end of the archive,
or to a point in time before a bad change.

```bash
scripts/postgres-restore-manifest.sh -c kind-sre-control-plane -n develop -t 2026-10-05T09:30:00Z \
  | kubectl --context kind-sre-control-plane apply -f -
```

- The name `app-postgres-restore` is fixed: the NetworkPolicies (`network-policies/base`,
  `data/minio/network-policies.yaml`) allow it the same paths as `app-postgres` - the backup store, the
  API server, the operator, the backend. A restore under any other name hangs on a dropped connection.
- The script copies the image, storage and resources from the source and keeps the app's
  credentials, so the restored database can be checked with the application's own user.
- Proof of a restore is data, not `Ready`: the expected rows, read and written with the app user.
- Delete the restore cluster when done:
  `kubectl --context kind-sre-control-plane -n develop delete cluster.postgresql.cnpg.io app-postgres-restore`.
