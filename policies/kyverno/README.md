# Kyverno baseline policy bundle

This directory contains the platform's baseline Kyverno policies. They are
installed cluster-wide by ArgoCD from the `gitops-fleet` repo.

## Categories

| # | Policy | What it does | Mode |
|---|---|---|---|
| 01 | `psa-baseline` | Enforce PSS *baseline* on all tenant NS | Enforce in prod, Audit elsewhere |
| 02 | `psa-restricted` | PSS *restricted* on opted-in NS, audit everywhere else | Audit |
| 10 | `require-requests-and-limits` | CPU + memory requests, memory limit | Enforce in prod |
| 11 | `disallow-latest-require-digest` | No `:latest`, digest pin in prod | Enforce in prod |
| 12 | `allowed-registries` | Only ECR / GHCR / Quay / public.ecr.aws / registry.k8s.io | Enforce in prod |
| 13 | `verify-images` | Cosign signature + SLSA provenance + SBOM attestations | Enforce in prod |
| 20 | `restrict-service-types` | ClusterIP only — go through the Gateway | Enforce in prod |
| 21 | `require-labels` | `app.kubernetes.io/{name,part-of}` mandatory | Audit |
| 22 | `require-probes` | liveness + readiness, distinct | Audit |
| 30 | `multi-tenancy` | Block `cluster-admin`, protect ResourceQuota, no bare Pods, no `default` SA | Enforce |
| 40 | `storage` | Require explicit + approved StorageClass, block `hostPath`, restrict PV creation, access-modes per driver | Enforce |
| 90 | `mutations-defaults` | securityContext, NetPol gen, ResourceQuota gen, AZ spread | (mutate) |

## Mode strategy

- **Audit** = violations are reported via PolicyReport, no admission block.
  Use this when rolling out a new policy. Watch reports for two weeks before
  flipping to Enforce.
- **Enforce** = admission webhook rejects offending objects.

Most validation rules are templated so prod gets Enforce, lower envs get
Audit — engineers iterate fast in dev, prod stays clean.

## Where each policy fits in the security model

```
Cluster boundary
 │
 ├── Network: default-deny NetworkPolicy (90, generate)
 │
 ├── Identity: explicit ServiceAccount required (30)
 │            no `cluster-admin` bindings outside platform (30)
 │
 ├── Workload admission:
 │   ├── PSS baseline (01) + optional restricted (02)
 │   ├── Default securityContext injection (90, mutate)
 │   ├── Disable SA token automount (90, mutate)
 │   └── Block bare Pods (30)
 │
 ├── Supply chain:
 │   ├── Approved registries only (12)
 │   ├── No :latest (11) + digest pin in prod (11)
 │   └── Cosign + SLSA + SBOM verification (13)
 │
 ├── Reliability:
 │   ├── Resources requests + limits (10)
 │   ├── Probes (22)
 │   └── Zonal topologySpread (90, mutate, replicas ≥ 2)
 │
 └── Tenancy:
     ├── ResourceQuota auto-gen for tenant NS (90, generate)
     └── Quota / LimitRange deletion blocked (30)

 └── Storage:
     ├── PVC must declare approved StorageClass (40)
     ├── hostPath blocked in tenant NS (40)
     ├── access-modes match driver: EBS=RWO, EFS/S3=RWX (40)
     ├── PVs platform-team only (40)
     └── Default SC mutated to gp3-encrypted (40)
```

## How to roll out a new policy

1. Drop it in this directory with `validationFailureAction: Audit`
2. Commit + push; ArgoCD syncs within a minute
3. Watch PolicyReports for two weeks:
   ```sh
   kubectl get policyreports -A --field-selector summary.fail!=0
   ```
4. Fix the noisy offenders (often dev pipelines that pre-date the policy)
5. Flip to `Enforce` via the env-aware template
6. Announce in `#platform-changelog`

## How to test policies locally

```sh
# Unit tests (assertions under tests/)
kyverno test policies/kyverno/

# Lint a single policy against a manifest
kyverno apply policies/kyverno/baseline/01-psa-baseline.yaml --resource sample-pod.yaml
```

## Why both Kyverno AND Gatekeeper?

See ADR-0009. Short version:

- **Kyverno** owns: PSS profiles, mutations, generation, image verification.
  YAML-first, easier to read for app teams.
- **Gatekeeper** owns: bespoke Rego validation, Gateway API constraints,
  anything that needs the OPA constraint framework.

They do not overlap on validation rules — each policy has exactly one owner.
