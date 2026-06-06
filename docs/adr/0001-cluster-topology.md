# ADR-001: Cluster topology — hub-spoke GitOps-of-GitOps

**Status:** Accepted (2026-06-04)
**Phase:** 0 (Foundation)

## Context

We need a Kubernetes footprint that supports:
- 20+ engineers across multiple product teams
- Multiple regions (data residency for GDPR, FedRAMP)
- Multiple clouds (AWS + Azure + GCP + on-prem by phase 3)
- Strict tenant isolation (team-namespace boundaries, per-team RBAC)
- Region failover (RTO < 1 hour, RPO < 5 minutes)

## Considered options

1. **Single shared cluster, multi-tenant namespaces.** Cheapest, simplest. Breaks at scale (>500 apps, blast radius concerns). Cross-region impossible without a second cluster.
2. **Cluster per team.** Maximum isolation, but operational overhead grows linearly with teams.
3. **Hub-spoke GitOps-of-GitOps.** One management cluster per region runs Argo Workflows, ArgoCD, Vault, observability. Workload clusters (spokes) run app workloads. ArgoCD on each hub manages its own spokes.

## Decision

**Hub-spoke GitOps-of-GitOps.**

- One **management cluster** per region (initial: `mgmt-aws-use1`).
- Management clusters run the control plane: Argo Workflows (CI), ArgoCD (CD), Vault, External Secrets, cert-manager, observability.
- Workload clusters (spokes) are added per region/team in phase 2+.
- `gitops-fleet/` repo declares clusters and App-of-Apps.
- `gitops-apps/` repo declares per-team workloads.

## Consequences

- ✅ Scales to 20+ engineers without cluster sprawl
- ✅ Region-pinned management cluster = region-pinned workloads (data residency)
- ✅ Single mental model: ArgoCD everywhere
- ✅ Compliance teams get one audit log pipeline (Vault audit + Argo audit + K8s audit)
- ⚠️ Bootstrap is more complex: must deploy the hub first, then spokes
- ⚠️ ArgoCD sync latency for spoke clusters requires ApplicationSet `cluster.sharding` to scale beyond ~10 spokes
- ⚠️ Cross-cluster secret access requires Vault per region + performance/replication tier (PR cluster for performance, secondary for DR)

## References

- [ArgoCD multi-cluster guidance](https://argo-cd.readthedocs.io/en/stable/operator-manual/multi_cluster/)
- [App-of-Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
