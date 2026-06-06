# ADR-003: SLSA target and supply-chain controls

**Status:** Accepted (2026-06-04)
**Phase:** 0 (Foundation) — full implementation phase 2/3

## Context

The platform must produce a verifiable, auditable software supply chain. Specifically:
- Every build must produce an SBOM (SPDX or CycloneDX).
- Every artifact must be signed (cosign + Rekor).
- Provenance must be machine-verifiable.
- Builds must be reproducible.

These are required for:
- SLSA levels (target L3 by phase 2, L4 by phase 3)
- FedRAMP and SOC 2 (control evidence)
- Customer audits (regulated industries ask for SBOMs)

## Decision

**SLSA Level 3 by end of phase 2, Level 4 by end of phase 3.**

| SLSA level | Requirement | Implementation | Phase |
|---|---|---|---|
| L1 | Automated build, provenance metadata | GitHub Actions + Argo Workflows trigger on tag, generate provenance | 0 |
| L2 | Hosted build, signed provenance | cosign sign on every build, Rekor transparency log | 0 |
| L3 | Hardened builds, isolated workers, non-falsifiable provenance | BuildKit rootless mode, ephemeral runners, slsa-github-generator | 2 |
| L4 | Two-party review on build changes, reproducible builds verified | CODEOWNERS for build platform, diff-based reproducibility checks | 3 |

## Tooling

- **SBOM**: Syft (Anchore), CycloneDX output
- **Signing**: cosign (Sigstore), keyless via OIDC
- **Transparency log**: Rekor (public Sigstore instance)
- **Provenance**: SLSA GitHub generator (`slsa-framework/slsa-github-generator`)
- **Build isolation**: BuildKit (rootless), ephemeral Argo Workflows runner pods
- **Vulnerability scanning**: Trivy (SBOM + filesystem), Grype

## Consequences

- ✅ Meets FedRAMP and SOC 2 supply chain requirements
- ✅ Provides auditable evidence trail for every artifact
- ✅ Reproducible builds catch tampering
- ⚠️ Adds 5-15 seconds to every build for SBOM + sign
- ⚠️ Requires public Sigstore instance OR self-hosted Rekor (recommended for FedRAMP)
- ⚠️ Reproducible builds require locked dependencies (lockfiles mandatory, Renovate required)

## References

- [SLSA framework](https://slsa.dev)
- [Sigstore docs](https://docs.sigstore.dev/)
- [CycloneDX spec](https://cyclonedx.org/specification/overview/)
