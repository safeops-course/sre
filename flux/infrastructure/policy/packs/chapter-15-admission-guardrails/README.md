# Chapter 15 Policy Pack (Admission Guardrails)

This pack is intentionally inactive.

It is the place for Kyverno baseline policies such as:
- no mutable tags
- required securityContext fields
- required resource requests/limits
- trusted registry allowlist

Enable only after engine-only rollout is stable.

Starter templates:
- `disallow-latest-tag.example.yaml`
- `require-security-context.example.yaml`
- `require-requests-limits.example.yaml`
