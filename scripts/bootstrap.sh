#!/usr/bin/env bash
# ============================================================================
# Phase 0 bootstrap: bring up the management cluster + GitOps of GitOps
# ----------------------------------------------------------------------------
# Prereqs: terraform, helm, helmfile, kubectl, aws cli, jq
# ============================================================================
set -euo pipefail

ENVIRONMENT="${1:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# --- Prereq checks ---
for cmd in terraform helm helmfile kubectl aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd not installed"
done
aws sts get-caller-identity >/dev/null 2>&1 || fail "AWS credentials not configured"

log "Bootstrapping platform management cluster for env=$ENVIRONMENT region=$AWS_REGION"

# --- Step 1: backend bootstrap (S3 + DynamoDB + KMS for state) ---
log "Step 1/5: Bootstrapping Terraform backend..."
cd "$ROOT_DIR/envs/_template/backend-bootstrap"
terraform init -input=false
terraform apply -auto-approve \
  -var="environment=$ENVIRONMENT" \
  -input=false

BUCKET=$(terraform output -raw bucket)
LOCK_TBL=$(terraform output -raw lock_tbl)
KMS_ARN=$(terraform output -raw kms_arn)
ok "Backend ready: bucket=$BUCKET lock=$LOCK_TBL"

# --- Step 2: configure the env's backend.tf ---
ENV_DIR="$ROOT_DIR/envs/$ENVIRONMENT"
mkdir -p "$ENV_DIR"
[ -f "$ENV_DIR/terraform.tfvars" ] || cp "$ROOT_DIR/envs/dev/terraform.tfvars.example" "$ENV_DIR/terraform.tfvars"

# Patch environment and aws_region in tfvars.
sed -i.bak "s/^environment.*=.*$/environment        = \"$ENVIRONMENT\"/" "$ENV_DIR/terraform.tfvars"
sed -i.bak "s/^aws_region.*=.*$/aws_region         = \"$AWS_REGION\"/" "$ENV_DIR/terraform.tfvars"

cat > "$ENV_DIR/backend.tf" <<EOF
terraform {
  backend "s3" {
    bucket         = "$BUCKET"
    key            = "platform-fleet/$ENVIRONMENT/terraform.tfstate"
    region         = "$AWS_REGION"
    dynamodb_table = "$LOCK_TBL"
    encrypt        = true
    kms_key_id     = "$KMS_ARN"
  }
}
EOF

# --- Step 3: terraform apply the management cluster ---
log "Step 2/5: Applying platform-fleet (this takes ~10 min)..."
cd "$ENV_DIR"
terraform init -input=false
terraform apply -var-file=terraform.tfvars -auto-approve -input=false
ok "Cluster provisioned"

# --- Export SIZING_* envsubst vars from the storage module's outputs ---
# StorageClasses consume these via envsubst at helmfile render time
# (mgmt-cluster-aws/apps/storage/storageclass-ebs.yaml.gotmpl).
log "Exporting sizing env vars for envsubst..."
SIZING_JSON=$(terraform output -json -module=aws_storage sizing 2>/dev/null \
              || terraform output -json aws_storage_sizing 2>/dev/null \
              || echo '{}')
export SIZING_GP3_DEFAULT_IOPS=$(echo "$SIZING_JSON"    | jq -r '.gp3_default_iops          // 3000')
export SIZING_GP3_DEFAULT_THROUGHPUT=$(echo "$SIZING_JSON" | jq -r '.gp3_default_throughput    // 125')
export SIZING_GP3_THROUGHPUT_IOPS=$(echo "$SIZING_JSON"   | jq -r '.gp3_throughput_iops       // 4000')
export SIZING_GP3_THROUGHPUT_THROUGHPUT=$(echo "$SIZING_JSON" | jq -r '.gp3_throughput_throughput // 1000')
export SIZING_IO2_IOPS=$(echo "$SIZING_JSON"             | jq -r '.io2_iops                  // 16000')
ok "Sizing: gp3_default=$SIZING_GP3_DEFAULT_IOPS/$SIZING_GP3_DEFAULT_THROUGHPUT  io2=$SIZING_IO2_IOPS"

# --- Step 4: configure kubectl + ArgoCD ingress + certs ---
log "Step 3/5: Configuring kubectl + bootstrap ingress/certs..."
aws eks update-kubeconfig --name "${ENVIRONMENT}-platform-mgmt" --region "$AWS_REGION"
ok "kubeconfig updated"

# --- Step 5: bootstrap ArgoCD with App-of-Apps ---
log "Step 4/5: Bootstrapping ArgoCD App-of-Apps..."
GITOPS_FLEET_REPO="${GITOPS_FLEET_REPO:-git@github.com:your-org/gitops-fleet.git}"
kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.${ENVIRONMENT}.example.com
  applicationsetcontroller.policy.csv: |
    p, proj:, appset, *, */*
EOF

# Install root App-of-Apps
kubectl apply -n argocd -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app-of-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $GITOPS_FLEET_REPO
    targetRevision: main
    path: apps/
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

ok "App-of-Apps installed"

# --- Step 6: print summary ---
log "Step 5/5: Summary"
cat <<EOF

$(ok "Bootstrap complete for $ENVIRONMENT")

ArgoCD UI:    https://argocd.${ENVIRONMENT}.example.com
Argo WF UI:   https://argo.${ENVIRONMENT}.example.com
Vault:        kubectl port-forward -n vault svc/vault 8200:8200 (then http://localhost:8200)

Initial ArgoCD password:
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

Next steps:
  1. Configure OIDC SSO for ArgoCD (see mgmt-cluster-aws/bootstrap/argocd-oidc.yaml)
  2. Initialize Vault (vault-bootstrap/ runbook)
  3. Push gitops-fleet and gitops-apps repos to your GitHub org
  4. Add the platform repo to Renovate

EOF
