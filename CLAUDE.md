# CLAUDE.md — SRE DevOps Repository

## AI Agent Guidance

### Repository Context

This is the SRE DevOps infrastructure repository, responsible for managing k3s clusters on Hetzner Cloud via Terraform IaC and FluxCD GitOps. It contains the reference backend/frontend services, observability stack, and the platform implementation that the separate `sre-course` repository teaches from. Terraform uses remote state in Cloudflare R2 with per-environment namespace isolation via FluxCD overlays.

### AI Agent Operating Principles

**Critical Instructions for AI Agents:**

- **Tool Result Reflection**: After receiving tool results, carefully reflect on their quality and determine optimal next steps before proceeding. Use your thinking to plan and iterate based on this new information, and then take the best next action.
- **Parallel Execution**: For maximum efficiency, whenever you need to perform multiple independent operations, invoke all relevant tools simultaneously rather than sequentially.
- **Temporary File Management**: If you create any temporary new files, scripts, or helper files for iteration, clean up these files by removing them at the end of the task.
- **High-Quality Solutions**: Write high quality, general purpose solutions. Implement solutions that work correctly for all valid inputs, not just specific cases. Do not hard-code values or create solutions that only work for specific scenarios.
- **Problem Understanding**: Focus on understanding the problem requirements and implementing the correct approach. Provide principled implementations that follow best practices and software design principles.
- **Feasibility Assessment**: If the task is unreasonable or infeasible, say so. The solution should be robust, maintainable, and extendable.

### Zen Principles of This Repo

*Inspired by PEP 20 — The Zen of Python, applied to infrastructure code:*

- **Beautiful is better than ugly** — Clean, readable Terraform/YAML over complex nested expressions
- **Explicit is better than implicit** — Clear variable names and documented intentions
- **Simple is better than complex** — Straightforward logic over clever abstractions
- **Complex is better than complicated** — When complexity is needed, make it organized not chaotic
- **Readability counts** — Code is read more often than written
- **Special cases aren't special enough to break the rules** — Consistency over exceptions
- **Errors should never pass silently** — Fail loud and early with clear messages
- **In the face of ambiguity, refuse the temptation to guess** — Test and verify, don't assume
- **If the implementation is hard to explain, it's a bad idea** — Complex patterns need clear documentation
- **If the implementation is easy to explain, it may be a good idea** — Simple solutions are often best
- **If you need a decoder ring to understand the code, rewrite it simpler** — No hieroglyphs!
- **There should be one obvious way to do it** — Establish patterns and stick to them
- **Be humble enough to build systems that are better than you** — Create safeguards that protect against human error, forgetfulness, and AI session resets

### Core Philosophical Principles

**KISS (Keep It Simple, Stupid)** — The fundamental principle guiding ALL decisions in this repository:
- Keep it simple and don't over-engineer solutions
- No hieroglyphs — code should be readable by humans, not just compilers
- Avoid complex regex patterns when simple logic works
- Replace nested function calls with clear step-by-step operations
- Use descriptive comments for complex validation logic
- If you need a decoder ring to understand the code, rewrite it simpler

**The "Be Humble" Principle** — Create safeguards that protect against:
- Human error and oversight
- AI session resets and context loss
- Complex edge cases that might be forgotten
- Future developers who may not understand the original intent

## Project Structure

```
infra/terraform/
  hcloud_cluster/    # Hetzner k3s cluster (kube-hetzner module)
  kind_cluster/      # Local development cluster
  gcp_foundation/    # Google Cloud: APIs, node + deployer service accounts, GitHub Workload Identity
                     # Federation, alert e-mail channel, budget - applied once by a person, nothing billed
                     # (docs/gcp.md; `make -C infra/terraform/gcp_foundation bootstrap`, settings in .env.gcp)
  gke_cluster/       # GKE Standard, per test cycle (created, tested, destroyed): own VPC, private nodes +
                     # Cloud NAT, DNS endpoint only, pools "platform" + "apps"; `make plan|apply|destroy|leftovers`,
                     # kubeconfig.yaml context gke-sre-control-plane (no credentials; gke-gcloud-auth-plugin);
                     # flux.tf: the same Flux bootstrap as Hetzner, profile flux/bootstrap/profiles/gke
  state-lab/         # Lab: local vs shared (MinIO, locked) state - two ConfigMaps in namespace lab
flux/
  bootstrap/         # FluxCD bootstrap: a profile per cluster on the provider-neutral base flux-system/.
                     # profiles/hetzner and profiles/gke = base + all components (components/: platform-secrets, public-edge,
                     # image-automation, alerting, opentelemetry) (+ the Hetzner load balancer patch on Hetzner);
                     # profiles/local (kind) = base + minio, lab, local secrets + kind patches, no components.
                     # The base never names a provider or depends on a component; components add their own dependsOn edges
  infrastructure/    # Helm releases (cert-manager, external-dns, prometheus, cnpg)
  apps/              # Application deployments (frontend, backend per environment)
  secrets/           # SOPS-encrypted secrets
backend/             # Go reference service (health, metrics, chaos endpoints)
frontend/            # Vue 3 SRE dashboard (Vite + Tailwind + nginx)
labs/                # Lab manifests applied by hand (never by Flux): labs/network-policies (Chapter 06), labs/security-context (Chapter 07), labs/resource-management (Chapter 08), labs/availability (Chapter 09), labs/promotion (Chapter 10)
scripts/             # Pre-commit hooks, automation scripts
  docs/                # Platform runbooks, architecture notes, and repo pointers
                       # docs/providers.md: the checklist for adding a cloud provider (AWS, Azure, ...)
```

## Key Technologies

- **IaC**: Terraform with kube-hetzner module (MicroOS, k3s)
- **GitOps**: FluxCD (Flux Operator + FluxInstance, Kustomizations, HelmReleases)
- **Secrets**: SOPS with AGE encryption
- **DNS/TLS**: external-dns (Cloudflare, proxied records) + cert-manager with Cloudflare Origin CA (origin-ca-issuer); zone SSL mode Full (strict)
- **Ingress**: Traefik, installed by Flux on every cluster (`flux/infrastructure/ingress/traefik`; Hetzner: kube-hetzner
  `ingress_controller = "custom"` creates only the load balancer; kind: NodePort 30080/30443 from the local profile)
- **Observability**: kube-prometheus-stack (Prometheus, Grafana) + k8s-ai-monitor (AI-assisted alert routing)
- **Database**: CloudNativePG
- **State**: Terraform remote state in Cloudflare R2 (S3-compatible)

## Critical Rules

### Infrastructure Safety
- **NEVER** run `terraform apply` or `terraform destroy` without explicit user approval
- **NEVER** commit secrets, kubeconfig files, .key, .pem, or .env files
- **NEVER** commit directly to main/master — always use feature branches
- **NEVER** amend commits that have been pushed to remote

### Terraform
- State is remote in R2 — never delete state files manually without understanding implications
- Use `make destroy` (not bare `terraform destroy`) — it handles Flux/k8s resource cleanup first
- All sensitive variables come via `TF_VAR_*` from `load-env.sh`
- `.tfvars` files are gitignored — use `terraform.tfvars.example` as template

### FluxCD / Kubernetes
- Environments: develop, staging, production — each has its own namespace and overlays
- Kustomize overlays pattern: `base/` + `overlays/{develop,staging,production}/patches/`
- SOPS secrets go in `flux/secrets/` with `.sops.yaml` rules per directory
- external-dns (namespace `external-dns`) reads the Cloudflare DNS token from its SOPS Secret
  `cloudflare-api-token`; origin-ca-issuer (namespace `cert-manager`) reads a separate token with only
  "SSL and Certificates: Edit" from `cloudflare-origin-ca-token` (both in flux/secrets/cloudflare)
- Flagger (progressive delivery) is installed but the develop frontend canary is OPT-IN (Ch19):
  `flux/bootstrap/flux-system/progressive-delivery-develop.yaml` is not in that kustomization.yaml.
  Only the frontend (no data; the backend is out of scope). The Canary sets `revertOnDeletion: true`
  so disabling restores the Deployment and Service; synthetic traffic feeds the analysis, and
  `CanaryRolledBack` alerts on a rejected release. `RANDOM_ERROR_RATE` (backend and frontend) is never
  set in production (`scripts/check-app-security.sh`).
- OIDC access (Dex GitHub connector, `flux/infrastructure/security/{dex,rbac}`): only members of the
  GitHub teams `safeops-course/members` and `admins` can log in; groups are `safeops-course:members` /
  `safeops-course:admins` (Dex never sends the bare org). Both: admin in develop, read-only in staging,
  production, flux-system, kube-system (no Secrets/exec). Admins also patch Kustomizations/HelmReleases
  in flux-system, limited by the ValidatingAdmissionPolicy `oidc-flux-operator-fields` (Deny) to
  spec.suspend + reconcile annotations; GitRepositories stay read-only. Every other create/update/delete
  of a Flux object by these groups is refused by `oidc-flux-objects-from-git` (Deny) - the develop `admin`
  role includes Flux's aggregated edit roles, and Flux applies with cluster-admin rights. Writing elsewhere = the
  Terraform break-glass kubeconfig. Enforced by `scripts/check-oidc-rbac.sh` (pre-commit + Flux Diff).
  kubectl login: `kubectl oidc-login setup --oidc-issuer-url=https://dex.safeops.work --oidc-client-id=kubernetes
  --oidc-extra-scope=email --oidc-extra-scope=groups` (int128/kubelogin; the API server maps the user from
  `email` and groups from `groups` - without these scopes the token has neither; the Dex client
  `kubernetes` is public - no secret, PKCE).
- Image tags: each overlay's `images[].newTag` matches its own environment's `image-policy.yaml` pattern and
  ends with the setter comment `# {"$imagepolicy": "<env>:<app>:tag"}` (`scripts/check-image-tags.sh`,
  pre-commit). Production images are never built - `promote-production.yml` (backend/frontend repos)
  re-tags a staging image (same digest). On Hetzner a rollback pins the production ImagePolicy pattern to
  the good tag (a revert of newTag alone is rewritten by ImageUpdateAutomation); kind has no automation.
- NetworkPolicies use `default-deny-all` — new services need explicit ingress/egress rules from `traefik` namespace.
  IPv4 and IPv6 alike (the platform is moving to dual-stack): a rule that opens `0.0.0.0/0` also opens `::/0` and the
  reverse, and IPv4 private ranges cut out mean `fc00::/7`, `fe80::/10` and the NAT64 prefixes cut out of `::/0`
  (`scripts/check-app-security.sh`). IPv6 is secured like IPv4, not switched off to look safe
- App security rules (enforced by `scripts/check-app-security.sh` in pre-commit and Flux Diff): every app
  Deployment sets `automountServiceAccountToken: false` and, when an HPA targets it, no `spec.replicas`;
  every workload written under `flux/` (apps and platform: Guardian, MinIO, chaos, synthetic traffic) sets
  `enableServiceLinks: false` (and no patch sets it true or removes it) - no variables for the namespace's Services
  (the API server's `KUBERNETES_SERVICE_HOST`/`_PORT`/`_PORT_HTTPS`, `KUBERNETES_PORT` and `KUBERNETES_PORT_*` are still added); `BACKEND_PORT=tcp://...` would have crash-looped the frontend
  (frontend#25, caught on kind); Helm/operator pods are not covered;
  every container runs non-root with a read-only root filesystem, no privilege escalation, capabilities
  drop ALL and seccomp RuntimeDefault (Pod Security restricted enforces all but the read-only root filesystem
  at admission); every emptyDir has a sizeLimit; every app container has `lifecycle.preStop.sleep` >= 5 s,
  a grace period covering that sleep plus 10 s of shutdown (a stopping pod still gets requests until the endpoints catch up);
  backend `PPROF_ENABLED` is `"false"` in Git;
  `CHAOS_ENABLED` is explicit - `"true"` only in develop/staging, `"false"` in production.
  `scripts/security-smoke.sh BASE_URL [HOST]` checks the public path from outside (no secrets on /api/env,
  no /api/token, no pprof, chaos as expected, bounded /delay, no wildcard CORS).

### Resource Management
- ResourceQuotas per namespace: requests 1 CPU / 1Gi (production 1 CPU / 1.5Gi); limits 2 CPU / 2Gi in develop,
  3 CPU / 3Gi in staging, 3 CPU / 4Gi in production (two Postgres instances there) (the worst case - HPA max + rolling surge + Postgres - must fit)
- App resources: staging = production >= develop (backend production/staging 100m/128Mi requests,
  250m/256Mi limits). Enforced with the quota budget by `scripts/check-app-resources.sh` (pre-commit + Flux Diff)
- LimitRange sets defaults (10m/64Mi request) — cert-manager ACME solver needs min 10m CPU
- Replica counts live ONLY in the HPA (`hpa.yaml` per environment: production 2-3, staging 2, develop 1);
  Deployments set no `spec.replicas`, or Flux would reset what the HPA scaled on every reconcile. An
  existing cluster needs `scripts/hpa-replicas-handover.sh <context> --apply` once before such a change
  (server-side apply resets a removed, solely-owned field to 1). Production has higher requests.

## Make Targets

### Root Makefile
- `make install-hooks` — install all pre-commit hooks
- `make pre-commit` — run all hooks manually
- `make fmt` — terraform fmt recursive
- `make validate` — terraform validate of every module (kind, hcloud, state-lab), no backend, no credentials
- `make tf` — list the Terraform modules and their targets
- `make kind-plan` / `kind-apply` / `kind-drift` / `kind-destroy` — local cluster; plan is saved with
  `guard-terraform-plan.sh`, apply applies only that plan (refused when older than `TF_MAX_AGE`, default 60 min)
- `make hcloud-plan` / `hcloud-apply` / `hcloud-destroy` — the same for Hetzner (aliases of
  `terraform-hcloud-plan|apply|destroy`; CI calls `terraform-hcloud-destroy`); `make hcloud-drift` - drift check
- `make cluster-conformance` — the cluster contract C1-C12 against KUBE_CONTEXT (`scripts/cluster-conformance.sh`): the
  pinned Kubernetes version exactly (a managed cluster without a pin: kind's minor), NetworkPolicies enforced (egress too), API-server egress rule, default StorageClass,
  ingress load balancer, metrics-server, webhooks reachable, WAL archiving, image architectures; PASS/FAIL/SKIP with a
  reason. Creates and deletes the namespace `conformance` (a real disk for ~1 min on a cloud); nightly on kind
- `make capstone-fault` — Chapter 23: a colleague's pull request with one random fault (f1 sign-up limit,
  f2 database network policies, f3 backend CPU), merged in the learner's repository; `scripts/capstone-fault.sh --local` commits only
  (tests/capstone-fault.test.sh). `make capstone-check` — the capstone's acceptance criteria against Git and
  the cluster, PROVEN / NOT PROVEN YET (read-only but for the smoke test's probe pod)

### hcloud_cluster / kind_cluster Makefiles
- `make init` / `make plan` (saved, via the guard) / `make apply` (that plan only) / `make destroy`
- `make test` — validate terraform configuration
- `make state-clean` — remove all resources from remote state
- `make state-clean-k8s` — remove only kubernetes resources from state
- `make kubeconfig` — print KUBECONFIG export command

## Git Workflow

1. Create feature branch from main
2. Make changes, run `make pre-commit`
3. Push and create PR — CodeRabbit reviews automatically
4. GitHub Actions runs `terraform plan` on PR
5. Merge to main — a plan runs and ends; nothing is applied. To apply: Actions → Terraform - Hetzner → Run workflow
   (main) with "apply" ticked — a fresh plan, then the apply waits for approval (environment `production`). Approve only
   the plan in the run summary: the apply job applies only the plan file with that SHA-256 and refuses one older than
   60 minutes (run it again for a fresh plan). The PR's plan is not the one that runs.

## Coding Style

- 2 spaces for YAML, HCL (Terraform), shell scripts
- Shell scripts: `set -e` minimum, `set -Eeuo pipefail` for critical scripts
- Terraform: pin chart/module versions, use meaningful resource names
- YAML: use `---` document separator, consistent indentation
- Keep it simple — KISS principle guides all decisions
