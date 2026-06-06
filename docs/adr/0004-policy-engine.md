# ADR-004: Policy engine — Conftest in CI + Gatekeeper/Kyverno at admission

**Status:** Accepted (2026-06-04)
**Phase:** 0 (Foundation) — bundle is in `policies/`

## Context

We need policy enforcement at three boundaries:
1. **Source (CI)** — reject bad Terraform / Helm / K8s manifests before they merge
2. **Cluster (admission)** — reject workloads that violate baseline (privileged, latest tag, missing limits)
3. **Runtime (audit)** — detect drift, collect evidence for audits

The policy set covers: encryption, access control, image provenance, resource limits, compliance frameworks.

## Decision

- **CI gate**: Conftest (OPA) on Terraform plans, Helm values, and Kustomize overlays. Reject PRs that violate policy.
- **Admission gate**: OPA Gatekeeper for validation, Kyverno for mutation. Both deployed per-cluster. One policy release train.
- **Audit**: ArgoCD reports drift; Gatekeeper audit + Kyverno policy reports shipped to central observability.

Policy bundle lives in `policies/`:
- `conftest/` — OPA rego for Terraform and Helm
- `gatekeeper/` — ConstraintTemplate + baseline Constraints
- `kyverno/` — (phase 3) mutation policies

Baseline Gatekeeper constraints (phase 0):
- `K8sNoPrivileged` — pods must not run privileged
- `K8sImageTag` — no `:latest` tag, no untagged image
- `K8sContainerLimits` — every container must have CPU + memory limits
- `K8sAllowedRepos` — only approved registries (ECR, GCR, GHCR, registry.k8s.io)

Baseline Conftest policies (phase 0):
- S3 buckets must have SSE + public access block
- EBS volumes must be encrypted
- Launch templates must use IMDSv2
- EKS clusters must encrypt secrets
- IAM policies must not grant `*:*` to non-admin roles
- DB instances must not be publicly accessible
- Security groups must not allow 0.0.0.0/0 to sensitive ports
- All taggable resources must have `Environment`, `ManagedBy`, `Project` tags

## Consequences

- ✅ Defense in depth: rejected at CI and admission
- ✅ One source of truth for policy (the `policies/` repo)
- ✅ Compliance evidence auto-collected (every rejection is an event)
- ✅ Kyverno mutation removes boilerplate (e.g., injecting resource limits)
- ⚠️ Gatekeeper and Kyverno overlap in capability — choose one per policy domain
- ⚠️ Conftest OPA rego has a learning curve; budget 2-3 weeks for team ramp-up
- ⚠️ OPA Gatekeeper is being deprecated upstream; Kyverno is becoming the default. We keep both for phase 3+, but plan to migrate fully to Kyverno eventually.

## References

- [OPA docs](https://www.openpolicyagent.org/docs)
- [Conftest](https://www.conftest.dev/)
- [OPA Gatekeeper](https://open-policy-agent.github.io/gatekeeper/website/)
- [Kyverno](https://kyverno.io/docs/)
