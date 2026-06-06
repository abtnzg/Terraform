# ADR-007: Tenancy — namespace-per-team with team AppProjects

**Status:** Accepted (2026-06-04)
**Phase:** 0 (Foundation)

## Context

20+ engineers across multiple product teams need to share a single Kubernetes cluster (or many clusters, in later phases) without stepping on each other.

We need:
- Isolation: team A cannot read team B's secrets
- RBAC: each team has its own role
- Resource fairness: no team can starve others
- Self-service: teams can deploy without platform team approval
- Audit: every action is attributed to a user/team

## Decision

**Namespace-per-team, with team-named AppProjects in ArgoCD.**

Conventions:
- Each team gets 3 namespaces by default: `team-<name>-dev`, `team-<name>-staging`, `team-<name>-prod`
- Each team gets 1 ArgoCD `AppProject` named `team-<name>`
- Each team gets 1 Vault policy: `team-<name>-rw` (leads) and `team-<name>-ro` (developers)
- Each team gets 1 GitHub team: `team-<name>-developers`, `team-<name>-admins`

ArgoCD `AppProject` enforces:
- Source repos: only the team's repos + approved Helm chart repos
- Destinations: only `team-<name>-*` namespaces
- Allowed resource kinds: limited to the team's deployment needs (no CRDs unless explicitly granted)
- Cluster-scoped resources: only `Namespace` (so teams can create their own namespaces within a controlled pattern)

Why namespace-per-team, not cluster-per-team:
- Cluster cost at 20+ teams: 20 EKS clusters × $150/mo = $3000/mo minimum
- Operational overhead: 20 clusters to upgrade, patch, monitor
- ArgoCD can manage 500+ apps per cluster with sharding

Why AppProject as the RBAC primitive, not pure Kubernetes RBAC:
- ArgoCD is the deployment surface, not kubectl
- AppProject constrains *what can be deployed*, not just *who can run what*
- Easier to audit: every Application has a project, every project has an allow-list

## Onboarding

`vault-bootstrap/onboard-team.sh <team-name> <github-org>` automates the full flow:
1. Create Vault policies
2. Create ArgoCD AppProject
3. Create Kubernetes namespaces (in phase 2+)
4. Create GitHub teams
5. Output: a checklist of next steps for the team lead

Time to onboard: < 5 minutes.

## Consequences

- ✅ Scales to 20+ teams in a single cluster
- ✅ Self-service deployment (teams submit PRs to gitops-apps/, ArgoCD syncs)
- ✅ Audit trail: every Application is attributed to a project
- ✅ Easy onboarding (one script)
- ⚠️ Noisy-neighbor risk: one team's pods can affect another's (mitigated by ResourceQuotas, LimitRanges in phase 2+)
- ⚠️ Namespace naming convention is rigid (any new namespace must be `team-<name>-<env>`)
- ⚠️ Cluster-wide resources (CRDs, operators) require platform team approval

## References

- [Kubernetes multi-tenancy best practices](https://kubernetes.io/docs/concepts/security/multi-tenancy/)
- [ArgoCD AppProject docs](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
