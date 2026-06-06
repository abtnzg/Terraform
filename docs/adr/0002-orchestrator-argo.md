# ADR-002: CI/CD orchestrator — Argo Workflows + ArgoCD

**Status:** Accepted (2026-06-04)
**Phase:** 0 (Foundation)

## Context

The platform's CI/CD layer must:
- Run reproducible pipelines (build → test → scan → sign → push)
- Provide GitOps-driven continuous deployment
- Support multi-cloud, multi-region
- Provide strong audit trail (every action attributed to a user/PR)
- Scale to 20+ teams without per-team Jenkins controllers
- Work with regulated industry compliance (SOC 2, ISO 27001, HIPAA, PCI, FedRAMP, GDPR)

## Considered options

1. **Jenkins (current state).** Proven, but: JCasC is awkward, plugin hell, 1 controller per cluster, no native GitOps, scaling requires fork+join hacks.
2. **Tekton + ArgoCD.** Tekton for pipelines, ArgoCD for CD. Two systems, two mental models, two RBAC models. But: Tekton is more expressive for complex pipelines.
3. **Argo Workflows + ArgoCD.** Single mental model, same RBAC, same audit trail, same UI framework. Argo Workflows is YAML-native, runs natively in K8s.
4. **GitHub Actions + ArgoCD.** GHA for CI (no infra to manage), ArgoCD for CD. Simpler ops, but GHA is the only one with first-party audit + OIDC.
5. **Managed CI (CircleCI, Buildkite, CodePipeline).** Less control, vendor lock-in, but no infra to operate.

## Decision

**Argo Workflows + ArgoCD.**

- Argo Workflows runs the CI pipelines (defined as `WorkflowTemplate` resources, versioned in Git).
- ArgoCD runs the CD (pull-based GitOps, automatic sync on Git changes).
- Both use the same RBAC primitive (`AppProject` for ArgoCD, `ServiceAccount` + Kubernetes RBAC for Argo Workflows).
- Both write audit events to the same audit pipeline.

We accept that we will also run GitHub Actions for open-source-style PRs
(see `.github/workflows/`). The two are complementary: GH Actions for PR
checks against external OSS consumers, Argo Workflows for in-cluster CI
that needs access to internal secrets and registries.

## Consequences

- ✅ One mental model: declarative YAML, Git as source of truth
- ✅ Same RBAC system (Kubernetes RBAC + ArgoCD AppProject)
- ✅ Pipelines can use the same Vault secrets as workloads (no secret copies)
- ✅ Native multi-tenancy: each team gets its own `WorkflowNamespace` and `AppProject`
- ✅ Auditable by default (K8s audit log + ArgoCD audit log + Vault audit log)
- ⚠️ Argo Workflows is younger than Tekton — fewer community examples
- ⚠️ Argo Workflows UI is less polished than Jenkins
- ⚠️ `WorkflowTemplate` testing requires running a full Argo cluster

## References

- [Argo Workflows docs](https://argoproj.github.io/argo-workflows/)
- [ArgoCD docs](https://argo-cd.readthedocs.io/)
- [Tekton vs Argo comparison](https://github.com/cdfoundation/sig-events)
