# AI Code of Conduct (DevOps / SRE)

AI in this repo is treated as a **very fast, very well-read junior engineer**: confident, low context, and indifferent to prod vs dev. The goal is to get leverage **without increasing risk**.

## Golden Rules

1. AI does not decide. AI proposes. Humans own decisions and accountability.
2. AI is a reviewer/simulator/second brain, not an executor.
3. No direct production credentials for AI (no cloud creds, no kubeconfig with write access).
4. No “apply” without “plan”: `plan → review → apply` (with explicit environment context).
5. Small, reversible changes only. Rollback first.
6. Reduce blast radius by default (namespaces, environments, least privilege, gradual rollouts).
7. Avoid correlated failures: do not batch unrelated changes; limit parallelism; lock critical paths.
8. Prefer GitOps: changes flow through Git, reviews, and audits.

## Allowed AI Actions (Default)

- Explain diffs and failure modes.
- Generate review checklists.
- Summarize incident timelines and “what changed”.
- Suggest rollback options (with verification steps).
- Propose safe migration plans and step-by-step runbooks.

## Forbidden AI Actions (Default)

- Running commands against production.
- Writing/rotating secrets.
- Applying Terraform/Kubernetes changes.
- Pushing directly to protected branches.
- Making broad, multi-area refactors without an explicit blast-radius plan.

## “Smelly” Phrases (Treat as a Stop Sign)

- “Just delete it.”
- “Apply directly.”
- “Auto-approve.”
- “Run this in prod.”
- “It should be fine.”

## Required Guardrails

- Environment/context checks (cluster, namespace, account, region).
- Locks on `apply` paths (Terraform state lock + CI concurrency).
- Approvals for production (GitHub Environments / protected branches).
- Read-only access paths for AI.
