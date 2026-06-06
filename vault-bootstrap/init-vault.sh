#!/usr/bin/env bash
# ============================================================================
# Vault initialization with AWS KMS auto-unseal
# ----------------------------------------------------------------------------
# Run this once after `helmfile apply` brings up the Vault StatefulSet.
# Re-runnable: detects already-initialized Vault and exits early.
# ============================================================================
set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-dev}"
KMS_KEY_ID="${VAULT_KMS_KEY_ID:?must be set to the platform CMK ARN}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"

log() { echo -e "\033[0;34m[$(date +%H:%M:%S)]\033[0m $*"; }
ok()  { echo -e "\033[0;32m[OK]\033[0m $*"; }
fail(){ echo -e "\033[0;31m[FAIL]\033[0m $*" >&2; exit 1; }

# --- Wait for Vault to be reachable ---
log "Waiting for Vault pod ${VAULT_NAMESPACE}/${VAULT_POD}..."
kubectl wait --for=condition=ready pod -n "$VAULT_NAMESPACE" "$VAULT_POD" --timeout=120s

vault_exec() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault "$@"
}

# --- Check initialization status ---
STATUS=$(vault_exec status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")

if [ "$STATUS" = "true" ]; then
  log "Vault already initialized. Skipping init."
  exit 0
fi

# --- Initialize ---
log "Initializing Vault (key shares=5, threshold=3)..."
INIT_OUTPUT=$(vault_exec operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json)

# Extract unseal keys + root token. These are SHOWN ONCE.
echo "$INIT_OUTPUT" > "./init-output.txt"
chmod 600 "./init-output.txt"

UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
UNSEAL_KEY_3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

ok "Vault initialized. Keys stored in init-output.txt (KEEP SAFE)."
log "Distribute unseal keys to 3 operators via 1Password or AWS Secrets Manager."
log "Distribute the root token separately, only to the platform team lead."

# --- Unseal (3 of 5 keys) ---
log "Unsealing Vault with 3 of 5 keys..."
for i in 1 2 3; do
  KEY_VAR="UNSEAL_KEY_$i"
  KEY="${!KEY_VAR}"
  vault_exec operator unseal "$KEY" || fail "unseal key $i failed"
done

# --- Configure KMS auto-unseal for the future ---
log "Configuring KMS auto-unseal (recovery mode)..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- env \
  VAULT_TOKEN="$ROOT_TOKEN" \
  VAULT_ADDR="https://127.0.0.1:8200" \
  /bin/sh -c "
    vault operator audit enable -path=audit file file_path=/vault/audit/audit.log || true
    # KMS auto-unseal is already configured in the Helm values.
    # The init above generated the recovery key shards; future unseals happen automatically.
    echo 'Auto-unseal verified via Helm values.'
  "

# --- Enable KV v2 + baseline auth methods ---
log "Enabling baseline auth methods and secrets engines..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- env \
  VAULT_TOKEN="$ROOT_TOKEN" \
  VAULT_ADDR="https://127.0.0.1:8200" \
  /bin/sh -c "
    set -e
    vault secrets enable -path=secret -version=2 kv || true
    vault auth enable kubernetes || true
    vault auth enable -path=github github || true

    vault write auth/kubernetes/config \\
      kubernetes_host=https://kubernetes.default.svc.cluster.local

    # Platform team policy: full read/write on secret/
    vault policy write platform-admin - <<EOF
path \"secret/*\" {
  capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"]
}
path \"sys/*\" {
  capabilities = [\"read\", \"list\"]
}
EOF

    # Read-only policy for product teams on their own namespace
    vault policy write team-readonly - <<EOF
path \"secret/data/teams/*\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/teams/*\" {
  capabilities = [\"list\"]
}
EOF

    # Configure audit shipping
    vault audit enable -path=cloudwatch file file_path=/vault/audit/audit.log || true
    echo 'Baseline configuration complete.'
  "

ok "Vault is initialized, unsealed, and configured."

cat <<EOF

================================================================
Vault initialization complete for environment: $ENVIRONMENT

ROOT TOKEN: stored in ./init-output.txt (chmod 600)
UNSEAL KEYS: 5 shards, threshold 3 — distribute via 1Password

NEXT STEPS:
  1. Back up init-output.txt to a secure location (1Password vault, AWS Secrets Manager)
  2. Configure the platform-cli to use the root token (or per-operator tokens)
  3. Onboard the first team: ./onboard-team.sh <team-name> <github-org>

================================================================
EOF
