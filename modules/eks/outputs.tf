output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.main.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.main.arn
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "EKS Kubernetes version."
  value       = aws_eks_cluster.main.version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the cluster."
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA / Pod Identity."
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "cluster_security_group_id" {
  description = "Cluster control-plane security group."
  value       = aws_security_group.cluster.id
}

output "node_role_arn" {
  description = "IAM role ARN used by the managed node group (also reused for Karpenter nodes)."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "IAM role name used by the managed node group."
  value       = aws_iam_role.node.name
}

output "node_security_group_ids" {
  description = "Security groups attached to MNG nodes (Karpenter-launched nodes reuse these)."
  # The MNG doesn't expose a security_group_ids attribute in this
  # resource shape — we hardcode the cluster SG and any additional
  # SGs via `additional_cluster_security_group_ids` (none in phase 0).
  # The cluster SG is what the kubelet ingress rule binds to.
  value = [aws_security_group.cluster.id]
}

output "node_subnet_ids" {
  description = "Subnet IDs the MNG runs in (Karpenter-launched nodes reuse these via the discovery tag)."
  value       = aws_eks_node_group.main.subnet_ids
}

output "github_actions_role_arn" {
  description = "IAM role assumed by GitHub Actions via OIDC for CI/CD."
  value       = aws_iam_role.github_oidc.arn
}
