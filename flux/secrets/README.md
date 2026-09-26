# Secrets (SOPS + age)

Every Kubernetes Secret that Flux applies from Git lives here, encrypted with
[SOPS](https://github.com/getsops/sops) (a CNCF project) for an [age](https://github.com/FiloSottile/age)
key. Only the values are encrypted (`encrypted_regex: ^(data|stringData)$`); `kind`, `metadata` and
the names of the keys stay readable, so a diff still shows *what* changed.

The encrypted files are public and stay in the Git history forever. They are exactly as safe as the
private key: whoever gets the key can open every version of every file, including old commits.

## What lives where

| Directory | Flux Kustomization | Encrypted for | Lands in |
|---|---|---|---|
| `flux-system/` | `secrets-flux-system` | platform key | `flux-system` (image automation deploy key) |
| `auth/` | `secrets-auth` | platform key | `auth` (Dex) |
| `cloudflare/` | `secrets-cloudflare` | platform key | `cert-manager`, `external-dns` |
| `observability/` | `secrets-observability` | platform key | `observability` |
| `develop/`, `staging/`, `production/` | `secrets-develop` / `-staging` / `-production` | platform key | the environment's namespace |
| `local/` | `secrets-local` (kind local profile only) | **your** key | `develop` |

The recipients are set per path in `/.sops.yaml`. The platform Kustomizations are defined in
`flux/bootstrap/flux-system/secrets.yaml`, the local one in `flux/bootstrap/profiles/local/secrets-local.yaml`.
Each has `decryption: {provider: sops, secretRef: {name: sops-age}}`: the kustomize-controller decrypts
in memory with the private key from the Secret `flux-system/sops-age` and applies the result.

`*.example` files are plaintext templates with placeholder values - never real ones.

**One platform key for all environments.** develop, staging and production run in the same cluster,
and one kustomize-controller decrypts all of them - it would hold every key anyway. Separate keys per
environment only isolate anything when each environment has its own cluster.

## Where the private key lives

- **Platform key:** the GitHub organization secret `SOPS_AGE_KEY` (visible to the `sre` repository
  only) and the owner's password vault. Terraform receives it as the **ephemeral** variable
  `sops_age_key` and writes it into `flux-system/sops-age` through a write-only attribute (`data_wo`),
  so it is never stored in a Terraform plan or state. Never create or edit `sops-age` with `kubectl`
  on a Terraform-managed cluster - the next apply would not know about it.
- **Your key (kind):** `age.agekey` at the repository root, git-ignored. The kind module's local
  profile generates it on the first apply; `scripts/sops-setup.sh --local` writes its public half into
  the `flux/secrets/local/` rule of `.sops.yaml`. Terraform reads this generated key from the file, so
  it **is** in the local Terraform state - acceptable for a throwaway development key. For a key that
  protects anything real, pass it as `TF_VAR_sops_age_key` instead.

## Guardrails

| Check | Where | Stops |
|---|---|---|
| `sops-encrypted` (`scripts/check-sops-encrypted.sh`) | pre-commit + CI | a file under `flux/secrets/` without SOPS metadata, or with a plaintext value added by hand |
| `no-secrets` (`scripts/block-secrets.sh`) | pre-commit + CI | kubeconfigs, `*.key`, `*.pem`, `credentials*`, `*.env*` files anywhere in the repository |

CI (`.github/workflows/secrets-guard.yml`) runs both on every pull request and push to `main`,
because `git commit --no-verify` skips the local hooks.

## Create, edit, view

```bash
# New secret: opens a plaintext template in $EDITOR, encrypts it, deletes the plaintext
scripts/sops-encrypt-secret.sh develop backend-secrets      # platform directory
scripts/sops-encrypt-secret.sh local lab-secret             # kind: your key, lands in develop
# then add the file to the directory's kustomization.yaml

# Edit an encrypted file in place (decrypts into $EDITOR, re-encrypts on save) - needs the private key
sops edit flux/secrets/develop/backend-secrets.yaml

# Read it (needs the private key)
sops --decrypt flux/secrets/develop/backend-secrets.yaml
```

Never add a value to an encrypted file with a plain text editor: sops then refuses to decrypt the file
at all, and the `sops-encrypted` check rejects it. Delete the line and add the value with `sops edit`.

**A changed Secret does not restart anything.** Flux updates the Secret object; pods that read it as
environment variables keep the old value until they restart:

```bash
kubectl -n develop rollout restart deployment/backend
```

## Troubleshooting

`flux get kustomizations -A` shows the failing `secrets-*` Kustomization; its message carries the
sops error:

| Error | Meaning | Fix |
|---|---|---|
| `Failed to get the data key required to decrypt the SOPS file` | the file is encrypted for a key the cluster does not hold | encrypt for the key of that path in `.sops.yaml` (`sops updatekeys`), or give the cluster the right key |
| `sops metadata not found` | the file is not encrypted at all | encrypt it; the `sops-encrypted` check should have stopped it |
| `cannot get sops decryption Secret 'flux-system/sops-age'` | the cluster has no private key | apply Terraform (`sops_age_key`) - kind: the local profile creates it |

## Key rotation

**Routine rotation** - the old key is not known to be compromised:

1. `age-keygen -o age-new.agekey` and store the private half where the old one lives (vault, the
   GitHub secret `SOPS_AGE_KEY`).
2. Give the cluster **both** keys for the transition: an age key file may hold several
   `AGE-SECRET-KEY-...` lines. Pass both as `sops_age_key`, raise `sops_age_key_revision` (write-only
   values are only re-sent when the revision changes), apply.
3. Put the new public key into `.sops.yaml`, then re-encrypt every file for it:
   `sops updatekeys -y <file>` (`sops rotate` only renews the data key; it does not change recipients).
4. Commit, push, wait until every `secrets-*` Kustomization is Ready.
5. Remove the old key from `sops_age_key`, raise the revision again, apply.

**After a leak** of the private key, re-encrypting is not enough: anyone with the old key can still
open every encrypted file already in the Git history. Rotate the key as above **and replace every value
it protected** at its source (API tokens, passwords, deploy keys), then encrypt the new values. The
platform key was rotated this way on 2026-09-26, after it leaked through a CI artifact.
