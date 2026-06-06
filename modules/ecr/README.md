# ============================================================================
# AWS ECR Module — README
# ============================================================================
#
# What this module creates
# ------------------------
# 1. Repositories under the registry at `<account>.dkr.ecr.<region>.amazonaws.com`:
#    - platform/*    — argocd, argo-workflows, karpenter
#    - observability/* — mimir, loki, tempo, pyroscope, otel-collector
#    - apps/*         — one per entry in var.app_repositories
#    - tools/*        — kaniko, buildkit, cosign, syft, trivy, grype, golang, python
# 2. Per-repo lifecycle policy (expire untagged after 7d, keep last 30 tagged)
# 3. Pull-through cache rules for docker.io, public.ecr.aws, ghcr.io, quay.io
# 4. GitHub Actions OIDC role for CI to push/pull
# 5. EC2 instance role read access (kubelet pulls)
# 6. EKS Pod Identity role per platform namespace (workload pulls)
# 7. (Optional) K8s docker-registry secret per namespace — gated by
#    var.create_k8s_pull_secrets, defaults to false.
#
# All repos are encrypted with the platform KMS CMK (var.kms_key_arn)
# and scanned on push (Amazon Inspector basic scanning).
#
# How to use
# ----------
# In your helmfile values (.gotmpl), reference images by their full ECR path:
#
#   image: {{ requiredEnv "ECR_REGISTRY" }}/platform/argocd:{{ .Values.version }}
#
# Where ECR_REGISTRY is exported by the bootstrap role:
#
#   export ECR_REGISTRY=$(terraform output -raw ecr_registry_url)
#
# For the pull-through cache, the convention is:
#
#   image: {{ requiredEnv "ECR_REGISTRY" }}/mirrored/docker-io/library/cert-manager:v1.15.5
#
# ECR will pull from docker.io on first request and cache the image.
#
# To add an app repo, edit envs/<env>/terraform.tfvars and add to
# app_repositories:
#
#   app_repositories = ["payments-api", "web"]
#
# Then re-run `terraform apply`. A new `apps/payments-api` repo appears
# in ECR. Push images with:
#
#   docker tag myapp:abc123 ${ECR_REGISTRY}/apps/payments-api:abc123
#   docker push ${ECR_REGISTRY}/apps/payments-api:abc123
#
# Auth for CI
# -----------
# GitHub Actions assumes the role output by `ecr_github_actions_role_arn`.
# Use `aws-actions/configure-aws-credentials` with that role ARN:
#
#   - uses: aws-actions/configure-aws-credentials@v4
#     with:
#       role-to-assume: ${{ secrets.ECR_PUSH_ROLE }}
#       aws-region: us-east-1
#
# Auth for kubelet
# ----------------
# The MNG's role (var.node_role_name) gets an inline policy automatically
# via this module. Karpenter-launched nodes reuse the same role, so they
# also get pull access without extra wiring.
#
# Auth for in-cluster workloads (Pod Identity)
# --------------------------------------------
# The platform namespaces listed in var.platform_namespaces get a
# Pod Identity association binding the namespace's `default` SA to a
# dedicated ECR-pull role. Workloads in those namespaces can `ecr-pull`
# without explicit credentials.
#
# If a namespace needs a non-default SA, create a new
# `aws_eks_pod_identity_association` for it (out of scope for this module).
#
# Limits and quotas
# -----------------
# ECR has a soft account limit of 10,000 repos. The module currently
# creates 18 by default; even with 100 app repos you stay well under.
#
# The pull-through cache has its own quota: 25 cache rules per account.
# We've allocated 4 (docker.io, public.ecr.aws, ghcr.io, quay.io). If
# you need more, add them to var.public_registry_mirrors — but be aware
# some upstreams (notably k8s.gcr.io) require custom credentials and
# can't be cached without extra trust policy work.
#
# Why this is a Terraform module, not a helmfile entry
# ----------------------------------------------------
# ECR repositories, IAM roles, OIDC trust, and Pod Identity associations
# are all AWS-side resources. They MUST live in Terraform so they're
# applied before any cluster-side chart tries to pull from them, and
# so the IAM state is owned by the same tooling as the rest of the
# platform's AWS resources.
#
# The cluster-side `imagePullSecrets` (which need real, rotated ECR
# passwords) live in the ansible platform-bootstrap role — see
# `ansible/roles/platform-bootstrap/tasks/ecr-pull-secrets.yml`. That
# keeps long-lived secrets out of TF state.
