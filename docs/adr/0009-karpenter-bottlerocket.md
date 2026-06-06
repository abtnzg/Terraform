# ADR-0009: Karpenter + Bottlerocket + Brupop + Kyverno alongside Gatekeeper

## Status

Accepted — 2026-06-04.

## Context

Two questions came to a head in the same week:

1. **How do we scale and patch nodes?** Cluster Autoscaler was the only realistic
   option when EKS launched in 2018; it's now showing its age. It scales by
   resizing existing managed-node-groups, which means: poor bin-packing, slow
   reaction time, no spot diversification, and OS patching requires the
   blunt instrument of "cycle the whole MNG." Meanwhile the workload mix
   includes (a) long-lived platform services, (b) bursty Argo Workflow runs,
   and (c) a fleet that will eventually span four clouds — we need
   bin-packing, spot, mixed instance families, and per-pool disruption budgets.

2. **How do we enforce policy across 4-6 teams without becoming the team that
   writes Rego?** Gatekeeper is well-established and excellent for
   constraint-framework validation, but it does not mutate — meaning every
   app team has to learn the entire securityContext incantation, and every
   bad manifest ends in a rejection rather than a quiet auto-fix. PSS
   profiles, image verification, NetworkPolicy generation — these are all
   things that exist as first-class features in Kyverno and require thousand-
   line Rego files in Gatekeeper.

## Decision

### Autoscaler: Karpenter v1, not Cluster Autoscaler

- **Karpenter v1** as the only autoscaler. CAS is removed.
- One `EC2NodeClass` per OS/role (`default`, `system`).
- Four `NodePool`s:
  - `default-spot` — bulk workloads, spot-first, weight 100
  - `default-ondemand` — interruption-intolerant fallback, weight 50
  - `system` — Karpenter / coredns / observability, tainted, on-demand only
  - `batch` — Argo Workflow runners, large spot pool, tainted
- A tiny **managed-node-group survives** for bootstrap (Karpenter, coredns,
  kube-proxy) — Karpenter can't schedule itself before it exists.
- Disruption budgets in every NodePool. Prod additionally freezes
  disruption during business hours (UTC).

### Node OS: Bottlerocket everywhere

- Immutable two-partition image, atomic A/B updates, signed by AWS.
- Settings via TOML in user-data — no Ansible at runtime, no SSH.
- IMDSv2-only, 1-hop TTL on metadata.
- Kernel hardening sysctls baked in (no unprivileged BPF, no unprivileged
  user namespaces, ptrace_scope=2).

### OS patching: split mechanism

- **Karpenter pools**: drift-based replacement. EC2NodeClass references
  `bottlerocket@latest` alias; when it resolves to a new AMI, Karpenter
  replaces nodes one disruption-budget at a time. New node Ready → drain
  old node → terminate. Zero unscheduled downtime.
- **Bootstrap MNG**: Brupop (Bottlerocket Update Operator). In-place updates
  via the Bottlerocket API, one node at a time, on a weekly cron.

Regulated environments (FedRAMP, SOC 2 Type 2) pin a specific AMI ID
instead of the alias and roll updates via PR — gives a paper trail.

### Policy: Kyverno AND Gatekeeper, with a clear split

- **Kyverno** owns:
  - PSS baseline + restricted enforcement
  - Mutations (default securityContext, disable SA token automount,
    inject topologySpread)
  - Generation (default-deny NetworkPolicy per new NS, ResourceQuota
    per tenant NS)
  - Image verification (cosign signatures, SLSA provenance, SBOM
    attestations) — Kyverno's `verifyImages` is the cleanest implementation
- **Gatekeeper** owns:
  - Bespoke Rego validation (we have non-trivial ones: Gateway API
    listener constraints, Terraform OPA in CI)
  - Anything that uses the OPA constraint framework so we don't duplicate
    the Conftest ↔ Gatekeeper policy library

Both run in HA (3 replicas), validating-only. Gatekeeper's mutating webhook
is **disabled** — Kyverno owns mutation. This avoids ordering ambiguity
between two mutators on the same field.

## Consequences

### Good

- **30-50% cost savings** vs CAS in the workload pools (real-world Karpenter
  spot adoption + bin-packing; this matches the budget gap in the phase
  plan).
- **Drift-based patching** means we can roll a CVE patch in <24h cluster-
  wide without a maintenance window.
- **Mutating Kyverno** removes the most common cause of rejected manifests
  in onboarded teams (missing securityContext, missing default-deny netpol).
  Engineers learn to write less YAML, not more.
- **Image verification at admission** closes the supply-chain loop:
  unsigned image → admission reject → user sees the failure in the deploy
  log, not in production three days later.

### Bad

- **Two policy engines to operate.** Both have CRDs, both have webhooks,
  both have metrics. Mitigated by the strict split — engineers learn one
  surface per concern.
- **Karpenter v1 is recent.** Breaking changes from v0.32 → v1 are not
  trivial (NodePool/EC2NodeClass replaced NodeTemplate/Provisioner). We
  pinned to `~1.0.0` and accept upgrade churn.
- **Bottlerocket has a learning curve.** No `apt`, no shell. Wrong mental
  model for engineers used to Amazon Linux. The runbook covers the common
  ops (rollback, force update, ssh-via-admin-container).
- **Brupop and Karpenter must not fight.** Brupop only targets nodes
  labelled `bottlerocket.aws/updater-interface-version` (set in the MNG
  launch template). Karpenter-launched nodes don't get that label, so
  Brupop ignores them — Karpenter handles them via drift.

### Carry-forward

- Per-NodePool **cost dashboards** (Kubecost, phase 2) will validate the
  spot/on-demand split.
- **NodePool budgets** may need tuning under real load — start conservative
  (10%), watch the disruption rate, raise if needed.
- **Kyverno → Gatekeeper migration is one-way.** If a policy can live in
  either, prefer Kyverno (YAML > Rego for the app team).

## Alternatives considered

- **Stay on CAS + Bottlerocket + Kured**: would work, but loses bin-packing,
  spot diversification, drift-based patching. Wrong long-term trajectory.
- **Karpenter + Amazon Linux 2023**: AL2023 is fine; Bottlerocket is better
  for the regulatory framework we operate in (immutable, signed, no shell).
- **Gatekeeper-only**: ruled out because mutation and image verification
  are essential and Kyverno does them with an order of magnitude less code.
- **Kyverno-only**: ruled out because we already have valuable Rego
  (Conftest in CI, Gateway API constraints) and rewriting it loses the
  shared library.

## References

- Karpenter docs: https://karpenter.sh
- Bottlerocket: https://bottlerocket.dev
- Brupop: https://github.com/bottlerocket-os/bottlerocket-update-operator
- Kyverno: https://kyverno.io
- ADR-0004 (policy engines — superseded for the mutating-engine choice)
- `platform-fleet/docs/runbooks/node-os-patching.md`
