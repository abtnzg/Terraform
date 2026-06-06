# ADR-0008: Ingress NGINX → Gateway API + Envoy Gateway

**Status:** Accepted (2026-06-04)
**Phase:** 0 (Foundation) — supersedes the Ingress NGINX choice

## Context

Ingress NGINX was originally chosen for the management cluster. The
Kubernetes community announced Ingress NGINX deprecation in November 2025
with end-of-life in March 2026. New projects are explicitly directed
to the **Gateway API** instead.

The platform's needs:
- Public ingress for ArgoCD, Argo Workflows, Vault UI, OTel collector
- TLS termination with cert-manager
- Per-service hostnames
- Multi-tenant RBAC (one platform team owns the Gateway; product teams
  attach their own HTTPRoute)
- Compliance-driven observability and audit
- Long-term support (we are building a 12-18 month platform, not a
  short-lived deployment)

## Considered options

1. **Stay on Ingress NGINX.** Rejected. EOL in 2-3 months from the
   freeze, no upstream security patches after that. Operationally
   irresponsible for a regulated environment.
2. **Switch to a different Ingress controller (Traefik, HAProxy).**
   Rejected. Buys time, doesn't fix the deeper problem that Ingress
   v1 is the wrong abstraction for multi-tenant, role-oriented
   operations. Same deprecation clock eventually.
3. **Gateway API + NGINX Gateway Fabric.** Viable. Same NGINX semantics
   in the data plane, modern API on the control plane. Lower migration
   friction if the team has NGINX muscle memory.
4. **Gateway API + Envoy Gateway.** Chosen.
5. **Istio IngressGateway.** Powerful but heavy. Adds a service mesh
   we don't otherwise need in phase 0.

## Decision

**Gateway API + Envoy Gateway.**

- Envoy Gateway is the upstream Envoy project's official Gateway
  implementation. CNCF, vendor-neutral.
- Single shared `Gateway` resource fronted by an AWS NLB. Each
  service attaches via an `HTTPRoute`. Tenancy is enforced by:
  - `HTTPRoute` `parentRefs.sectionName` (which Gateway listener)
  - `HTTPRoute` `hostnames` (no global wildcard in prod)
  - ArgoCD `AppProject` allowed-kinds + namespace allowlists
  - Gatekeeper baseline policies on Gateway API resources (see below)
- TLS is terminated by Envoy. cert-manager issues the cert via the
  `cert-manager.io/cluster-issuer` annotation on the Gateway listener.
  One cert covers all routes, since all hostnames are subdomains of
  a single platform zone.

## Role model (why Gateway API beats Ingress here)

Ingress v1 is "one resource, everything mixed in it." Gateway API splits
this into three roles:

| Role | Resource | Who owns it |
|---|---|---|
| **Cluster operator** | `GatewayClass` | Platform team |
| **Cluster operator** | `Gateway` (NLB, TLS) | Platform team |
| **Application developer** | `HTTPRoute` | Product team |

This matches our ADR-0007 tenancy model exactly. With Ingress, product
teams needed a ClusterRole to manage `Ingress` resources, which gave
them too much power. With Gateway API, they only need RBAC for
`HTTPRoute` in their own namespace.

## Migration path

- **Phase 0** (now): Envoy Gateway + GatewayClass + shared Gateway +
  HTTPRoute per service. Replace the legacy `server.ingress` /
  `ui.ingress` / `ingress:` blocks in the ArgoCD / Argo / OTel
  Helm values with HTTPRoutes that target the shared Gateway.
- **Phase 1** (pilot): Pilot team's first services use HTTPRoute.
  No application code change required; only manifests.
- **Phase 2**: Migrate spoke clusters (when they exist) from
  whatever they had to Gateway API + Envoy Gateway. If the spoke
  is on AKS, use the AKS Application Routing add-on (which speaks
  Gateway API natively).
- **Phase 3**: Multi-cloud parity. Envoy Gateway has a
  consistent operational model across AWS, Azure, and GCP.

## Consequences

- ✅ Future-proof: Gateway API is the upstream-recommended replacement
- ✅ Role-oriented tenancy matches our ADR-0007 model
- ✅ One cert for all platform services (simpler rotation)
- ✅ Envoy is widely deployed, well-understood, and has good
  observability (access logs, metrics, tracing)
- ⚠️ Envoy Gateway is younger than NGINX; some edge cases
  (TCP/UDP routes, mTLS) require `EnvoyProxy` CRD extensions
- ⚠️ cert-manager's `gatewayHTTPRoute` solver is newer than
  the `ingress` solver; we keep the legacy `cert-manager.io/issuer`
  annotation on the Gateway listener as a fallback
- ⚠️ The Argo Helm chart's built-in `server.ingress` / `ui.ingress`
  blocks are still Ingress-shaped; we leave them disabled and
  provide HTTPRoutes as separate manifests

## References

- [Kubernetes blog: Ingress NGINX deprecation](https://kubernetes.io/blog/2025/11/14/ingress-nginx-retirement/)
- [Gateway API](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway](https://gateway.envoyproxy.io/)
- [cert-manager Gateway API support](https://cert-manager.io/docs/usage/gateway/)
