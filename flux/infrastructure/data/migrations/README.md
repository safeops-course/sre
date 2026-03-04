# Database Migrations — Expand/Contract Workflow

## Strategy

All schema migrations follow the **expand/contract** pattern to maintain
rollback safety at every step.

```
Expand (additive DDL)
  → Deploy app with feature flag OFF
  → Enable flag gradually, monitor SLO
  → Rollback window (flag OFF reverts behavior)
  → Contract (destructive DDL) only after explicit approval
```

## Migration Files

| File | Phase | Reversible | Notes |
|---|---|---|---|
| `001-expand-add-login-v2-column.sql` | Expand | Yes (DROP COLUMN) | Adds new column, old app unaffected |
| `002-contract-drop-old-column.sql` | Contract | **No** (backup restore) | Removes old column after full cutover |

## Execution

Migrations are run manually via `kubectl exec` + `psql` — not automated Jobs.
This is intentional: schema changes require human review and explicit approval.

```bash
# Connect to the CNPG primary in develop
kubectl exec -it app-postgres-1 -n develop -- \
  psql -U app -d app -f -

# Then paste or pipe the migration SQL
```

## Rollback Rules

1. **During expand phase:** DROP the new column to revert. App continues on old column.
2. **After contract phase:** Rollback requires point-in-time restore from CNPG backup.
3. **Never run contract without:** verified backup, stable SLO window, explicit approval.

## Feature Flag Integration

The application reads `FEATURE_LOGIN_V2` from the feature-flags ConfigMap.
When `false`, the app uses the old `login_method` column.
When `true`, the app uses `login_method_v2`.

See: `flux/apps/backend/develop/patches/feature-flags.yaml`
