# ============================================================================
# Per-Environment Backend
# ============================================================================
# Each environment has its own S3 prefix and DynamoDB lock table.
# State is never shared across environments.
# ----------------------------------------------------------------------------

terraform {
  backend "s3" {
    # Filled in by `terraform init -backend-config=...` or env vars.
    # Example:
    #   bucket         = "platform-tfstate-${var.environment}-${data.aws_caller_identity.current.account_id}"
    #   key            = "platform-fleet/${var.environment}/terraform.tfstate"
    #   region         = "us-east-1"
    #   dynamodb_table = "platform-tflock-${var.environment}"
    #   encrypt        = true
    #   kms_key_id     = "alias/platform-tfstate-${var.environment}"
  }
}
