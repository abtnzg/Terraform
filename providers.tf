# ============================================================================
# Multi-Cloud Provider Configuration
# ----------------------------------------------------------------------------
# Each environment enables only the providers it needs via enable_* flags.
# Cross-cloud identity uses OIDC federation (no long-lived keys).
# ============================================================================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "platform-fleet"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = "platform-team"
      Compliance  = join(",", var.compliance_frameworks)
    }
  }
}

# Conditional providers are gated via module composition in main.tf, not
# via `count` on the provider block. See main.tf for the multi-cloud
# module structure (azure-vnet, gcp-vpc added in phase 2/3).

# ----------------------------------------------------------------------------
# Kubernetes / Helm providers
# ----------------------------------------------------------------------------
# The ../../platform-fleet/ root module is invoked AS A CHILD by each
# envs/<env>/ directory. As a child, it cannot declare its own
# provider "kubernetes" or provider "helm" — those are owned by the
# real root (envs/<env>/main.tf) and passed in via the providers =
# { ... } meta-argument on the module call.
#
# When you want to run `terraform plan` directly from this directory
# (rare; mainly for module-level unit tests), uncomment the blocks
# below — but be aware they'll conflict with the env wrapper's
# override.
# ----------------------------------------------------------------------------

