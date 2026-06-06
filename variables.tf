# ============================================================================
# Root Variables
# ============================================================================
# All variables are validated. Sensitive values must come from a secret store
# (AWS Secrets Manager / Azure Key Vault / HashiCorp Vault) — never committed.
# ----------------------------------------------------------------------------

variable "environment" {
  description = "Environment name. Drives naming, sizing, and policy. `sandbox` is the test/sandbox AWS account; sizing comes from the sandbox profile (ADR-0011)."
  type        = string

  validation {
    condition     = contains(["sandbox", "dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: sandbox, dev, staging, prod."
  }
}

# --- Sizing profile ---
# `sandbox`  : tiny footprint for the test/sandbox AWS account.
#              t3.small / t3.medium, 2 AZs, 1–3 nodes, gp3 1000 IOPS,
#              EFS bursting only, no Object-Lock, no lifecycle IA transitions,
#              CloudWatch log retention 7 days, all platform controllers at 1
#              replica, Vault in dev mode.
#              Cost ceiling ~$300/month per cluster.
# `standard` : the dev/staging default. m6i/m6a/m7i xlarge, 3 AZs, 3–6 nodes,
#              gp3 3000 IOPS, EFS elastic throughput, full platform stack.
#              Cost ceiling ~$1,500/month per cluster.
# `production` : full prod sizing. m6i/m6a/m7i xlarge, 3 AZs, 6–20 nodes,
#                gp3 3000 IOPS / io2 16000 IOPS, EFS elastic, full stack HA.
#                Cost ceiling ~$4,500/month per cluster.
variable "sizing_profile" {
  description = "Sizing profile. Drives node count, IOPS, replica counts, log retention."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["sandbox", "standard", "production"], var.sizing_profile)
    error_message = "sizing_profile must be one of: sandbox, standard, production."
  }
}

variable "aws_region" {
  description = "Primary AWS region for the management cluster."
  type        = string
  default     = "us-east-1"
}

# --- Multi-cloud toggles ---
variable "enable_azure" {
  description = "Enable Azure provider (sets up AKS in future phases)."
  type        = bool
  default     = false
}

variable "enable_gcp" {
  description = "Enable GCP provider (sets up GKE in future phases)."
  type        = bool
  default     = false
}

variable "azure_subscription_id" {
  description = "Azure subscription ID."
  type        = string
  default     = ""
}

variable "azure_tenant_id" {
  description = "Azure AD tenant ID."
  type        = string
  default     = ""
}

variable "gcp_project_id" {
  description = "GCP project ID."
  type        = string
  default     = ""
}

variable "gcp_region" {
  description = "GCP region."
  type        = string
  default     = "us-central1"
}

# --- Compliance ---
variable "compliance_frameworks" {
  description = "Compliance frameworks this environment must satisfy. Drives policy bundles, retention, and encryption."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for f in var.compliance_frameworks :
      contains(["soc2", "iso27001", "hipaa", "pci", "fedramp", "gdpr"], f)
    ])
    error_message = "Allowed frameworks: soc2, iso27001, hipaa, pci, fedramp, gdpr."
  }
}

# --- Networking ---
variable "vpc_cidr" {
  description = "CIDR for the management VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to spread the cluster across (2 or 3)."
  type        = number
  default     = 3

  validation {
    condition     = contains([2, 3], var.az_count)
    error_message = "az_count must be 2 or 3."
  }
}

# --- EKS sizing ---
variable "eks_cluster_version" {
  description = "Kubernetes version for the management EKS cluster."
  type        = string
  default     = "1.31"
}

variable "eks_node_instance_types" {
  description = "Instance types for the EKS managed node group. Default comes from locals.sizing based on sizing_profile — override only for one-off custom instance mixes."
  type        = list(string)
  default     = null
}

# --- Bootstrap ---
variable "github_org" {
  description = "GitHub org that owns the platform repos. Used for OIDC."
  type        = string
}

variable "github_repos" {
  description = "Repos granted OIDC access to AWS."
  type        = list(string)
  default     = ["platform-fleet", "gitops-fleet", "gitops-apps", "policies"]
}

variable "app_repositories" {
  description = "ECR repository names to create under the apps/ prefix. One entry per microservice the team owns (e.g. [\"service-a\", \"payments-api\"]). Each becomes a separate ECR repository."
  type        = list(string)
  default     = []
}
