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
| `cloudflare/` | `secrets-cloudflare` | platform key | `cert-manager` (Origin CA token), `external-dns` (DNS token) |
| `observability/` | `secrets-observability` | platform key | `observability` |
| `develop/`, `staging/`, `production/` | `secrets-develop` / `-staging` / `-production` | platform key | the environment's namespace |
| `local/` | `secrets-local` (kind local profile only) | **your** key | `develop` |

The recipients are set per path in `.sops.yaml` at the repository root. The platform Kustomizations are defined in
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
| `no-secrets` (`scripts/block-secrets.sh`) | pre-commit + CI | files named `kubeconfig` / `kubeconfig.yaml`, `*.key`, `*.pem`, `credentials*` (name starts with `credentials`), `*.env` / `*.env.*` - anywhere in the repository, `*.example` excepted |

| `credentials` (`scripts/check-credentials.sh`) | pre-commit + CI + daily | a file here that is not in the credential registry (`docs/credential-registry.yaml`), or a credential due for rotation |

CI (`.github/workflows/secrets-guard.yml`) runs the first two on every pull request and push to `main`,
because `git commit --no-verify` skips the local hooks. Every value here is also a credential in
`docs/credential-registry.yaml`, with its rotation runbook in `docs/credential-rotation.md`.

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

Each file is encrypted in two layers: sops encrypts the values with a random **data key**, and
encrypts that data key for every age recipient (the `sops:` block at the end of the file). Two
commands work on those layers:

- `sops updatekeys -y <file>` - re-encrypts the **data key** for the recipients `.sops.yaml` names
  now. The values stay byte for byte the same, still under the old data key.
- `sops rotate -i <file>` - a **new data key**, every value re-encrypted with it. Recipients unchanged.

A rotation needs both. After `updatekeys` alone, whoever holds the old key can take an old commit,
recover the data key from it, and read the current file - and every value `sops edit` adds later,
because editing keeps the data key.

**Routine rotation** - the old key is not known to be compromised, and nobody who held it has lost the right to read the secrets (an old key, a scheduled rotation):

1. `age-keygen -o age-new.agekey` and store the private half where the old one lives (vault, the
   GitHub secret `SOPS_AGE_KEY`).
2. Give the cluster **both** keys for the transition: an age key file may hold several
   `AGE-SECRET-KEY-...` lines. Pass both as `sops_age_key`, raise `sops_age_key_revision` (write-only
   values are only re-sent when the revision changes), apply.
3. Put the new public key into `.sops.yaml`, then for every file: `sops updatekeys -y <file>` and
   `sops rotate -i <file>`.
4. Commit, push, wait until every `secrets-*` Kustomization is Ready.
5. Remove the old key from `sops_age_key`, raise the revision again, apply.

**Your key on kind** - the same steps, with files instead of a vault (Chapter 04 lab):

```bash
export SOPS_AGE_KEY_FILE="$PWD/age.agekey"
cp age.agekey age-old.agekey
age-keygen -o age-new.agekey
cat age-new.agekey age-old.agekey > age.agekey   # both keys, the NEW one first
make kind-plan && make kind-apply                # read the plan: only sops-age changes
scripts/sops-setup.sh --local                    # registers the FIRST key in .sops.yaml
sops updatekeys -y flux/secrets/local/<file>.yaml && sops rotate -i flux/secrets/local/<file>.yaml
git add .sops.yaml flux/secrets/local && git commit -m "rotate the kind age key" && git push
cp age-new.agekey age.agekey && make kind-plan && make kind-apply   # the cluster drops the old key
rm age-old.agekey age-new.agekey
```

The kind module needs no revision number: for the local profile the revision follows the key file, so
a changed `age.agekey` is re-sent on the next apply (an in-place update of `kubernetes_secret_v1.sops_age`
in the plan; the key itself never shows).

**After a leak** of the private key, re-encrypting is not enough: anyone with the old key can still
open every encrypted file already in the Git history. The same holds when someone who held the key
leaves - they keep a copy - so treat it as a leak, and also remove their own access. Rotate the key as above **and replace every value
it protected** at its source (API tokens, passwords, deploy keys), then encrypt the new values. The
platform key was rotated this way on 2026-09-26, after it leaked through a CI artifact; every platform
file was encrypted from scratch, so each has a new data key.
