# Policy Infrastructure (Kyverno Engine + Policy Packs)

This directory separates:
- policy engine deployment (active)
- policy packs for chapters (inactive by default)

Current state:
- `kyverno/` is intended to be reconciled by Flux (controller only).
- policy packs are not wired into Flux bootstrap yet.

This allows platform teams to deploy admission infrastructure first and enable
enforcement policies later with controlled rollout.
