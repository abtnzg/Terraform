# ============================================================================
# AWS Storage Module — EFS, S3, KMS, Pod Identity for the 3 CSI drivers
# ----------------------------------------------------------------------------
# What this module owns (the AWS side of CSI):
#
#   - aws_efs_file_system          : encrypted EFS for ReadWriteMany volumes
#   - aws_efs_mount_target × N     : one per private subnet
#   - aws_efs_access_point × N     : per-tenant access points (POSIX user
#                                    enforcement — no shared root)
#   - aws_s3_bucket                : shared bucket for the S3 Mountpoint CSI
#                                    driver (per-team prefixes via IAM)
#   - aws_iam_role × 3             : EBS / EFS / S3 controller roles, bound
#                                    via EKS Pod Identity associations
#
# What this module does NOT own (CSI driver Helm releases live in helmfile,
# StorageClasses live in mgmt-cluster-aws/apps/storage/):
#   - the CSI driver Deployments/DaemonSets
#   - StorageClass / VolumeSnapshotClass / VolumeAttributesClass
#   - per-tenant PVCs
#
# See ADR-0010 for the storage strategy.
# ============================================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.100" }
  }
}

# --- Inputs ---
variable "cluster_name" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "node_security_group_id" {
  description = "SG of the worker nodes; the EFS mount targets allow NFS from this SG."
  type        = string
}
variable "kms_key_id" {
  description = "CMK used to encrypt EFS, S3, and EBS volumes provisioned by the drivers."
  type        = string
}
variable "kms_key_arn" { type = string }
variable "compliance_frameworks" {
  type    = list(string)
  default = ["arn:aws:kms:us-east-1:059200471385:key/ec573fe4-96e7-4e69-87ea-3a4918508703"]
}
variable "sizing" {
  description = "Sizing profile object from the root locals — drives EFS throughput mode, S3 lifecycle, etc."
  type = object({
    node_instance_types          = list(string)
    node_min_size                = number
    node_max_size                = number
    node_desired_size            = number
    node_disk_size               = number
    gp3_default_iops             = number
    gp3_default_throughput       = number
    gp3_throughput_iops          = number
    gp3_throughput_throughput    = number
    io2_iops                     = number
    gp2_disabled                 = bool
    efs_throughput_mode          = string
    s3_object_lock_enabled       = bool
    s3_lifecycle_to_ia           = bool
    s3_lifecycle_days            = number
    log_retention_days           = number
    default_spot_cpu_limit       = number
    default_spot_memory_limit_gi = number
    default_od_cpu_limit         = number
    default_od_memory_limit_gi   = number
    batch_cpu_limit              = number
    batch_memory_limit_gi        = number
    system_cpu_limit             = number
    system_memory_limit_gi       = number
  })
}
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ----------------------------------------------------------------------------
# 1. EFS — multi-AZ file system + access points
# ----------------------------------------------------------------------------
# Encryption at rest (CMK) + encryption in transit (enforced at the
# StorageClass via mountOptions: ["tls"]).
# Lifecycle: hot data on the IA class after 30 days idle, archive after 90d.

resource "aws_efs_file_system" "shared" {
  creation_token = "${var.cluster_name}-shared"
  encrypted      = true
  kms_key_id     = var.kms_key_arn

  performance_mode = "generalPurpose"
  # Sandbox: bursting is the cheapest mode (no per-GB/month fee on top of
  # storage). Standard/prod: elastic (scales with workload, no provisioned
  # throughput cap to design around).
  throughput_mode = var.sizing.efs_throughput_mode

  # EFS lifecycle:
  #   - IA after 30d idle: supported on bursting + elastic + provisioned.
  #   - Archive after 90d idle: ONLY on elastic + provisioned. Bursting
  #     rejects it ("ThroughputMode does not support TransitionToArchive"),
  #     so the transition_to_archive block is gated on throughput mode.
  #   - Back to primary after 1 access: supported on every mode.
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  dynamic "lifecycle_policy" {
    for_each = var.sizing.efs_throughput_mode == "elastic" || var.sizing.efs_throughput_mode == "provisioned" ? [1] : []
    content {
      transition_to_archive = "AFTER_90_DAYS"
    }
  }
  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-efs-shared"
  })
}

# Backup policy on by default — AWS Backup picks it up via tag
# `aws-backup:enabled=true` (set in the default tags at the provider level).
resource "aws_efs_backup_policy" "shared" {
  file_system_id = aws_efs_file_system.shared.id

  backup_policy {
    status = "ENABLED"
  }
}

# Mount target per private subnet — EFS needs one per AZ for the driver to
# resolve the local IP. NFS port 2049 is locked to the worker node SG only.
resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs-mount"
  description = "EFS mount targets: NFS from worker nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from EKS nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-efs-sg" })
}

locals {
  efs_subnets = {
    for idx, subnet_id in var.private_subnet_ids :
    "subnet-${idx}" => subnet_id
  }
}

resource "aws_efs_mount_target" "shared" {
  for_each = local.efs_subnets

  file_system_id  = aws_efs_file_system.shared.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# Default access point: per-tenant access points get layered on top via the
# tenant onboarding script. This one is the platform's "shared scratch" AP
# (root squashed, POSIX 1000:1000, scoped to /platform).
resource "aws_efs_access_point" "platform" {
  file_system_id = aws_efs_file_system.shared.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/platform"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-efs-ap-platform" })
}

# ----------------------------------------------------------------------------
# 2. S3 — Mountpoint CSI bucket
# ----------------------------------------------------------------------------
# Why S3 CSI: large read-mostly datasets (ML model weights, batch fixtures,
# observability cold storage) that don't justify an EBS-per-pod. Mountpoint
# is read-optimised; for writes it appends, no random-write — that's by
# design and a feature, not a bug.

resource "aws_s3_bucket" "csi" {
  bucket = "${var.cluster_name}-csi-shared"

  # block-public-access is the bucket-level lock; the public-access-block
  # resource below sets the policy.
  tags = merge(var.tags, { Name = "${var.cluster_name}-csi-shared" })
}

resource "aws_s3_bucket_public_access_block" "csi" {
  bucket                  = aws_s3_bucket.csi.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "csi" {
  bucket = aws_s3_bucket.csi.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "csi" {
  bucket = aws_s3_bucket.csi.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

# HIPAA / FedRAMP: object lock for compliance retention (WORM, 7y).
# Sandbox: skipped regardless of compliance — the test account doesn't need
# the WORM overhead, and Object-Lock cannot be removed once set, so the
# bucket would carry the constraint forever.
resource "aws_s3_bucket_object_lock_configuration" "csi" {
  count = (
    !var.sizing.s3_object_lock_enabled
    ) ? 0 : (
    contains(var.compliance_frameworks, "hipaa") || contains(var.compliance_frameworks, "fedramp")
  ) ? 1 : 0

  bucket = aws_s3_bucket.csi.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 2557 # 7 years
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "csi" {
  bucket = aws_s3_bucket.csi.id

  rule {
    id     = "tiering"
    status = "Enabled"
    filter {}

    # Sandbox: no transition (skip INTELLIGENT_TIERING, skip the
    # noncurrent_version_expiration noise). Standard/prod: 30-day
    # transition, 90-day noncurrent expiry.
    dynamic "transition" {
      for_each = var.sizing.s3_lifecycle_to_ia ? [1] : []
      content {
        days          = var.sizing.s3_lifecycle_days
        storage_class = "INTELLIGENT_TIERING"
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Deny anything that's not encrypted-in-transit or not using the CMK
resource "aws_s3_bucket_policy" "csi" {
  bucket = aws_s3_bucket.csi.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.csi.arn,
          "${aws_s3_bucket.csi.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid       = "DenyWrongKmsKey"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.csi.arn}/*"
        Condition = {
          StringNotEqualsIfExists = {
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = var.kms_key_arn
          }
        }
      },
    ]
  })
}

# ----------------------------------------------------------------------------
# 3. Pod Identity IAM — one role per CSI controller
# ----------------------------------------------------------------------------
# All three drivers ship with their own SA. We bind a least-privilege role
# to each via EKS Pod Identity (no IRSA, no kiam).

data "aws_iam_policy_document" "csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# --- EBS CSI controller -----------------------------------------------------
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.csi_assume.json
  tags               = var.tags
}

# AWS-managed policy is fine — Amazon maintains it and we'd otherwise be
# tracking 30+ EC2 actions ourselves. Scope is the cluster's region only.
resource "aws_iam_role_policy_attachment" "ebs_csi_managed" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Extra inline policy: kms:Encrypt/Decrypt/GenerateDataKey on the cluster CMK
# (the managed policy only covers AWS-managed keys).
resource "aws_iam_role_policy" "ebs_csi_kms" {
  name = "kms-cluster-cmk"
  role = aws_iam_role.ebs_csi.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant",
        ]
        Resource = var.kms_key_arn
        Condition = {
          Bool = { "kms:GrantIsForAWSResource" = "true" }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

# --- EFS CSI controller -----------------------------------------------------
resource "aws_iam_role" "efs_csi" {
  name               = "${var.cluster_name}-efs-csi"
  assume_role_policy = data.aws_iam_policy_document.csi_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi_managed" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_iam_role_policy" "efs_csi_scope" {
  name = "efs-this-cluster-only"
  role = aws_iam_role.efs_csi.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:DescribeAccessPoints",
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:CreateAccessPoint",
          "elasticfilesystem:DeleteAccessPoint",
          "elasticfilesystem:TagResource",
        ]
        Resource = "arn:aws:elasticfilesystem:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:file-system/${aws_efs_file_system.shared.id}"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:CreateAccessPoint",
          "elasticfilesystem:DeleteAccessPoint",
        ]
        Resource = "arn:aws:elasticfilesystem:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:access-point/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "efs_csi" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-controller-sa"
  role_arn        = aws_iam_role.efs_csi.arn
}

# --- Mountpoint S3 CSI driver ----------------------------------------------
resource "aws_iam_role" "s3_csi" {
  name               = "${var.cluster_name}-s3-csi"
  assume_role_policy = data.aws_iam_policy_document.csi_assume.json
  tags               = var.tags
}

# Scoped to the CSI bucket only. The bucket policy adds a second layer of
# defence (denies wrong-CMK writes regardless of who the caller is).
resource "aws_iam_role_policy" "s3_csi" {
  name = "mountpoint-csi"
  role = aws_iam_role.s3_csi.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MountpointFullBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = aws_s3_bucket.csi.arn
      },
      {
        Sid    = "MountpointObjectIO"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.csi.arn}/*"
      },
      {
        Sid    = "KmsForS3"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = var.kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "s3_csi" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "s3-csi-driver-sa"
  role_arn        = aws_iam_role.s3_csi.arn
}

# ----------------------------------------------------------------------------
# 4. EBS-volume CMK grant
# ----------------------------------------------------------------------------
# When the EBS driver provisions a volume with the cluster CMK, it needs an
# AWS-side grant so the EC2 service can use the key when attaching. The
# driver requests this grant automatically once `kms:CreateGrant` is in the
# inline policy above — nothing else to wire here.

# --- Outputs ---
output "efs_file_system_id" { value = aws_efs_file_system.shared.id }
output "efs_access_point_id" { value = aws_efs_access_point.platform.id }
output "s3_bucket_name" { value = aws_s3_bucket.csi.id }
output "s3_bucket_arn" { value = aws_s3_bucket.csi.arn }
output "ebs_csi_role_arn" { value = aws_iam_role.ebs_csi.arn }
output "efs_csi_role_arn" { value = aws_iam_role.efs_csi.arn }
output "s3_csi_role_arn" { value = aws_iam_role.s3_csi.arn }

# Sizing values — surfaced so the StorageClass yamls (which Helmfile renders
# as plain YAML after envsubst) can read them via envsubst. The bootstrap
# script exports SIZING_GP3_DEFAULT_IOPS etc. before running helmfile.
output "sizing" {
  description = "Sizing profile values, surfaced as envsubst-friendly names for StorageClass rendering."
  value = {
    gp3_default_iops          = var.sizing.gp3_default_iops
    gp3_default_throughput    = var.sizing.gp3_default_throughput
    gp3_throughput_iops       = var.sizing.gp3_throughput_iops
    gp3_throughput_throughput = var.sizing.gp3_throughput_throughput
    io2_iops                  = var.sizing.io2_iops
  }
}
