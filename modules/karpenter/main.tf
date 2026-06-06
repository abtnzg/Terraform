# ============================================================================
# AWS Karpenter Module — IAM, SQS interruption queue, EventBridge wiring
# ----------------------------------------------------------------------------
# Karpenter replaces Cluster Autoscaler. It provisions EC2 instances on-demand
# from in-cluster NodePool/EC2NodeClass CRDs, packs pods more tightly, and
# consolidates underutilised nodes. See ADR-0009 for the rationale.
#
# This module sets up the AWS side:
#   - KarpenterController IAM role (assumed via EKS Pod Identity)
#   - KarpenterNode IAM role + instance profile (attached to launched EC2s)
#   - SQS queue for spot interruption / instance state-change events
#   - EventBridge rules forwarding the interruption events into the queue
#   - Tags on subnets and security groups so EC2NodeClass.subnetSelector and
#     securityGroupSelector can discover them
#
# The Karpenter controller itself is installed via Helm; NodePools and
# EC2NodeClasses live in `mgmt-cluster-aws/apps/karpenter/`.
# ============================================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.100" }
  }
}

# --- Inputs ---
variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "node_role_name" {
  description = "Existing managed-node-group IAM role; Karpenter nodes reuse it (single role keeps aws-auth simple)."
  type        = string
}
variable "private_subnet_ids" { type = list(string) }
variable "cluster_security_group_id" { type = string }
variable "additional_node_security_group_ids" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ----------------------------------------------------------------------------
# 1. SQS interruption queue + EventBridge rules
# ----------------------------------------------------------------------------
# Karpenter listens on this queue for:
#   - Spot interruption warnings (2-minute grace)
#   - Scheduled maintenance events
#   - Instance state-change notifications (stopped, terminated, etc.)
# When a message arrives Karpenter drains the node and provisions a replacement
# before the instance is reclaimed.

resource "aws_sqs_queue" "interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-karpenter-interruption" })
}

data "aws_iam_policy_document" "interruption_queue" {
  statement {
    sid     = "EventsToSQS"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    principals {
      type = "Service"
      identifiers = [
        "events.amazonaws.com",
        "sqs.amazonaws.com",
      ]
    }
    resources = [aws_sqs_queue.interruption.arn]
  }
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.id
  policy    = data.aws_iam_policy_document.interruption_queue.json
}

locals {
  eb_rules = {
    spot_interruption = {
      source      = "aws.ec2"
      detail_type = "EC2 Spot Instance Interruption Warning"
    }
    rebalance_recommendation = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance Rebalance Recommendation"
    }
    scheduled_change = {
      source      = "aws.health"
      detail_type = "AWS Health Event"
    }
    state_change = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance State-change Notification"
    }
  }
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.eb_rules

  name        = "${var.cluster_name}-karpenter-${each.key}"
  description = "Karpenter — ${each.value.detail_type}"
  event_pattern = jsonencode({
    source      = [each.value.source]
    detail-type = [each.value.detail_type]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.eb_rules

  rule      = aws_cloudwatch_event_rule.this[each.key].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.interruption.arn
}

# ----------------------------------------------------------------------------
# 2. Karpenter controller IAM role (Pod Identity)
# ----------------------------------------------------------------------------
# Pod Identity associations bind this role to the karpenter ServiceAccount in
# the kube-system namespace. The association itself is created below via
# aws_eks_pod_identity_association.

data "aws_iam_policy_document" "controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json

  tags = var.tags
}

# Minimum-rights controller policy. Scope by cluster tag and node role wherever
# the API supports it — this is the v1 reference policy from karpenter.sh,
# trimmed to a single cluster.
data "aws_iam_policy_document" "controller" {
  statement {
    sid    = "AllowScopedEC2InstanceAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
    ]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}::image/*",
      "arn:aws:ec2:${data.aws_region.current.name}::snapshot/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:security-group/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:subnet/*",
    ]
  }

  statement {
    sid    = "AllowScopedEC2LaunchTemplateAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
    ]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  statement {
    sid    = "AllowScopedEC2InstanceActionsWithTags"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
    ]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}:*:fleet/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:instance/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:volume/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:network-interface/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:spot-instances-request/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid     = "AllowScopedResourceCreationTagging"
    effect  = "Allow"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}:*:fleet/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:instance/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:volume/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:network-interface/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:spot-instances-request/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }
  }

  statement {
    sid    = "AllowScopedDeletion"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}:*:instance/*",
      "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowRegionalReadActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [data.aws_region.current.name]
    }
  }

  statement {
    sid       = "AllowSSMReadActions"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}::parameter/aws/service/*"]
  }

  statement {
    sid       = "AllowPricingReadActions"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.interruption.arn]
  }

  statement {
    sid     = "AllowPassingInstanceRole"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.node_role_name}",
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Karpenter 1.0.x doesn't propagate the cluster tag onto the
  # iam:CreateInstanceProfile API call, so the aws:RequestTag condition
  # blocks every attach. Scope by Karpenter's profile name prefix instead
  # (it always names profiles "<cluster_name>_<random>").
  statement {
    sid    = "AllowScopedInstanceProfileActions"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.cluster_name}_*"]
  }

  statement {
    sid       = "AllowInstanceProfileRead"
    effect    = "Allow"
    actions   = ["iam:GetInstanceProfile"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"]
  }

  statement {
    sid       = "AllowAPIServerEndpointDiscovery"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_policy" "controller" {
  name   = "${var.cluster_name}-karpenter-controller"
  policy = data.aws_iam_policy_document.controller.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

# Bind the controller role to the karpenter SA via Pod Identity.
resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.controller.arn
}

# ----------------------------------------------------------------------------
# 3. Instance profile for Karpenter-launched nodes
# ----------------------------------------------------------------------------
# We reuse the managed-node-group role to keep the aws-auth ConfigMap simple
# (Karpenter nodes show up in the cluster under the same identity).

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-karpenter-node"
  role = var.node_role_name

  tags = merge(var.tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# ----------------------------------------------------------------------------
# 4. Discovery tags on subnets and security groups
# ----------------------------------------------------------------------------
# EC2NodeClass.subnetSelectorTerms and securityGroupSelectorTerms look up
# resources by tag. We tag the private subnets and the cluster security group
# so the NodePools don't need to hard-code IDs.

resource "aws_ec2_tag" "subnet_discovery" {
  for_each = {
    for idx, subnet_id in var.private_subnet_ids :
    tostring(idx) => subnet_id
  }

  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_ec2_tag" "cluster_sg_discovery" {
  resource_id = var.cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_ec2_tag" "additional_sg_discovery" {
  for_each    = toset(var.additional_node_security_group_ids)
  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# --- Outputs ---
output "controller_role_arn" { value = aws_iam_role.controller.arn }
output "node_instance_profile_name" { value = aws_iam_instance_profile.node.name }
output "interruption_queue_name" { value = aws_sqs_queue.interruption.name }
output "interruption_queue_arn" { value = aws_sqs_queue.interruption.arn }
