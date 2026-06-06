# ADR-006: Observability — Grafana stack (Mimir + Loki + Tempo) per region

**Status:** Accepted (2026-06-04)
**Phase:** 0 (Foundation) — full implementation phase 1+

## Context

We need:
- **Metrics** for cluster, workloads, pipelines, business KPIs
- **Logs** for application debugging, security audit, compliance
- **Traces** for request-flow debugging across services
- **Single pane of glass** for the entire platform (all clouds, all regions)
- **Per-tenant RBAC** (each team sees their own data, not others')
- **OpenTelemetry-native** (no proprietary agents)

## Decision

**Grafana stack per region, federated by `cluster_id` label.**

- **Mimir** (long-term metrics storage, multi-tenant)
- **Loki** (log aggregation, multi-tenant)
- **Tempo** (distributed tracing)
- **Pyroscope** (continuous profiling, phase 4)
- **Grafana** (UI, with per-region datasources)

Architecture:
- One full Grafana stack per region (initially `mgmt-aws-use1`)
- Central Grafana with a datasource per region (no central storage; queries are federated)
- OpenTelemetry Collector (DaemonSet) in every cluster, receiving OTLP and exporting to the regional stack
- Every workload ships OTel SDK (auto-instrumented where possible)
- Long-term retention: 1 year SOC 2, 7 years HIPAA, configurable per env

Why not managed (Datadog, Honeycomb, New Relic):
- Cost at 20+ engineers, 100+ services: $50k+/month
- Vendor lock-in for compliance
- OTel agents work everywhere; Datadog agents do not

Why per-region, not central:
- Storage cost: a single region would mean egress charges for every other region's data
- Latency: cross-region queries are slow
- Compliance: GDPR + FedRAMP require data to stay in region
- Resilience: a region loss doesn't lose observability for the other regions

## Consequences

- ✅ OTel-native: no proprietary agents
- ✅ Per-tenant RBAC by team label
- ✅ Region-pinned storage meets GDPR/FedRAMP
- ✅ Federated query: one Grafana URL, many datasources
- ⚠️ Operationally heavy: Mimir + Loki + Tempo + Grafana is 4 systems
- ⚠️ Cross-region queries are slow (queries are federated, not central)
- ⚠️ Object storage (S3) cost for 7-year retention is significant

## References

- [Grafana stack docs](https://grafana.com/docs/)
- [Mimir](https://grafana.com/oss/mimir/)
- [Loki](https://grafana.com/oss/loki/)
- [Tempo](https://grafana.com/oss/tempo/)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
