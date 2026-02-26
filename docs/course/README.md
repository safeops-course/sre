# Guardrails-First Course Materials

## Current Status

This directory is in active draft-delivery state (core track + advanced track packs are already present).

Available now:
- `00-intro-ai-as-junior.md` - course framing and mental model.
- `CURRICULUM.md` - approved 12-chapter core structure + advanced track.
- `_lesson-template.md` - standard lesson structure for guardrails-first labs.
- `chapter-01-introduction/README.md` - first complete guardrails lesson with demo commands.
- `chapter-02-iac/{README,lab,quiz}.md` - first IaC chapter draft with guarded Terraform workflow.
- `chapter-03-secrets-management/{README,lab,quiz}.md` - SOPS lesson pack for `encrypt -> commit -> Flux decrypt/apply`.
- `chapter-04-gitops/{README,lab,quiz}.md` - GitOps promotion pack (`develop -> staging -> production`) with rollback drill.
- `chapter-05-network-policies/{README,lab,quiz}.md` - isolation pack with default deny, DNS allow, ingress allow, and blocked-traffic debug.
- `chapter-06-security-context/{README,lab,quiz}.md` - pod hardening pack (non-root, read-only root FS, dropped caps, seccomp).
- `chapter-07-resource-management/{README,lab,quiz}.md` - requests/limits, quota/limitrange, QoS and OOM analysis pack.
- `chapter-08-availability-engineering/{README,lab,quiz}.md` - HPA/PDB availability pack with drain preflight checks.
- `chapter-09-observability/{README,lab,runbook-incident-debug,quiz}.md` - metrics/logs/traces workflow with incident debug path.
- `chapter-10-backup-restore/{README,lab,runbook,quiz}.md` - CNPG backup/restore basics with simulation workflow.
- `chapter-11-controlled-chaos/{README,lab,runbook-game-day,scorecard,quiz}.md` - deterministic failure drills + guarded Chaos Monkey in `develop`.
- `chapter-12-ai-assisted-sre-guardian/{README,lab,runbook-guardian,quiz}.md` - draft advanced-track guardian chapter mapped to `k8s-ai-monitor`.
- `chapter-13-24-7-production-sre/{README,lab,runbook-oncall,postmortem-template,quiz}.md` - on-call lifecycle and blameless operations module.
- `chapter-14-supply-chain-security/{README,lab,runbook-supply-chain,quiz}.md` - advanced supply-chain guardrails pack (SBOM, signing, verification).
- `chapter-15-admission-policy-guardrails/{README,lab,runbook-admission-policy,quiz}.md` - advanced policy-as-code enforcement pack (deny risky manifests).
- `chapter-16-rollback-data-migrations/{README,lab,runbook-rollback-migrations,quiz}.md` - advanced rollback-safe schema migration operations pack.
- `module-linkerd-progressive-delivery/{README,lab,runbook-linkerd-progressive-delivery,quiz}.md` - advanced mesh and progressive delivery module (canary/A-B).
- Flux scaffolds for advanced modules:
  - `flux/infrastructure/policy/kyverno/` + policy packs in `flux/infrastructure/policy/packs/`
  - `flux/infrastructure/progressive-delivery/{linkerd,flagger,develop}/`
  - bootstrap wiring in `flux/bootstrap/flux-system/infrastructure.yaml` (controllers enabled, sample canary pack opt-in)
- Local Git guardrails:
  - `.pre-commit-config.yaml` includes `flux-kustomize-validate`
  - `scripts/flux-kustomize-validate.sh` (yq + kustomize + kubeconform + Flux CRD schemas)

Still in progress:
- instructor-grade solution keys / answer guides per lab
- chapter numbering and legacy placeholder cleanup across `chapter-*`
- chapter-16 hands-on wiring to real backend DB migration flow (after backend migration module is implemented)

## Course Goal

Teach practical DevOps/SRE workflows where AI increases speed without increasing production risk.

Core model:
- AI proposes.
- Humans decide.
- Guardrails enforce safe execution paths.

See `../ai-code-of-conduct.md` for repository-wide rules.

## Planned Structure

The canonical structure is now the 12-chapter core program in `CURRICULUM.md`:
1. Production Mindset & Guardrails
2. Infrastructure as Code (IaC)
3. Secrets Management (SOPS)
4. GitOps & Version Promotion
5. Network Policies (Production Isolation)
6. Security Context & Pod Hardening
7. Resource Management & QoS
8. Availability Engineering (HPA + PDB)
9. Observability
10. Backup & Restore Basics
11. Controlled Chaos
12. 24/7 Production SRE

Advanced track (Part 2):
1. Supply Chain Security
2. Admission Policy Guardrails
3. AI-Assisted SRE Guardian
4. Linkerd + Progressive Delivery (Canary / A-B)
5. Rollback and Data Migrations

## Authoring Workflow

1. Start each new chapter from `_lesson-template.md`.
2. Keep each lesson tied to one failure mode and one guardrail story.
3. Include:
   - unsafe path (what breaks and why)
   - safe path (checks, approvals, rollback)
   - reproducible demo commands
4. Prefer deterministic labs that can run on local kind and map to Hetzner workflows.

## Next Recommended Content

1. Content hygiene: align chapter numbering and clearly mark/remove legacy placeholder directories.
2. Instructor assets: add lab solution keys and scoring rubrics for chapters 09, 11, 13, 14, 15, and 16.
3. Advanced track enablement: add a documented non-production rollout path for policy packs (`Audit -> Enforce`) and keep production opt-in.
4. Progressive delivery labs: enable `develop` canary sample only during lab windows and add explicit verify/rollback evidence checklist.
5. Backend integration: wire `chapter-16-rollback-data-migrations` to real backend DB migration workflow once migration tooling is added.

## Pending Decisions

1. Final course duration estimate (hours).
2. Target learner level (mid/senior split).
3. Concrete lab depth per chapter.
4. Opening and closing story arc for delivery impact.

## Notes

If a chapter folder is present but empty, treat it as planned scope, not completed material.
Current `chapter-*` directory numbering reflects existing draft files and may lag behind canonical curriculum ordering.
