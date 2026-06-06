# ============================================================================
# Root Composition
# ============================================================================
# Each cloud is its own module. Cross-cloud identity and shared services
# (KMS, observability) are factored out so spokes and platforms reuse them.
# ----------------------------------------------------------------------------

# --- Phase 0: AWS management cluster ---
module "kms" {
  source = "./modules/kms"

  environment           = var.environment
  key_description       = "Platform management cluster key (${var.environment})"
  multi_region          = false
  compliance_frameworks = var.compliance_frameworks
}

module "aws_vpc" {
  source = "./modules/aws-vpc"

  environment = var.environment
  vpc_cidr    = var.vpc_cidr
  azs         = local.azs
  az_count    = var.az_count
  # VPC flow logs + future encrypt targets use the CMK ARN, not the UUID.
  kms_key_id  = module.kms.key_arn

  tags = local.common_tags
}

module "aws_eks" {
  source = "./modules/aws-eks"

  environment             = var.environment
  cluster_name            = "${local.name_prefix}-mgmt"
  kubernetes_version      = var.eks_cluster_version
  vpc_id                  = module.aws_vpc.vpc_id
  private_subnet_ids      = module.aws_vpc.private_subnet_ids
  public_subnet_ids       = module.aws_vpc.public_subnet_ids
  endpoint_private_access = true
  endpoint_public_access  = var.environment != "prod" # private-only in prod

  node_instance_types = coalesce(var.eks_node_instance_types, local.sizing.node_instance_types)
  node_min_size       = local.sizing.node_min_size
  node_max_size       = local.sizing.node_max_size
  node_desired_size   = local.sizing.node_desired_size
  node_disk_size      = local.sizing.node_disk_size

  # EKS encryption_config.provider.key_arn requires the full ARN, not the
  # UUID. CloudWatch Logs accepts ARN or alias; ARN works for both.
  cluster_kms_key_id    = module.kms.key_arn
  secrets_kms_key_id    = module.kms.key_arn
  github_org            = var.github_org
  github_repos          = var.github_repos
  compliance_frameworks = var.compliance_frameworks
  log_retention_days    = local.sizing.log_retention_days

  tags = local.common_tags
}

# Karpenter — replaces Cluster Autoscaler. The managed-node-group above stays
# small (system / Karpenter controller / coredns); Karpenter provisions all
# workload capacity from in-cluster NodePool / EC2NodeClass CRDs.
module "aws_karpenter" {
  source = "./modules/aws-karpenter"

  cluster_name              = module.aws_eks.cluster_name
  cluster_endpoint          = module.aws_eks.cluster_endpoint
  node_role_name            = element(split("/", module.aws_eks.node_role_arn), 1)
  private_subnet_ids        = module.aws_vpc.private_subnet_ids
  cluster_security_group_id = module.aws_eks.cluster_security_group_id

  tags = local.common_tags
}

# Storage — CSI drivers' AWS-side: EFS file system, S3 bucket, KMS grants,
# and one Pod Identity role per controller (EBS / EFS / S3 Mountpoint).
# The drivers themselves are installed via Helmfile and managed by ArgoCD.
module "aws_storage" {
  source = "./modules/aws-storage"

  cluster_name           = module.aws_eks.cluster_name
  environment            = var.environment
  vpc_id                 = module.aws_vpc.vpc_id
  private_subnet_ids     = module.aws_vpc.private_subnet_ids
  node_security_group_id = module.aws_eks.cluster_security_group_id
  # Storage module already accepts both — keep them in sync.
  kms_key_id             = module.kms.key_arn
  kms_key_arn            = module.kms.key_arn
  compliance_frameworks  = var.compliance_frameworks
  sizing                 = local.sizing

  tags = local.common_tags
}

# Platform stack — installed by the helmfile apply in `mgmt-cluster-aws/`,
# not by Terraform. The Karpenter/ArgoCD/Argo Workflows helm charts have
# CRDs and pre-install hooks that are easier to manage in helmfile than
# via the helm provider. The only cluster-side resource Terraform manages
# directly is the EKS Pod Identity agent add-on (declared below), because
# it's a managed AWS addon (not a helm release) and needs to be in place
# before any Pod Identity association can deliver credentials.
# See `mgmt-cluster-aws/helmfile.yaml` for the rest of the platform stack.

# EKS Pod Identity agent (managed add-on). Must be Active before any
# Pod Identity association works. Installed via Terraform so the rest
# of the platform (helmfile) can assume it's already there.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = module.aws_eks.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = "v1.3.10-eksbuild.3"
  resolve_conflicts_on_create = "OVERWRITE"
  tags                        = local.common_tags
}

# ECR — private container registry for the platform and apps.
# Creates repos for platform/, observability/, apps/<service>, tools/.
# Wires up four auth models: Pod Identity (workloads), GitHub OIDC (CI),
# EC2 instance role (kubelet), and a per-namespace pull secret (fallback).
module "aws_ecr" {
  source = "./modules/aws-ecr"

  environment           = var.environment
  cluster_name          = module.aws_eks.cluster_name
  cluster_oidc_issuer_url = module.aws_eks.cluster_oidc_issuer_url
  node_role_name        = module.aws_eks.node_role_name

  github_org   = var.github_org
  github_repos = var.github_repos

  kms_key_arn = module.kms.key_arn

  # App repos — set per environment in the env wrapper. Sandbox is
  # empty by default; add names here as teams onboard.
  app_repositories = var.app_repositories

  # K8s docker-registry secrets are managed by the ansible bootstrap
  # role, not Terraform, so this module works on a greenfield cluster.
  create_k8s_pull_secrets = false

  tags = local.common_tags

  depends_on = [module.aws_eks]
}

# --- Future phases (stubs) ---
# module "azure_vnet"  { source = "./modules/azure-vnet"  count = var.enable_azure ? 1 : 0 }
# module "gcp_vpc"     { source = "./modules/gcp-vpc"     count = var.enable_gcp  ? 1 : 0 }
