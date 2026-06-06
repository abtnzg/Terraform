# Vault — Operations Runbook

## Architecture

- **Dev**: single Vault pod, in-memory storage, no unseal required. Root token in `init-output.txt`.
- **Staging / Prod**: 3-node Vault HA Raft, AWS KMS auto-unseal, audit logs to CloudWatch + local file.

## Initial bootstrap

```bash
# 1. Set the KMS key created by platform-fleet
export VAULT_KMS_KEY_ID="arn:aws:kms:us-east-1:123456789012:key/abcd-..."

# 2. Run the init script
./init-vault.sh

# 3. Save the unseal keys (5 total, threshold 3) to 1Password / AWS Secrets Manager
#    Save the root token to a SEPARATE vault (different operators)
```

The init script:
- Calls `vault operator init` with 5 key shares and threshold 3
- Unseals with 3 of the 5 keys
- Enables baseline auth (kubernetes, github) and secret engines (kv v2 at `secret/`)
- Writes baseline policies (`platform-admin`, `team-readonly`)
- Configures audit log file output to `/vault/audit/audit.log`

## Day-2 operations

### Unseal (only needed if KMS auto-unseal fails)

```bash
kubectl exec -n vault vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
  vault operator unseal <key-shard-1>
kubectl exec -n vault vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
  vault operator unseal <key-shard-2>
kubectl exec -n vault vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
  vault operator unseal <key-shard-3>
```

### Status

```bash
kubectl exec -n vault vault-0 -- vault status
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

### Backup the Raft data

```bash
kubectl exec -n vault vault-0 -- vault operator raft snapshot save /tmp/raft.snap
kubectl cp vault/vault-0:/tmp/raft.snap ./vault-snapshot-$(date +%Y%m%d).snap
aws s3 cp ./vault-snapshot-*.snap s3://platform-vault-snapshots-${ENVIRONMENT}/
```

### Restore

```bash
aws s3 cp s3://platform-vault-snapshots-${ENVIRONMENT}/vault-snapshot-latest.snap /tmp/
kubectl cp /tmp/vault-snapshot-latest.snap vault/vault-0:/tmp/
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/vault-snapshot-latest.snap
```

### Rotate a team secret (zero-downtime pattern)

1. Write the new value as a new version (Vault KV v2 keeps history):
   ```bash
   vault kv put secret/teams/<team>/<secret> value=<new-value>
   ```
2. ESO will sync the new version into Kubernetes within 60 seconds (default refresh).
3. The pod needs to pick up the new secret. For env vars, restart the pod. For file mounts, ESO re-creates the secret volume.
4. After 24 hours, prune old versions:
   ```bash
   vault kv metadata put -mount=secret -max-versions=5 secret/teams/<team>/<secret>
   ```

## Audit logs

Audit logs are written to `/vault/audit/audit.log` in the Vault pods.
Operators must:
- Ship this file to CloudWatch Logs (via the `aws-cloudwatch-logs` DaemonSet or a sidecar)
- Ship a copy to S3 (long-term retention: 7 years for HIPAA, 1 year for SOC 2)

## Disaster recovery

| Scenario | RTO | RPO | Procedure |
|---|---|---|---|
| Single Vault pod down | 5 min | 0 | StatefulSet self-heals |
| All Vault pods down (cluster intact) | 10 min | 0 | Restart StatefulSet; KMS auto-unseal |
| Raft data corruption | 30 min | Last snapshot | Restore from S3 snapshot |
| Full cluster loss | 4 hours | Last snapshot | Recreate cluster, run `init-vault.sh`, then `vault operator raft snapshot restore` |

## Compliance notes

- KMS auto-unseal means the unseal key never lives in operator memory. Operators do not have direct access to the root encryption key.
- 5 key shares / threshold 3 enables geo-distributed recovery (e.g., 2 keys in US, 2 in EU, 1 in APAC).
- Audit logs are tamper-evident (file mode 0600, append-only at the filesystem level via Kubernetes).

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `connection refused` to Vault | Pod not ready | `kubectl wait --for=condition=ready pod -n vault vault-0` |
| `sealed` status | Auto-unseal failed | Manual unseal with 3 shards |
| `permission denied` on kv read | Missing policy | Check team policy with `vault token capabilities secret/teams/<team>/<secret>` |
| `no secret engine mounted at secret/` | Init not run | Run `init-vault.sh` |
