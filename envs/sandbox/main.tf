# ============================================================================
# Per-Environment Root Module
# ============================================================================
# This file lives in envs/<env>/. It re-exposes the variables that the
# root `platform-fleet/` module needs and instantiates it as a child.
# Variables come from `terraform.tfvars` in the same directory.
# ----------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "platform-fleet"
      ManagedBy = "Terraform"
    }
  }
}

module "platform" {
  source = "../../"

  # Identity
  environment    = var.environment
  aws_region     = var.aws_region
  sizing_profile = var.sizing_profile
  github_org     = var.github_org
  github_repos   = var.github_repos

  # Cloud toggles
  enable_azure = var.enable_azure
  enable_gcp   = var.enable_gcp

  # Networking
  vpc_cidr = var.vpc_cidr
  az_count = var.az_count

  # EKS
  eks_cluster_version   = var.eks_cluster_version
  eks_node_instance_types = var.eks_node_instance_types

  # Compliance
  compliance_frameworks = var.compliance_frameworks

  # ECR app repositories — one ECR repo per microservice the team owns.
  app_repositories = var.app_repositories
}
