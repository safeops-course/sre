# Credentials: Rotation Runbooks

How to replace each credential in [`credential-registry.yaml`](credential-registry.yaml) - the registry of what exists,
where every copy lives and when it was last replaced. `scripts/check-credentials.sh` fails two weeks
before a rotation is due (tokens every 90 days, keys every 180), and every day on `main` until it is
done (`.github/workflows/credential-rotation.yml`). Chapter 21 explains the why.

Values are never pasted into a terminal command, a chat, an issue or a pull request: they go from the
provider's page into the place that stores them (`gh secret set` reads stdin, `sops edit` opens an
editor).

## Every Rotation

1. **Create the new value next to the old one** where the provider allows two (GitHub OAuth Apps, R2
   and Hetzner tokens, deploy keys). Where it does not (a Cloudflare token roll, a generated secret),
   plan the short gap.
2. **Update every place in `lives_in`.** A copy left behind keeps the old value alive - or breaks the
   first time it is used.
3. **Make the readers pick it up.** A changed Secret restarts nothing: pods that read it as environment
   variables keep the old value until they restart - through Git, see
   [Restarting the Readers](#restarting-the-readers).
4. **Verify with the new value** - the check named in the section below.
5. **Revoke the old value** at the provider. Until then the rotation has changed nothing for whoever
   holds the old one.
6. **Set `rotated`** in `docs/credential-registry.yaml` to today, in the same pull request as any SOPS change.

After a leak, do all of it at once, starting with the revocation if the holder could act on it now -
and treat every value the leaked credential could read as leaked too (the age key opens every SOPS
file in the history: `flux/secrets/README.md#key-rotation`).

## Restarting the Readers

A workload Flux manages is restarted by a change in Git: the annotation `safeops.io/secrets-rotated`
on its pod template, set to the current UTC time (`date -u +%FT%TZ`) in the same pull request as the
Secret. A timestamp, not a day: two rotations on one day must still change the template. The template
changes, and Flux rolls the pods like any release - a new pod Ready before an old one goes.

| Reader | Where the annotation lives |
|---|---|
| backend | `flux/apps/backend/<env>/kustomization.yaml` - the `secrets-rotated` patch |
| frontend | `flux/apps/frontend/overlays/<env>/patches/deployment.yaml` |
| k8s-ai-monitor | `flux/infrastructure/observability/k8s-ai-monitor/deployment.yaml` |
| Dex, Headlamp, external-dns | the HelmRelease's `spec.values.podAnnotations` |
| OpenTelemetry collectors | nothing - the DSN is substituted into the HelmRelease, so a new one rolls them ([Third-Party URLs and DSNs](#third-party-urls-and-dsns)) |
| origin-ca-issuer | the HelmRelease's `spec.values.controller.podAnnotations` |

**Not `kubectl rollout restart`** on a Flux-managed Deployment. It sets an annotation that is not in
Git, and Flux removes it on its next reconcile. If that reconcile comes while the rollout is still
running, the new pods are scaled away and the old ones stay - with the old value, and nothing reports
it (seen on kind, 2026-10-11). Kubernetes objects Flux does not manage - the Hetzner cloud controller
and CSI driver in `kube-system` - are restarted with `kubectl rollout restart` as usual.

## Hetzner API Token

1. Hetzner Console → the SafeOps project → **Security → API tokens → Generate** (Read & Write).
2. `gh secret set HCLOUD_TOKEN --org safeops-course --visibility selected --repos sre` (paste at the
   prompt); the owner's context: `HCLOUD_CONFIG=~/sre/.local/hcloud-safeops.toml hcloud context create safeops`.
3. **A cluster is running:** apply Terraform (the workflow with *apply*). kube-hetzner re-applies the
   Secrets `kube-system/hcloud` and `hcloud-csi` when the token changes; then restart what reads them
   (kube-hetzner deploys them, not Flux): `kubectl -n kube-system get deploy,ds | grep hcloud` and
   `kubectl -n kube-system rollout restart` each.
   **No cluster:** nothing else - the next one is created with the new token.
4. Verify: `hcloud server list` works; on a running cluster the cloud controller logs no `401`.
5. Delete the old token in the console.

## Node SSH Key

1. `ssh-keygen -t ed25519 -N '' -C safeops-hetzner -f ~/.ssh/safeops-hetzner-new`
2. `gh secret set HCLOUD_SSH_PRIVATE_KEY --org safeops-course --visibility selected --repos sre < ~/.ssh/safeops-hetzner-new`
   and `gh variable set HCLOUD_SSH_PUBLIC_KEY --org safeops-course --visibility selected --repos sre < ~/.ssh/safeops-hetzner-new.pub`.
3. Rotate **between cycles** (no cluster running): the key is written into the nodes when they are
   created. On a cluster you keep, read the plan first - if it replaces servers, wait for the next cycle.
4. Verify: the next apply provisions the nodes (kube-hetzner signs in with this key);
   `scripts/node-maintenance.sh` reaches a node.
5. Delete the old key pair from `~/.ssh` and the SSH key object in the Hetzner project.

## R2 and Backup Keys

The Terraform state keys (`R2_*`) and the backup keys (`BACKUP_S3_*`) are Cloudflare R2 API tokens,
each limited to its own bucket.

1. Cloudflare → **R2 → Manage API tokens → Create** - *Object Read & Write*, only that bucket.
2. `gh secret set` both halves (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` or the `BACKUP_S3_` pair)
   for the organization, visible to `sre` only; the state keys also in the owner's `.env.local`.
3. Backup keys on a running cluster: apply Terraform - it rewrites the Secret `cnpg-backup-s3` in each
   environment.
4. Verify: state keys - the Terraform workflow's plan job runs `init` and `plan`; backup keys - the next
   scheduled backup completes (`kubectl -n develop get backups`, the newest `completed`).
5. Delete the old token in Cloudflare.

## Tfplan Passphrase

1. `openssl rand -base64 32 | gh secret set TFPLAN_PASSPHRASE --org safeops-course --visibility selected --repos sre`
   - the value never reaches the screen.
2. Verify: the next Terraform run encrypts and decrypts the plan. Plans already uploaded with the old
   passphrase cannot be applied any more - they are kept one day anyway.

## Course Repo PAT

1. GitHub → Settings → Developer settings → **Fine-grained tokens → Generate**: resource owner
   `safeops-course`, only `sre-course`, *Contents* and *Pull requests* read and write, an expiry at
   most 90 days ahead.
2. `gh secret set COURSE_REPO_PAT --org safeops-course --visibility selected --repos sre`
3. Write the token's expiry date as `expires` in the registry.
4. Verify: Actions → *Sync course snippets* → Run workflow; it opens or updates its pull request.
5. Revoke the old token.

## Image Automation Deploy Key

1. `ssh-keygen -t ed25519 -N '' -C flux-image-automation -f /tmp/flux-deploy-key` (a throw-away path).
2. `gh repo deploy-key add /tmp/flux-deploy-key.pub -R safeops-course/sre --allow-write --title "flux image automation $(date +%F)"`
3. `sops edit flux/secrets/flux-system/image-automation-deploy-key.yaml`: `identity` = the private key,
   `known_hosts` = `ssh-keyscan github.com` (unchanged unless GitHub's keys changed).
4. Merge; verify: `flux get sources git -A` Ready, and the next image update pushes a commit.
5. `gh repo deploy-key list -R safeops-course/sre`, `gh repo deploy-key delete <old id>`; `rm /tmp/flux-deploy-key*`.

## Dex GitHub OAuth App

A GitHub OAuth App holds two client secrets at once, so this rotation has no gap.

1. Organization settings → Developer settings → OAuth Apps → *SafeOps Dex* → **Generate a new client secret**.
2. `sops edit flux/secrets/auth/dex-secrets.yaml` → `DEX_GITHUB_CLIENT_SECRET`; in the same pull
   request, the annotation in Dex's `podAnnotations` (it reads the Secret as environment variables).
3. Merge; Flux updates the Secret and rolls Dex.
4. Verify: `kubectl oidc-login` (or Headlamp) signs in through GitHub.
5. Delete the old secret in the OAuth App.

## Cloudflare Tokens

The DNS token (Zone → DNS: Edit, the zone only) and the Origin CA token (Zone → SSL and Certificates:
Edit). **Roll** in Cloudflare replaces the value and ends the old one at once; between the roll and
the merge, DNS changes and certificate requests fail and are retried.

1. Cloudflare → My Profile → **API Tokens** → the token → **Roll**.
2. `sops edit` `flux/secrets/cloudflare/external-dns-cloudflare-api-token.yaml` or
   `cloudflare-origin-ca-token.yaml` → `api-token`; in the same pull request, the annotation in the reader's
   pod annotations (external-dns: `podAnnotations`; origin-ca-issuer: `controller.podAnnotations`).
3. Merge; Flux updates the Secret and rolls the reader.
4. Verify: external-dns logs no `403`; `kubectl get certificates -A` all Ready.

## Generated Secrets

Secrets with no provider - the backend's JWT signing secret, the Headlamp client of Dex - are random
values we generate.

1. `sops edit` the file in `lives_in` and replace the value with the output of `openssl rand -base64 48`
   (generated inside the editor's buffer, or copied from a terminal you then clear).
2. In the same pull request, the annotation of the readers
   ([Restarting the Readers](#restarting-the-readers)): the backend of that environment, or for the
   Headlamp client both Dex and Headlamp. Merge.
3. **What it costs:** a new JWT secret signs everyone out - tokens signed with the old one are refused.
   Rotate all three environments, one at a time.
4. Verify: `kubectl -n <env> rollout status deployment/backend`, then sign in on that environment's
   site - a fresh login gets a token signed with the new secret.

## Database Passwords

The app role of each database is a CloudNativePG **managed role** whose password comes from the
Secret `app-postgres-app` (`spec.managed.roles[].passwordSecret`). When that Secret changes,
CloudNativePG sets the new password in PostgreSQL itself - `status.managedRolesStatus.passwordStatus`
records the Secret version it applied. Existing connections stay open; new ones need the new password.

**develop, staging** (SOPS):

1. `sops edit flux/secrets/<env>/cnpg-postgres-secret.yaml` → `password` (`openssl rand -base64 32 | tr -d '/+='`);
   in the same pull request, `safeops.io/secrets-rotated` in `flux/apps/backend/<env>/kustomization.yaml`.
2. Merge. The role follows within seconds (4 s on kind) - the Secret's version and the one the role
   applied are then equal:

   ```bash
   kubectl -n <env> get secret app-postgres-app -o jsonpath='{.metadata.resourceVersion}{"\n"}'
   kubectl -n <env> get cluster app-postgres -o jsonpath='{.status.managedRolesStatus.passwordStatus.app.resourceVersion}{"\n"}'
   ```

3. Flux rolls the backend - it reads the password at start. Until its new pods run, the old ones keep
   their open connections, but a new connection with the old password is refused.
4. Verify: `kubectl -n <env> rollout status deployment/backend` completes - every new pod's `migrate`
   init container signs in to the database before the backend starts, so a wrong password stops the
   rollout and the old pods keep serving.

**production** (Terraform, `class: cluster`): the password is a `random_password`, seeded once into the
Secret; Terraform then ignores the Secret's data, because CloudNativePG adds its own keys to it. A new
cluster gets a new password. On a cluster that lives on, Terraform cannot change it - replace the
password in the Secret itself, and the managed role follows:

```bash
printf '{"stringData":{"password":"%s"}}' "$(openssl rand -base64 32 | tr -d '/+=')" \
  | kubectl -n production patch secret app-postgres-app --type merge --patch-file /dev/stdin
```

The value goes through a pipe, not an argument: an argument is visible to every process on the machine
(`ps`) and may reach shell history or command telemetry. `printf` is a shell builtin - it runs no
process that could show it.

Then, at once, a pull request with a new `safeops.io/secrets-rotated` in `flux/apps/backend/production/kustomization.yaml`,
and steps 2-4 for `production`: between the patch and the rollout, new backend connections fail. The
state still holds the old seed - harmless, it is used only when the Secret is created.

## Break-Glass Access

The kubeconfig Terraform writes (`infra/terraform/hcloud_cluster/kubeconfig.yaml`) holds a
cluster-admin client certificate. People sign in through Dex (OIDC): admin in develop, read-only
elsewhere. This file is for when that is not enough - Dex is down, or an incident needs a write that
no role allows.

- **Who holds it:** the person who applied Terraform, on that machine, mode `0600`, git-ignored. It is
  also in the Terraform state. It is never copied to a chat, a ticket or another laptop.
- **When:** an incident that OIDC access cannot handle. Say so where the team talks *before* using it:
  who, why, for how long.
- **After:** write down what was changed with it; anything that should stay goes back into Git, or Flux
  undoes it.
- **Revoking it:** a client certificate cannot be revoked one by one - Kubernetes has no revocation
  list. It ends when it expires, or when the cluster's certificate authority is replaced. The
  Hetzner cluster is rebuilt each cycle, which replaces both; on a cluster that lives on, a lost admin
  kubeconfig means rotating the CA (k3s: `k3s certificate rotate-ca`) - plan it as an outage.

## Prometheus Service Account Token

kube-prometheus-stack creates a `kubernetes.io/service-account-token` Secret for Prometheus: the
ServiceMonitors of the API server, the kubelets and CoreDNS can authenticate only through a Secret.
The token in it never expires. The Hetzner cluster is rebuilt each cycle, which replaces it; on a
cluster that lives on, replace it when it may have been seen.

**Deleting the Secret is not a rotation.** The token names only the ServiceAccount (name and UID) and
the Secret's name - no issue time, no Secret UID - so the Secret the chart creates again holds the same
token, byte for byte, and the old copy is valid again (seen on kind, 2026-10-12). And while the Secret
is missing, the operator drops the three ServiceMonitors from Prometheus' configuration: their targets
disappear instead of turning down, so no `TargetDown` fires.

A new token needs a new ServiceAccount:

1. Delete the ServiceAccount - Kubernetes deletes its token Secret with it, and the old token stops
   working at once:
   `kubectl --context <name> -n observability delete serviceaccount kube-prometheus-stack-prometheus`.
2. Let the chart create both again:
   `flux --context <name> reconcile helmrelease kube-prometheus-stack -n observability --force`.
3. Restart Prometheus: its pod still carries the old ServiceAccount's token, and its Kubernetes service
   discovery gets `401` until it starts again. The prometheus-operator owns the StatefulSet, not Flux,
   so deleting the pod is the restart:
   `kubectl --context <name> -n observability delete pod prometheus-kube-prometheus-stack-prometheus-0`.
4. Verify: every target is up again - the `apiserver`, `kubelet` and `coredns` jobs among them - and
   `sum(rate(prometheus_sd_kubernetes_failures_total[5m]))` is `0`.

## Guardian LLM Key

The Guardian's Gemini key (Chapter 14) is billed per request on the owner's Google account.

1. Create a new key in Google AI Studio, under the same project.
2. `sops edit flux/secrets/observability/k8s-ai-monitor-secrets.yaml` (`gemini-api-key`) and, in the same
   pull request, the Guardian's annotation ([Restarting the Readers](#restarting-the-readers)). Merge.
   For kind, set `guardian_llm_api_key` in `infra/terraform/kind_cluster/terraform.tfvars` and run
   `make kind-plan` and `make kind-apply`. kind rolls nothing by itself: delete its pod.
3. Verify: the Guardian's log at start says `LLM check OK`.
4. Delete the old key in AI Studio.

## Third-Party URLs and DSNs

The Alertmanager heartbeat URL and the Uptrace DSN are secrets in a URL: whoever has the heartbeat URL
can report that Alertmanager is alive, and the DSN lets anyone send data into the Uptrace project.

The heartbeat URL:

1. Create a new heartbeat check URL at the provider.
2. `sops edit flux/secrets/observability/alertmanager-heartbeat.yaml`. Alertmanager reads its
   configuration without a restart. Merge.
3. Verify: the heartbeat check shows a fresh ping.
4. Delete the old check.

The Uptrace DSN has three readers, and each gets it its own way:

| Reader | Where the DSN comes from | Picks up a new one |
|---|---|---|
| backend (each environment) | Secret `backend-secrets` (`uptrace-dsn`, `uptrace-headers`): `flux/secrets/<env>/backend-secrets.yaml` on a cloud cluster, Terraform (`uptrace_dsn`) on kind | the `secrets-rotated` annotation ([Restarting the Readers](#restarting-the-readers)) |
| frontend (each environment) | the same Secret, key `uptrace-dsn` - handed to the browser, which sends its traces with it (ingest only, so public by design) | the `secrets-rotated` annotation in `flux/apps/frontend/overlays/<env>/patches/deployment.yaml` |
| OpenTelemetry collectors (`otel-collector`, `otel-events`) | Terraform variable `uptrace_dsn` → Secret `flux-system/cluster-secrets` → Flux substitutes it into both HelmReleases | by itself: a changed value changes the pod template, and Flux rolls the pods within one interval of the `opentelemetry-collector` Kustomization (10 minutes). Seen on kind on 2026-10-18 - the roll only: on kind the collectors print to their own log, not to Uptrace |

1. Create a new DSN in the Uptrace project's settings (Project → DSN).
2. Every place in `lives_in`:
   - `gh secret set UPTRACE_DSN --org safeops-course --visibility all` (paste at the prompt; the CI
     runs read it), `UPTRACE_DSN` in `.env.local` and `TF_VAR_uptrace_dsn` in `.env.gcp` (no quotes:
     the variable's validation wants `https://`), and `uptrace_dsn` in
     `infra/terraform/kind_cluster/terraform.tfvars` if one is set there;
   - `sops edit` the three `backend-secrets.yaml`, with the `secrets-rotated` annotation of the backend
     and the frontend of each environment in the same pull request. Merge.
3. Every running cluster: apply its Terraform - Hetzner: the workflow with *apply*; GKE: `make gke-plan`
   and `make gke-apply`; kind: `make kind-plan` and `make kind-apply`. The apply rewrites
   `cluster-secrets` (and on kind `backend-secrets` too); nothing else is needed for the collectors.
   On kind, set the `secrets-rotated` annotations to a new time as well - the backend and the frontend
   read a Secret Terraform changed, and no pull request rolled them.
4. Verify:
   ```bash
   # both collectors restarted after the apply, and no export errors since. --tail=-1: with a selector,
   # kubectl logs shows only 10 lines per pod. A failed call or no pods at all (kubectl then exits 0 with
   # no lines) is no count of zero.
   kubectl -n observability get pods -l app.kubernetes.io/name=opentelemetry-collector
   if logs=$(kubectl -n observability logs -l app.kubernetes.io/name=opentelemetry-collector --since=10m --tail=-1) \
     && [[ -n "$logs" ]]; then
     echo "export errors: $(grep -c 'Exporting failed' <<<"$logs")"
   else
     echo "no collector logs read - check the pods above" >&2
   fi
   unset logs
   ```
   and new logs, traces and Kubernetes Events arrive in Uptrace.
5. Delete the old DSN in Uptrace.
