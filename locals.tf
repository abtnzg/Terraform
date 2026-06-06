# ============================================================================
# Root Locals
# ============================================================================
# Computed values shared across modules. Naming convention:
#   <env>-<service>-<region-short>-<owner>
# Example: dev-mgmt-eks-use1-platform
# ----------------------------------------------------------------------------

locals {
  name_prefix = "${var.environment}-platform"

  # Common tags merged with provider default_tags.
  common_tags = {
    Project     = "platform-fleet"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Compliance  = join(",", var.compliance_frameworks)
  }

  # AZ names for the chosen region.
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Whether the environment requires FedRAMP hardening.
  is_fedramp = contains(var.compliance_frameworks, "fedramp")
  is_hipaa   = contains(var.compliance_frameworks, "hipaa")
  is_pci     = contains(var.compliance_frameworks, "pci")

  # -----------------------------------------------------------------------
  # Sizing profile — small set of numbers, surfaced once, used everywhere.
  # One switch in tfvars flips the whole stack. See ADR-0011.
  # -----------------------------------------------------------------------
  sizing = {
    sandbox = {
      # EKS bootstrap MNG — Karpenter + coredns + kube-proxy + 1-2 platform pods
      # Updated 2026-06-05: bumped to t3.medium only (was t3.small/t3.medium
      # mix) and 5 nodes (was 2 desired / 3 max). The full platform stack
      # (Kyverno + ArgoCD + Argo Workflows + OTel + cert-manager + ESO +
      # Vault + Gatekeeper + Karpenter + Prometheus/Grafana) needs ~30+
      # pods of headroom; t3.small hits its 17-pod ceiling almost
      # immediately and pods stack up in Pending.
      node_instance_types = ["t3.medium"]
      node_min_size       = 3
      node_max_size       = 6
      node_desired_size   = 5
      node_disk_size      = 30

      # EBS StorageClasses
      gp3_default_iops          = 1000
      gp3_default_throughput    = 50
      gp3_throughput_iops       = 1500
      gp3_throughput_throughput = 100
      io2_iops                  = 1000
      gp2_disabled              = true # we still ship only gp3/io2, but flag for policy

      # EFS
      efs_throughput_mode = "bursting" # no provisioned/elastic, cheapest

      # S3
      s3_object_lock_enabled = false
      s3_lifecycle_to_ia     = false # skip INTELLIGENT_TIERING
      s3_lifecycle_days      = 0     # 0 = no transition rule

      # CloudWatch log retention
      log_retention_days = 7

      # Karpenter NodePool limits
      default_spot_cpu_limit       = 40
      default_spot_memory_limit_gi = 80
      default_od_cpu_limit         = 20
      default_od_memory_limit_gi   = 40
      batch_cpu_limit              = 80
      batch_memory_limit_gi        = 160
      system_cpu_limit             = 8
      system_memory_limit_gi       = 16
    }

    standard = {
      node_instance_types = ["m6i.xlarge", "m6a.xlarge", "m7i.xlarge"]
      node_min_size       = 3
      node_max_size       = 6
      node_desired_size   = 3
      node_disk_size      = 100

      gp3_default_iops          = 3000
      gp3_default_throughput    = 125
      gp3_throughput_iops       = 4000
      gp3_throughput_throughput = 1000
      io2_iops                  = 16000

      efs_throughput_mode = "elastic"
      gp2_disabled = true # we still ship only gp3/io2, but flag for policy
      s3_object_lock_enabled = false
      s3_lifecycle_to_ia     = true
      s3_lifecycle_days      = 30

      log_retention_days = 30

      default_spot_cpu_limit       = 1000
      default_spot_memory_limit_gi = 4000
      default_od_cpu_limit         = 500
      default_od_memory_limit_gi   = 2000
      batch_cpu_limit              = 2000
      batch_memory_limit_gi        = 8000
      system_cpu_limit             = 32
      system_memory_limit_gi       = 128
    }

    production = {
      node_instance_types = ["m6i.xlarge", "m6a.xlarge", "m7i.xlarge"]
      node_min_size       = 6
      node_max_size       = 20
      node_desired_size   = 6
      node_disk_size      = 200

      gp3_default_iops          = 3000
      gp3_default_throughput    = 125
      gp3_throughput_iops       = 4000
      gp3_throughput_throughput = 1000
      io2_iops                  = 16000
      gp2_disabled = true # we still ship only gp3/io2, but flag for policy
      efs_throughput_mode = "elastic"

      s3_object_lock_enabled = true # gated separately by compliance in module
      s3_lifecycle_to_ia     = true
      s3_lifecycle_days      = 30

      log_retention_days = 365

      default_spot_cpu_limit       = 1000
      default_spot_memory_limit_gi = 4000
      default_od_cpu_limit         = 500
      default_od_memory_limit_gi   = 2000
      batch_cpu_limit              = 2000
      batch_memory_limit_gi        = 8000
      system_cpu_limit             = 32
      system_memory_limit_gi       = 128
    }
  }[var.sizing_profile]
}

data "aws_availability_zones" "available" {
  state = "available"
}
