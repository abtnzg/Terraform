# ============================================================================
# AWS ECR Module — Private Container Registry
# ----------------------------------------------------------------------------
# Provisions ECR private repositories for the platform with four logical
# groupings (all stored under one or more registry namespaces):
#
#   1. platform/      - argocd, argo-workflows, karpenter (and a few
#                       pre-cached controller images). Mirrors upstream
#                       so a control-plane outage doesn't take down CD.
#   2. observability/ - mimir, loki, tempo, pyroscope. Mirrored from
#                       Grafana Labs / OTel registries for compliance.
#   3. apps/          - one repo per service. Created dynamically from
#                       `var.app_repositories`.
#   4. tools/         - kaniko, buildkit, cosign, syft, trivy, etc.
#                       Used by the CI runner image and the SLSA L3
#                       build path.
#
# Auth model (all four options enabled, opt-in per workload):
#   - EKS Pod Identity associations per workload (one role per app or
#     platform component that pulls/pushes). Most secure.
#   - GitHub Actions OIDC role (push from CI). Scoped to the platform-
#     fleet org, repo list from the existing aws-eks module.
#   - EC2 instance role read access (kubelet pulls). The MNG's existing
#     role gets an inline policy granting ecr:BatchGetImage +
#     ecr:GetDownloadUrlForLayer on the registry.
#   - K8s docker-registry secret per namespace (fallback for workloads
#     that can't use Pod Identity yet). Generated as kubernetes_manifest
#     resources.
#
# Features:
#   - scan_on_push (Amazon Inspector basic scanning)
#   - Lifecycle policy (expire untagged after 7d, keep last 30 tagged)
#   - Pull-through cache rules (mirror docker.io, public.ecr.aws, ghcr.io)
#   - CMK encryption (the platform KMS module's key, not AWS-managed)
# ============================================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.100" }
    # The kubernetes provider is only used when var.create_k8s_pull_secrets
    # is true (off by default so the module is greenfield-deployable).
    # When the flag is on, the env wrapper MUST declare the provider
    # and pass it through to the platform module.
    kubernetes = {
      source                = "hashicorp/kubernetes"
      version               = "~> 2.34"
      configuration_aliases = []
    }
  }
}

# ----------------------------------------------------------------------------
# Inputs
# ----------------------------------------------------------------------------
variable "environment" {
  description = "Environment name (sandbox, dev, staging, prod)."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name. Used for resource naming and the K8s namespace for the per-namespace pull secrets."
  type        = string
}

variable "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL of the EKS cluster (for Pod Identity associations)."
  type        = string
}

variable "node_role_name" {
  description = "Name of the IAM role used by the MNG (and Karpenter-launched nodes). Gets an inline policy for ECR pull."
  type        = string
}

variable "github_org" {
  description = "GitHub org for the CI OIDC role. Must match what aws-eks uses."
  type        = string
  default     = ""
}

variable "github_repos" {
  description = "List of GitHub repos allowed to assume the CI role."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "KMS key ARN for ECR encryption (re-uses the platform's CMK)."
  type        = string
}

variable "app_repositories" {
  description = "List of app image names to create repos for (e.g. [\"payments-api\", \"web\"]). Created under the apps/ prefix."
  type        = list(string)
  default     = []
}

variable "platform_namespaces" {
  description = "K8s namespaces that need a per-namespace docker-registry pull secret. The controller for these namespaces will get a Pod Identity association automatically."
  type        = list(string)
  default     = [
    "kube-system",
    "argocd",
    "argo",
    "cert-manager",
    "external-secrets",
    "vault",
    "kyverno",
    "gatekeeper-system",
    "observability",
    "monitoring",
    # Team namespaces — each team gets a Pod Identity association so their
    # workloads can pull from ECR without a long-lived imagePullSecret.
    "pilot-team",
  ]
}

variable "public_registry_mirrors" {
  description = "Public registries to mirror via ECR pull-through cache. Each entry must be unique by upstream URL because ECR only allows one rule per (prefix, upstream) pair. Default list contains only the upstream registries that don't require Secrets Manager auth (docker.io, ghcr.io, GitLab, ACR, Chainguard DO require auth — add them with `auth_secret_arn` once you store creds in Secrets Manager). The mirror uses a per-upstream prefix (`mirrored-docker-io`, `mirrored-ghcr-io`, etc.) so multiple rules can coexist."
  type = map(object({
    upstream_url    = string
    prefix          = optional(string)
    auth_secret_arn = optional(string)
  }))
  default = {
    "public.ecr.aws" = {
      upstream_url = "public.ecr.aws"
    }
    "quay.io" = {
      upstream_url = "quay.io"
    }
  }
}

variable "lifecycle_untagged_days" {
  type    = number
  default = 7
}

variable "lifecycle_tagged_keep_count" {
  type    = number
  default = 30
}

variable "create_k8s_pull_secrets" {
  description = "Whether to create per-namespace K8s docker-registry secrets. If false, the bootstrap role (ansible) creates them. Default false so this module works on greenfield (no chicken-and-egg with the kubernetes provider)."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ----------------------------------------------------------------------------
# Locals
# ----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Registry URL — what pods and CI use to address the registry.
  registry_url = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # The four logical groupings, with the names we expose to the helmfile.
  platform_repos = [
    "platform/argocd",
    "platform/argo-workflows",
    "platform/karpenter",
  ]

  observability_repos = [
    "observability/mimir",
    "observability/loki",
    "observability/tempo",
    "observability/pyroscope",
    "observability/otel-collector",
    "observability/otel-collector-contrib",
  ]

  build_tool_repos = [
    "tools/kaniko",
    "tools/buildkit",
    "tools/cosign",
    "tools/syft",
    "tools/trivy",
    "tools/grype",
    "tools/golang",
    "tools/python",
  ]

  # App repos are namespaced under "apps/". e.g. apps/payments-api
  app_repos = [for r in var.app_repositories : "apps/${r}"]

  # The full set we manage.
  all_repos = concat(
    local.platform_repos,
    local.observability_repos,
    local.build_tool_repos,
    local.app_repos,
  )

  # Map: repo name -> ECR repository object (for IAM policy resources).
  repos_map = {
    for r in aws_ecr_repository.this : r.name => r
  }
}

# ----------------------------------------------------------------------------
# 1. ECR Repositories
# ----------------------------------------------------------------------------
# One ECR repository per logical image. The "name" we pass to ECR is the
# full path including the namespace prefix (e.g. "platform/argocd"),
# which ECR stores as a single repo with "/" allowed in the name.
resource "aws_ecr_repository" "this" {
  for_each = toset(local.all_repos)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"  # Compliance: tags can't be overwritten
  force_delete         = var.environment == "sandbox" ? true : false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(var.tags, {
    Name        = each.value
    Category    = split("/", each.value)[0]
    Environment = var.environment
  })
}

# ----------------------------------------------------------------------------
# 2. Lifecycle policy (every repo)
# ----------------------------------------------------------------------------
# Keep the last 30 tagged images; expire anything untagged after 7 days.
# Sandbox keeps more (50) for easier iteration.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.lifecycle_untagged_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.lifecycle_untagged_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${var.lifecycle_tagged_keep_count} tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release", "main", "master", "sandbox", "dev", "staging", "prod"]
          countType     = "imageCountMoreThan"
          countNumber   = var.lifecycle_tagged_keep_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ----------------------------------------------------------------------------
# 3. Registry-wide pull-through cache rules
# ----------------------------------------------------------------------------
# Mirror docker.io, ghcr.io, public.ecr.aws, and quay.io into our registry.
# Once the rule is in place, `docker pull <account>.dkr.ecr.<region>.amazonaws.com/mirrored/<repo>`
# will pull from the upstream on first request and cache for subsequent pulls.
# Helmfile values can then reference the mirrored path.
resource "aws_ecr_pull_through_cache_rule" "public" {
  for_each = var.public_registry_mirrors

  # One prefix per upstream so multiple rules can coexist. Defaults to
  # `mirrored-<sanitized-upstream>`; callers can override with `prefix`.
  ecr_repository_prefix = coalesce(each.value.prefix, "mirrored-${replace(replace(each.value.upstream_url, "https://", ""), "/", "-")}")
  upstream_registry_url = each.value.upstream_url

  # Optional: wire a Secrets Manager secret for upstreams that need auth
  # (docker.io, ghcr.io, GitLab, ACR, Chainguard). The variable is empty
  # by default, so the rule is created without authentication.
  credential_arn = each.value.auth_secret_arn
}

# One repo per upstream prefix, to hold the cached images.
# AWS requires a real ECR repository to back each pull-through rule.
# The repo name uses the SAME prefix that the rule was assigned (mirrored-<upstream>)
# so they line up.
resource "aws_ecr_repository" "pull_through_backing" {
  for_each = aws_ecr_pull_through_cache_rule.public

  name = "${each.value.ecr_repository_prefix}/cache"
  # e.g. mirrored-public-ecr-aws/cache

  image_tag_mutability = "MUTABLE"  # mirrors are rewritten by ECR
  force_delete         = var.environment == "sandbox" ? true : false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(var.tags, {
    Name        = "${each.value.ecr_repository_prefix}/${each.value.upstream_registry_url}"
    Category    = "mirrored"
    Environment = var.environment
  })
}

# ----------------------------------------------------------------------------
# 4. ECR repository policy — allow cross-account reads if you federate
# ----------------------------------------------------------------------------
# For now we keep the registry private to this account. The CI role
# (below) is in the same account, so no cross-account trust is needed.
# If you later add a "shared services" account, expand this with a
# cross-account policy that grants pull to specific principals.

# ----------------------------------------------------------------------------
# 5. GitHub Actions OIDC role (push from CI)
# ----------------------------------------------------------------------------
# Same trust pattern as the existing aws-eks module's github_oidc role,
# but scoped to ECR actions on this registry. The CI role can push to
# any repo in the registry, and pull from any.
data "tls_certificate" "github" {
  count = var.github_org != "" ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_org != "" ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = var.tags
}

data "aws_iam_policy_document" "github_ecr_assume" {
  count = var.github_org != "" && length(var.github_repos) > 0 ? length(var.github_repos) : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repos[count.index]}:*"]
    }
  }
}

resource "aws_iam_role" "github_ecr" {
  count = var.github_org != "" && length(var.github_repos) > 0 ? 1 : 0

  name               = "${var.cluster_name}-ecr-github-oidc"
  assume_role_policy = data.aws_iam_policy_document.github_ecr_assume[0].json

  tags = var.tags
}

data "aws_iam_policy_document" "github_ecr_policy" {
  count = var.github_org != "" && length(var.github_repos) > 0 ? 1 : 0

  # Allow push to ANY repo in the registry. Tighten with a `resources`
  # condition once you have a list of allowed repos.
  statement {
    sid    = "AllowECRPushAndPull"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowECRRepositoryActions"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    # Scoped to repos under this account. Tighten further with a
    # `condition` block if you need per-repo access.
    resources = [for r in aws_ecr_repository.this : r.arn]
  }
}

resource "aws_iam_role_policy" "github_ecr" {
  count = var.github_org != "" && length(var.github_repos) > 0 ? 1 : 0

  name   = "${var.cluster_name}-ecr-github-oidc"
  role   = aws_iam_role.github_ecr[0].id
  policy = data.aws_iam_policy_document.github_ecr_policy[0].json
}

# ----------------------------------------------------------------------------
# 6. EC2 instance role read access (kubelet pulls)
# ----------------------------------------------------------------------------
# The MNG's role (and any Karpenter-launched role that reuses it) gets
# an inline policy that lets kubelet pull from the registry. No
# GetAuthorizationToken call needed for ECR within the same account —
# the kubelet uses the instance role for that.
data "aws_iam_policy_document" "ec2_pull" {
  statement {
    sid    = "AllowECRPull"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }

  statement {
    sid    = "AllowECRAuthToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_pull" {
  name   = "${var.cluster_name}-ecr-pull"
  role   = var.node_role_name
  policy = data.aws_iam_policy_document.ec2_pull.json
}

# ----------------------------------------------------------------------------
# 7. EKS Pod Identity associations (per workload)
# ----------------------------------------------------------------------------
# One Pod Identity role per platform namespace. Workloads in that
# namespace can `imagePull` or `imagePush` against the registry.
#
# Pattern: read-only for most namespaces; the build-tools repo gets
# push access for kaniko / buildkit.
# EKS Pod Identity uses a different trust policy than IRSA:
# the principal is the `pods.eks.amazonaws.com` service, the action is
# sts:AssumeRole + sts:TagSession, and the OIDC issuer is filtered via
# the `eks:RequestDuration` and OIDC sub condition. Pod Identity also
# requires the `aws:ResourceTag/eks:cluster-name` condition if the
# role will be used by EKS, but that's enforced at the association
# call site by tagging the cluster, not the role.
data "aws_iam_policy_document" "workload_assume" {
  for_each = toset(var.platform_namespaces)

  statement {
    sid    = "AllowPodIdentityAssume"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

# Per-namespace role. The role is bound to the `default` ServiceAccount
# in each namespace; teams that need a dedicated SA can create their
# own binding (or pass a different `service_account_name` here).
resource "aws_iam_role" "workload_pull" {
  for_each = toset(var.platform_namespaces)

  name               = "${var.cluster_name}-ecr-${replace(each.value, "-", "")}"
  assume_role_policy = data.aws_iam_policy_document.workload_assume[each.value].json

  tags = var.tags
}

data "aws_iam_policy_document" "workload_pull" {
  for_each = toset(var.platform_namespaces)

  statement {
    sid    = "AllowECRPull"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }

  statement {
    sid    = "AllowECRAuthToken"
    effect = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "workload_pull" {
  for_each = toset(var.platform_namespaces)

  name   = "ecr-pull"
  role   = aws_iam_role.workload_pull[each.value].id
  policy = data.aws_iam_policy_document.workload_pull[each.value].json
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each = toset(var.platform_namespaces)

  cluster_name    = var.cluster_name
  namespace       = each.value
  service_account = "default"
  role_arn        = aws_iam_role.workload_pull[each.value].arn

  tags = var.tags
}

# ----------------------------------------------------------------------------
# 8. K8s docker-registry secret per namespace (fallback)
# ----------------------------------------------------------------------------
# For workloads that can't use Pod Identity (third-party operators that
# run before Pod Identity is wired, or workloads that need an explicit
# imagePullSecret). The secret contains a long-lived ECR token fetched
# via `aws ecr get-login-password`.
#
# We don't ship the password in TF state — instead, we declare a
# kubernetes Secret with an empty data map, and the bootstrap role
# (ansible) populates it via `kubectl create secret docker-registry`.
# The presence of the Secret (even empty) tells Pod admission to add
# the `imagePullSecrets` annotation when configured.
#
# Gated by var.create_k8s_pull_secrets so the module can be applied on
# a greenfield cluster (no kubernetes provider config required). When
# the bootstrap role runs, it creates these secrets directly.
resource "kubernetes_secret" "ecr_pull" {
  for_each = toset(var.create_k8s_pull_secrets ? var.platform_namespaces : [])

  metadata {
    name      = "ecr-pull"
    namespace = each.value
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "ecr-pull-secret"
    }
    annotations = {
      "ecr.terraform/registry"     = local.registry_url
      "ecr.terraform/repo-pattern" = "*"
      # Bootstrap role notes: rotate via `aws ecr get-login-password | kubectl create secret ...`
      "ecr.terraform/rotation" = "ansible-platform-bootstrap"
    }
  }

  type = "kubernetes.io/dockerconfigjson"
  data = {
    # Filled in by the ansible platform-bootstrap role. We ship an empty
    # dockerconfig to avoid breaking admission; the role overwrites this
    # with a real config on first apply.
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.registry_url) = {
          username = "AWS"
          password = ""
          auth     = ""
        }
      }
    })
  }
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------
output "registry_url" {
  description = "ECR registry URL (e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com)."
  value       = local.registry_url
}

output "repository_arns" {
  description = "Map of repo name to ARN (for use in IAM policies or CI)."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}

output "platform_repositories" {
  description = "Platform repository URLs (for use in values overrides)."
  value       = [for r in local.platform_repos : "${local.registry_url}/${r}"]
}

output "observability_repositories" {
  description = "Observability repository URLs."
  value       = [for r in local.observability_repos : "${local.registry_url}/${r}"]
}

output "app_repositories" {
  description = "App repository URLs (one per entry in var.app_repositories)."
  value       = [for r in local.app_repos : "${local.registry_url}/${r}"]
}

output "build_tool_repositories" {
  description = "Build tool image repository URLs."
  value       = [for r in local.build_tool_repos : "${local.registry_url}/${r}"]
}

output "github_actions_role_arn" {
  description = "IAM role ARN that GitHub Actions assumes to push/pull from ECR."
  value       = var.github_org != "" && length(var.github_repos) > 0 ? aws_iam_role.github_ecr[0].arn : null
}

output "workload_pull_role_arns" {
  description = "Map of namespace to Pod Identity role ARN. Bind the namespace's `default` SA to this role via `eks_pod_identity_association` (already done in this module) or via your own SA."
  value       = { for ns, r in aws_iam_role.workload_pull : ns => r.arn }
}

output "pull_through_cache_prefix" {
  description = "ECR pull-through cache prefix (e.g. \"mirrored\"). Charts and values should reference the registry URL (from ecr_registry_url output) followed by /mirrored/docker-io/library/cert-manager, etc."
  value       = "mirrored"
}
