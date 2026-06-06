# ============================================================================
# Backend bootstrap (one-time per environment)
# ============================================================================
# Creates the S3 bucket, DynamoDB lock table, and KMS key for state encryption.
# Run this once before `terraform init` in the envs/<env>/ directory.
# ----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.100" }
  }
}

variable "environment" { type = string }

resource "aws_s3_bucket" "tfstate" {
  bucket = "platform-tfstate-${var.environment}-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "tfstate" {
  bucket        = aws_s3_bucket.tfstate.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "tfstate/${var.environment}/"
}

resource "aws_s3_bucket" "logs" {
  bucket = "platform-tfstate-logs-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_kms_key" "tfstate" {
  description             = "KMS key for Terraform state (${var.environment})"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_dynamodb_table" "tflock" {
  name         = "platform-tflock-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

data "aws_caller_identity" "current" {}

output "bucket" { value = aws_s3_bucket.tfstate.bucket }
output "region" { value = "us-east-1" }
output "lock_tbl" { value = aws_dynamodb_table.tflock.name }
output "kms_arn" { value = aws_kms_key.tfstate.arn }
