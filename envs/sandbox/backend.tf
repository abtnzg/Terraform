# Local backend for plan-only validation. The bootstrap script replaces
# this with the real S3 backend at apply time.
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
