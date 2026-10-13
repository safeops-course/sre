# Platform Handover

<!-- Chapter 23 capstone. Copy this file to docs/handover.md and replace every placeholder. A section
     that does not apply says why, in a sentence - a placeholder never stays: make capstone-check
     refuses the handover while one is left.
     Keep four kinds of statement apart, as in a postmortem (Chapter 15): what was observed (with its
     evidence), what is assumed, what made it possible, and what will change. The reader takes over
     tomorrow and was not there: every claim points to something they can check again. -->

- **Date (UTC):** TODO
- **From:** TODO (you) **To:** TODO (who runs the platform after you)
- **Repository and revision handed over:** TODO (your fork, and `git rev-parse origin/main`)

## The Platform in One Paragraph

TODO: what runs where, how a change reaches it, what protects it - for someone who knows Kubernetes
but not this platform.

## What Changed This Week

One row per pull request, yours and others'. Level: proven / proven with a hint (which hint) /
not proven yet.

| Change | Pull request | Proven by (the check, and the evidence below) | Level |
|---|---|---|---|
| Display names in staging | TODO | TODO | TODO |
| Display names in production | TODO | TODO | TODO |
| A colleague's change | TODO | TODO | TODO |
| Its fix | TODO | TODO | TODO |

## Evidence on the Users' Path

The probe of each environment after its change (the lab's A3) - each request's status, time and the
returned user, pasted as the commands printed them, with the time (UTC) you ran it:

```text
TODO: staging, run at (UTC)
TODO: production, run at (UTC)
```

## The Colleague's Change

- **What you observed first, and when (UTC):** TODO
- **What you assumed, and how you checked it:** TODO
- **The evidence that tied the symptom to the change:** TODO
- **The fix, its pull request, and the proof it worked:** TODO
- **Why no check caught it, and what would:** TODO

## The AI Agent's Proposal

- **The proposal, in one sentence:** TODO
- **Decision (accepted, rejected, or accepted in part):** TODO
- **The reason, with the evidence or the rule behind it:** TODO

## Acceptance Criteria

Each criterion graded - proven, proven with a hint, or not proven yet - with what proves it. For 3,
the order is the proof: staging's probe (its time above) comes before the merge of production's pull
request (its time on GitHub).

| # | Criterion | Level (and the hint opened, if any) | Evidence: where above, or the command | Time (UTC) | Revision |
|---|---|---|---|---|---|
| 1 | Flux applies origin/main | TODO | TODO | TODO | TODO |
| 2 | Display names in staging | TODO | TODO | TODO | TODO |
| 3 | Display names in production, after staging | TODO | TODO | TODO | TODO |
| 4 | The colleague's change fixed | TODO | TODO | TODO | TODO |
| 5 | No guardrail switched off | TODO | TODO | TODO | TODO |
| 6 | The smoke test | TODO | TODO | TODO | TODO |
| 7 | The handover in Git | TODO | TODO | TODO | TODO |
| 8 | The users' path, under a second | TODO | TODO | TODO | TODO |
| 9 | The AI agent's proposal decided | TODO | TODO | TODO | TODO |

The output of `make capstone-check`, as printed, and the revision it ran against:

```text
TODO
```

## How to Run It

- **Where a change goes in, and how it reaches the cluster:** TODO
- **What alerts, and who it reaches:** TODO
- **The runbooks, and which one for what:** TODO
- **Backups - the last proven restore; the RTO and RPO objectives, and what was measured against them:** TODO
- **Credentials - where the registry is, what is due next:** TODO

## What It Does Not Protect Against

TODO: the known limits, each with what it would cost to change - a single worker, what the error
budget does not count, what reaches nobody on kind, anything this week showed you.

## Before Real Users

TODO: what has to change before anyone depends on it - each item with why, and roughly what it costs.

## Open Items

| Item | Owner | Due |
|---|---|---|
| TODO | TODO | TODO |
