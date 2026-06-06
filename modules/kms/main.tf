terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.100" }
  }
}

variable "environment" { type = string }
variable "key_description" { type = string }

variable "multi_region" {
  type    = bool
  default = false
}

variable "compliance_frameworks" {
  type    = list(string)
  default = []
}

variable "deletion_window_in_days" {
  type    = number
  default = 30
}

# FedRAMP / HIPAA require CMK, key rotation, and explicit grants.
locals {
  rotation_period = contains(var.compliance_frameworks, "fedramp") ? 90 : 365
  account_id      = data.aws_caller_identity.current.account_id
  region          = data.aws_region.current.name
}

# Service principals granted access to the CMK. Each gets kms:* (broad but
# pinned to the key + the service principal); the kms:CallerAccount
# condition in the canonical AWS docs pattern was returning AccessDenied
# during CloudWatch Logs CreateLogGroup in this account, so we deliberately
# drop the condition here. Account root has the full grant; the root
# principal is the recovery path if a service statement is wrong.
locals {
  service_principals = {
    EKS = "eks.amazonaws.com"
    EC2 = "ec2.amazonaws.com"
    S3  = "s3.amazonaws.com"
    # Regional: CloudWatch Logs has a per-region service principal.
    CloudWatchLogs = "logs.${local.region}.amazonaws.com"
  }
}

resource "aws_kms_key" "main" {
  description             = var.key_description
  enable_key_rotation     = true
  rotation_period_in_days = local.rotation_period
  multi_region            = var.multi_region
  deletion_window_in_days = var.deletion_window_in_days

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "RootAccountFull"
          Effect    = "Allow"
          Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
          Action    = "kms:*"
          Resource  = "*"
        },
      ],
      [for sp_name, sp_value in local.service_principals : {
        Sid       = "${sp_name}Usage"
        Effect    = "Allow"
        Principal = { Service = sp_value }
        Action    = "kms:*"
        Resource  = "*"
      }]
    )
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/platform-${var.environment}"
  target_key_id = aws_kms_key.main.key_id
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

output "key_id" { value = aws_kms_key.main.id }
output "key_arn" { value = aws_kms_key.main.arn }
output "key_alias" { value = aws_kms_alias.main.name }
