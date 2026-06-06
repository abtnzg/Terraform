# ============================================================================
# Sandbox Environment
# ============================================================================
# A small but real cluster for the test/sandbox AWS account. Driven by the
# `sizing_profile = "sandbox"` switch (ADR-0011):
#   - t3.medium bootstrap MNG, 3-6 nodes (desired 5), 30 GB disk
#   - gp3 1000 IOPS / 50 MB/s default
#   - EFS bursting (cheapest throughput mode)
#   - S3 without Object-Lock and without INTELLIGENT_TIERING transitions
#   - CloudWatch log retention: 7 days
#   - Vault in dev mode (in-memory, no Raft, no KMS auto-unseal)
#   - Karpenter ships only the `system` pool (1-2 nodes, t3 family)
#   - All platform controllers (Kyverno, ArgoCD, Argo Workflows, OTel,
#     cert-manager, external-secrets, gatekeeper) at 1 replica
#
# Cost ceiling: ~$500/month per cluster at 5x t3.medium (excluding
# data transfer and EBS/EFS storage).
# ----------------------------------------------------------------------------

environment        = "sandbox"
aws_region         = "us-east-1"
sizing_profile     = "sandbox"

# Tiny instance types — guaranteed to be available in every AWS account
# without quota increase. Sandbox profile (locals.tf) sets t3.medium × 5;
# we override here only to lock the instance type to a single SKUs
# (no mixed t3.small/t3.medium fleet) so Karpenter's instance-type
# selection is deterministic.
eks_node_instance_types = ["t3.medium"]

# node_min/max/desired_size are driven by the sandbox sizing profile in
# locals.tf (currently 3/6/5). Override here only for one-off custom sizing.
vpc_cidr           = "10.50.0.0/16"
az_count           = 2
enable_azure       = false
enable_gcp         = false
compliance_frameworks = []

eks_cluster_version   = "1.31"

github_org = "your-org"
github_repos = [
  "platform-fleet",
  "gitops-fleet",
  "gitops-apps",
  "policies",
]

# ECR application repositories — one per service the team owns.
# Names become ECR repository paths under `apps/`.
app_repositories = [
  "service-a",
]
