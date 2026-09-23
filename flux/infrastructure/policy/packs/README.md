# Policy Packs (Inactive by Default)

These policy packs are chapter scaffolds and are not reconciled by Flux unless
you add explicit `Kustomization` entries in `flux/bootstrap/flux-system/infrastructure.yaml`.

- `chapter-15-admission-guardrails/` contains baseline admission policy examples.
- `chapter-16-supply-chain/` contains signature/attestation policy examples.

Use staged rollout:
1. deploy policy engine (Kyverno)
2. run in audit mode in non-production
3. switch selected policies to enforce
