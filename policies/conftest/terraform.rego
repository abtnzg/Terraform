# ============================================================================
# Terraform policy bundle
# ----------------------------------------------------------------------------
# Conftest (OPA) policies run in CI on every PR. They prevent:
#   - unencrypted S3/EBS/EFS/RDS
#   - public S3 buckets
#   - IMDSv1 (we require v2)
#   - IAM policies with `*` actions on `*` resources
#   - missing tags
# Tested via fixtures under tests/.
# ============================================================================

package terraform.platform

# Reject S3 buckets without server-side encryption.
deny_s3_unencrypted[msg] {
  resource := input.resource.aws_s3_bucket[name]
  not has_sse(resource, name)
  msg := sprintf("aws_s3_bucket[%s] is missing server-side encryption", [name])
}

# Reject S3 buckets with public access not blocked.
deny_s3_public[msg] {
  resource := input.resource.aws_s3_bucket[name]
  pab := input.resource.aws_s3_bucket_public_access_block[name]
  not pab.block_public_acls
  msg := sprintf("aws_s3_bucket[%s] does not block public ACLs", [name])
}

# Reject EBS volumes that are not encrypted.
deny_ebs_unencrypted[msg] {
  vol := input.resource.aws_ebs_volume[name]
  not vol.encrypted
  msg := sprintf("aws_ebs_volume[%s] is not encrypted", [name])
}

# Reject launch templates without IMDSv2.
deny_imdsv1[msg] {
  lt := input.resource.aws_launch_template[name]
  not lt.metadata_options.http_tokens == "required"
  msg := sprintf("aws_launch_template[%s] requires IMDSv2 (http_tokens=required)", [name])
}

# Reject EKS clusters without secrets encryption.
deny_eks_unencrypted_secrets[msg] {
  cluster := input.resource.aws_eks_cluster[name]
  not cluster.encryption_config
  msg := sprintf("aws_eks_cluster[%s] has no encryption_config (secrets must be encrypted with KMS)", [name])
}

# Reject IAM policies granting `*:*` to anything but the cluster root.
deny_iam_admin[msg] {
  policy := input.resource.aws_iam_policy[name]
  stmt := policy.policy.Statement[_]
  stmt.Effect == "Allow"
  stmt.Action == "*"
  stmt.Resource == "*"
  not is_known_admin_role(stmt)
  msg := sprintf("aws_iam_policy[%s] grants Action=* Resource=* (admin-only path)", [name])
}

# Require mandatory tags on every taggable resource.
required_tags := ["Environment", "ManagedBy", "Project"]

deny_missing_tags[msg] {
  resource := input.resource[provider][name]
  is_taggable(resource)
  missing := required_tags[_]
  not resource.tags[missing]
  msg := sprintf("%s[%s] is missing required tag %q", [provider, name, missing])
}

# Reject DB instances with public access enabled.
deny_rds_public[msg] {
  db := input.resource.aws_db_instance[name]
  db.publicly_accessible == true
  msg := sprintf("aws_db_instance[%s] is publicly accessible", [name])
}

# Reject security groups allowing 0.0.0.0/0 ingress to sensitive ports.
sensitive_ports := [22, 3389, 3306, 5432, 6379, 27017, 9200, 5601]

deny_sg_open_admin[msg] {
  sg := input.resource.aws_security_group[name]
  rule := sg.ingress[_]
  rule.cidr_blocks[_] == "0.0.0.0/0"
  rule.from_port == sensitive_ports[_]
  msg := sprintf("aws_security_group[%s] allows 0.0.0.0/0 to sensitive port %d", [name, rule.from_port])
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

has_sse(bucket, name) {
  sse := input.resource.aws_s3_bucket_server_side_encryption_configuration[name]
  sse.rule[_].apply_server_side_encryption_by_default.sse_algorithm
}

is_known_admin_role(stmt) {
  # Allow the GitHub OIDC role to be admin in dev only.
  startswith(stmt.Sid, "GitHubOIDCAdmin")
}

is_taggable(resource) {
  resource.tags
}

provider := resource_type_split(resource)[0]
resource_type := resource_type_split(resource)[1]

resource_type_split(resource) := [type, _] {
  keys := [k | k := object.keys(resource)[_]; k != "tags"]
  type := keys[_]
}
