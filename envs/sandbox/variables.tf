# ============================================================================
# Per-Environment Variables
# ============================================================================
# Re-declared here so the `terraform.tfvars` in this directory is read at the
# root-module scope. The `module "platform"` block in main.tf forwards each
# one to the `platform-fleet/` root.
# ----------------------------------------------------------------------------

variable "environment" {
  type    = string
  default = "sandbox"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "sizing_profile" {
  type    = string
  default = "sandbox"
}

variable "vpc_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "enable_azure" {
  type    = bool
  default = false
}

variable "enable_gcp" {
  type    = bool
  default = false
}

variable "eks_cluster_version" {
  type    = string
  default = "1.31"
}

variable "eks_node_instance_types" {
  type    = list(string)
  default = null
}

variable "github_org" {
  type = string
}

variable "github_repos" {
  type    = list(string)
  default = ["platform-fleet", "gitops-fleet", "gitops-apps", "policies"]
}

variable "compliance_frameworks" {
  type    = list(string)
  default = []
}

variable "app_repositories" {
  description = "ECR application repository names to create under the apps/ prefix. One entry per microservice."
  type        = list(string)
  default     = []
}
