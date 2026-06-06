# Platform Fleet

Multi-cloud DevSecOps platform — Phase 0 (Foundation).

This repo is the **infrastructure layer** of the platform. It provisions the
management EKS cluster per environment and the VPC + KMS + IAM that surround
it. The **workload layer** lives in `gitops-fleet/` and `gitops-apps/`.

## Status

| Phase | Window | Scope | Status |
|---|---|---|---|
| **0 — Foundation** | Weeks 1-3 | AWS management cluster, Argo Workflows + ArgoCD + Vault, GitOps-of-GitOps, OPA policies, GitHub OIDC | **In progress** |
| 1 — Pilot | Weeks 4-12 | 1 product team on AWS, end-to-end pipeline (CI/CD/secrets/observability) | Not started |
| 2 — Scale + L3 | Months 4-7 | 3-5 teams, Azure region, SLSA L3 | Not started |
| 3 — Multi-cloud + L4 | Months 8-12 | GCP + on-prem, SLSA L4, FedRAMP boundary | Not started |
| 4 — Federation | Months 13-18 | Self-service, 20+ engineers | Not started |

## Layout

```
platform-fleet/
├── main.tf                 # Root composition
├── providers.tf            # AWS / Azure / GCP / Kubernetes / Helm / Vault
├── variables.tf            # All input variables
├── locals.tf               # Computed values (tags, AZs, name prefix)
├── versions.tf             # Provider pinning
├── modules/
│   ├── aws-vpc/            # Multi-AZ VPC, multi-NAT, flow logs
│   ├── aws-eks/            # EKS 1.31, managed node groups, IRSA, GitHub OIDC
│   ├── kms/                # CMK with rotation + compliance-driven policy
│   ├── azure-vnet/         # (phase 3) Azure VNet + AKS
│   ├── gcp-vpc/            # (phase 3) GCP VPC + GKE
│   └── onprem-baremetal/   # (phase 3) EKS Anywhere / Rancher
├── envs/
│   ├── _template/          # Backend.tf and backend-bootstrap
│   ├── dev/                # Per-env Terraform state + tfvars
│   ├── staging/
│   └── prod/
├── ci/                     # Argo WorkflowTemplates (lint-tf, lint-helm, conftest)
├── scripts/
│   └── bootstrap.sh        # One-shot: backend → EKS → ArgoCD root app
├── policies/               # Mirror of /policies/Conftest + Gatekeeper (read-only here)
└── docs/
    └── adr/                # Architectural Decision Records
```

## Quick start (dev environment)

```bash
# 0. Prereqs: terraform >= 1.9, helm >= 3.15, helmfile >= 0.169, kubectl, aws-cli, jq

# 1. Configure AWS credentials
aws configure sso  # or whatever your org uses

# 2. Bootstrap the dev environment (creates backend, applies Terraform, installs ArgoCD)
./scripts/bootstrap.sh dev

# 3. Initialize Vault (manual one-time, see vault-bootstrap/RUNBOOK.md)
export VAULT_KMS_KEY_ID=$(terraform -chdir=envs/dev output -raw kms_key_arn)
./../vault-bootstrap/init-vault.sh

# 4. Onboard the pilot team
./../vault-bootstrap/onboard-team.sh pilot-team your-org

# 5. (Optional) Verify the cluster is healthy
make validate ENV=dev
```

The whole process takes ~30 minutes. The output includes the ArgoCD UI URL
and the initial admin password.

## What this repo is NOT

- It does **not** hold the ArgoCD `Application` resources. Those live in `gitops-fleet/`.
- It does **not** hold per-team workload manifests. Those live in `gitops-apps/`.
- It does **not** hold the policies that run inside clusters. Those live in `policies/`.

This separation means:
- The platform team owns `platform-fleet/`, `mgmt-cluster-aws/`, `policies/`, `vault-bootstrap/`, and `gitops-fleet/`.
- Product teams own `gitops-apps/teams/<their-team>/`.
- The two repos can have different branch protection, CODEOWNERS, and review requirements.

## Compliance

This platform is designed to satisfy:
- **SOC 2** — change management, access control, audit logging, encryption at rest + in transit
- **ISO 27001** — ISMS, risk management, statement of applicability
- **HIPAA** — 7-year log retention, encryption, BAAs with cloud providers
- **PCI-DSS** — segmentation, encryption, restricted access, audit trails
- **FedRAMP** — CMK, key rotation, region pinning, continuous monitoring
- **GDPR** — data residency (region-pinned clusters), right-to-deletion procedures

The `compliance_frameworks` variable on the root module drives which
controls are enabled per environment.

## References

- [Phased delivery plan](/home/ubuntu/.claude/plans/typed-seeking-tarjan.md)
- [Architecture Decision Records](docs/adr/)
- [Bootstrap script](scripts/bootstrap.sh)
- [Vault operations runbook](../vault-bootstrap/RUNBOOK.md)
- [CI WorkflowTemplates](ci/)
