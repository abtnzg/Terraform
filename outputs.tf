# ============================================================================
# Root Outputs
# ============================================================================
# Outputs are namespaced by purpose. Avoid dumping internal module values.
# ----------------------------------------------------------------------------

output "vpc_id" {
  description = "Management VPC ID."
  value       = module.aws_vpc.vpc_id
}

output "vpc_cidr" {
  description = "Management VPC CIDR."
  value       = module.aws_vpc.vpc_cidr
}

output "private_subnet_ids" {
  description = "Private subnet IDs (for spokes to peer with)."
  value       = module.aws_vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs (for ALBs/NAT)."
  value       = module.aws_vpc.public_subnet_ids
}

output "eks_cluster_name" {
  description = "EKS management cluster name."
  value       = module.aws_eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API endpoint."
  value       = module.aws_eks.cluster_endpoint
  sensitive   = true
}

output "eks_oidc_provider_arn" {
  description = "OIDC issuer ARN (for Pod Identity / IRSA). Surfaced from the EKS module."
  value       = module.aws_eks.cluster_oidc_issuer_url
}

output "kms_key_arn" {
  description = "KMS key for cluster + secrets encryption."
  value       = module.kms.key_arn
}

output "aws_storage_sizing" {
  description = "Sizing profile values surfaced from the storage module — consumed as SIZING_* envsubst vars at helmfile render time (StorageClass IOPS/throughput)."
  value       = module.aws_storage.sizing
}

output "efs_file_system_id" {
  description = "EFS file system ID for the shared RWX volume."
  value       = module.aws_storage.efs_file_system_id
}

output "efs_access_point_id" {
  description = "EFS access point ID (the platform default AP)."
  value       = module.aws_storage.efs_access_point_id
}

output "s3_csi_bucket_name" {
  description = "S3 bucket name for the Mountpoint S3 CSI driver."
  value       = module.aws_storage.s3_bucket_name
}

output "s3_csi_bucket_arn" {
  description = "S3 bucket ARN for the Mountpoint S3 CSI driver."
  value       = module.aws_storage.s3_bucket_arn
}

# --- ECR ---
output "ecr_registry_url" {
  description = "ECR registry URL (e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com). Used in helmfile values and CI config."
  value       = module.aws_ecr.registry_url
}

output "ecr_repository_arns" {
  description = "Map of repository name to ARN (for IAM policies, CI, or downstream consumers)."
  value       = module.aws_ecr.repository_arns
}

output "ecr_github_actions_role_arn" {
  description = "IAM role ARN that GitHub Actions assumes to push/pull images. Set as `role-to-assume` in your workflow."
  value       = module.aws_ecr.github_actions_role_arn
}

output "ecr_workload_pull_role_arns" {
  description = "Map of namespace to Pod Identity role ARN for ECR pull. Bind via `eks_pod_identity_association` or annotate the namespace's default SA."
  value       = module.aws_ecr.workload_pull_role_arns
}
