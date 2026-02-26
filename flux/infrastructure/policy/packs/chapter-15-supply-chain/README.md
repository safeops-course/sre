# Chapter 14 Policy Pack (Supply Chain)

This pack is intentionally inactive.

It is the place for Kyverno `verifyImages` and attestation policies once you
enable Chapter 14 enforcement.

Suggested rollout:
1. start with validationFailureAction: Audit in `develop`
2. collect deny/audit evidence
3. move to Enforce for selected namespaces

Starter templates:
- `verify-images.example.yaml`
- `verify-attestations.example.yaml`
