terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.34"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.2"
    }
  }

  # Remote backend configuration is per-environment.
  # Each envs/<env>/backend.tf points to its own S3 key + DynamoDB lock.
}
