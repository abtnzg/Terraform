# ADR-005: Secret management — Vault per region with KMS auto-unseal

**Status:** Accepted (2026-06-04)
**Phase:** 0 (Foundation)

## Context

The platform needs to store and distribute:
- Application secrets (DB credentials, API keys, OAuth clients)
- Platform secrets (CI runner tokens, GitHub webhooks, registry creds)
- Cross-cluster shared secrets (e.g., shared SSO client)
- Compliance: encryption at rest, rotation, audit

Multi-cloud + regulated industry + 20+ engineers narrows the options.

## Decision

**HashiCorp Vault, deployed per region with KMS auto-unseal.**

- **Dev**: single Vault pod, in-memory storage, no unseal.
- **Staging / Prod**: 3-node Vault HA Raft, AWS KMS auto-unseal, audit logs to CloudWatch + file.
- **Cross-region**: secondary Vault cluster for DR (read-only), performance replication for active-active. No cross-cloud replication.
- **Application access**: External Secrets Operator (ESO) in each cluster, syncing Vault KV v2 secrets to K8s Secrets. Apps never talk to Vault directly.
- **Audit**: every read/write to Vault is logged. Logs shipped to CloudWatch + S3 (7-year retention for HIPAA, 1 year for SOC 2).

Why per-region, not per-cluster: smaller blast radius, simpler compliance, fewer unseal operations. A region loss loses a Vault, but a single-cluster Vault loss also takes down that cluster's apps.

Why not cloud-native (AWS Secrets Manager / Azure Key Vault / GCP Secret Manager):
- Multi-cloud would require abstracting 3 different APIs.
- No first-class dynamic secrets (database creds) outside of AWS.
- Per-secret pricing adds up.
- Harder to expose to on-prem clusters.

## Unseal key distribution

5 key shares, threshold 3. Operators store them in 1Password vaults or AWS Secrets Manager. Region-distributed (2 in US, 2 in EU, 1 in APAC) for DR. KMS auto-unseal handles the routine case; manual unseal is for catastrophic recovery.

## Consequences

- ✅ KMS auto-unseal means the unseal key never lives in operator memory
- ✅ Dynamic database credentials (Vault DB engine) for short-lived creds
- ✅ Single API for all clouds and on-prem
- ✅ Audit log is uniform across regions
- ⚠️ Operational overhead: 3 nodes, upgrades, backups, DR drills
- ⚠️ Initial bootstrap is manual (5 key shares, threshold 3)
- ⚠️ Vault licensing (if using enterprise features like HSM auto-unseal) is expensive

## References

- [Vault HA with Raft](https://developer.hashicorp.com/vault/docs/raft)
- [AWS KMS auto-unseal](https://developer.hashicorp.com/vault/docs/configuration/seal/awskms)
- [External Secrets Operator](https://external-secrets.io/)
