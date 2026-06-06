# ============================================================================
# Dev Environment
# ============================================================================
# Single region (us-east-1), standard sizing, no compliance frameworks.
# ----------------------------------------------------------------------------

environment        = "dev"
aws_region         = "us-east-1"
sizing_profile     = "standard"

vpc_cidr           = "10.10.0.0/16"
az_count           = 3
enable_azure       = false
enable_gcp         = false
compliance_frameworks = []

eks_cluster_version   = "1.31"
# node_min/max/desired_size + node_disk_size are driven by sizing_profile
# in locals.tf. Override here only for a one-off custom instance mix.

github_org = "your-org"
github_repos = [
  "platform-fleet",
  "gitops-fleet",
  "gitops-apps",
  "policies",
]
