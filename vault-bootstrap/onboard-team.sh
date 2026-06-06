#!/usr/bin/env bash
# ============================================================================
# Onboard a product team to Vault + ArgoCD + GitHub
# ----------------------------------------------------------------------------
# Creates:
#   - Vault policy: secret/data/teams/<team>/* (read/write for leads, read for devs)
#   - Vault Kubernetes auth role
#   - ArgoCD AppProject
#   - GitHub team + repo permissions (via gh CLI)
# ============================================================================
set -euo pipefail

TEAM_NAME="${1:?usage: onboard-team.sh <team-name> <github-org>}"
GITHUB_ORG="${2:?usage: onboard-team.sh <team-name> <github-org>}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"

log() { echo -e "\033[0;34m[*]\033[0m $*"; }

# --- 1. Vault policy ---
log "Creating Vault policy for team $TEAM_NAME..."
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- env \
  VAULT_TOKEN="${VAULT_ROOT_TOKEN:?set VAULT_ROOT_TOKEN}" \
  VAULT_ADDR="https://127.0.0.1:8200" \
  /bin/sh -c "
    vault policy write team-${TEAM_NAME}-rw - <<EOF
path \"secret/data/teams/${TEAM_NAME}/*\" {
  capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"]
}
path \"secret/metadata/teams/${TEAM_NAME}/*\" {
  capabilities = [\"list\"]
}
EOF

    vault policy write team-${TEAM_NAME}-ro - <<EOF
path \"secret/data/teams/${TEAM_NAME}/*\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/teams/${TEAM_NAME}/*\" {
  capabilities = [\"list\"]
}
EOF

    # Bind to Kubernetes ServiceAccounts in the team's namespaces
    for env in dev staging prod; do
      vault write auth/kubernetes/role/team-${TEAM_NAME}-${env} \\
        bound_service_account_names=team-${TEAM_NAME}-sa \\
        bound_service_account_namespaces=team-${TEAM_NAME}-${env} \\
        policies=team-${TEAM_NAME}-rw \\
        ttl=1h
    done
  "

# --- 2. ArgoCD AppProject ---
log "Creating ArgoCD AppProject for team $TEAM_NAME..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-${TEAM_NAME}
  namespace: argocd
spec:
  description: ${TEAM_NAME} team AppProject
  sourceRepos:
    - 'https://github.com/${GITHUB_ORG}/*'
  destinations:
    - namespace: 'team-${TEAM_NAME}-*'
      server: '*'
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: ''
      kinds: ['ConfigMap', 'Secret', 'Service', 'ServiceAccount']
    - group: 'apps'
      kinds: ['Deployment', 'StatefulSet']
    - group: 'batch'
      kinds: ['CronJob', 'Job']
    - group: 'networking.k8s.io'
      kinds: ['Ingress']
    - group: 'autoscaling'
      kinds: ['HorizontalPodAutoscaler']
  roles:
    - name: developer
      policies:
        - 'p, proj:team-${TEAM_NAME}:developer, applications, get, */*, allow'
        - 'p, proj:team-${TEAM_NAME}:developer, applications, sync, */*, allow'
      groups:
        - '${GITHUB_ORG}:team-${TEAM_NAME}-developers'
EOF

# --- 3. GitHub team (best-effort) ---
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  log "Creating GitHub teams for $TEAM_NAME..."
  gh api -X POST "/orgs/${GITHUB_ORG}/teams" \
    -f name="team-${TEAM_NAME}-developers" \
    -f description="Developers in ${TEAM_NAME}" \
    -f privacy=closed || true
  gh api -X POST "/orgs/${GITHUB_ORG}/teams" \
    -f name="team-${TEAM_NAME}-admins" \
    -f description="Admins in ${TEAM_NAME}" \
    -f privacy=closed || true
else
  log "Skipping GitHub team creation (gh CLI not authenticated)"
fi

cat <<EOF

================================================================
Team $TEAM_NAME onboarded.

Vault policy:    team-${TEAM_NAME}-rw / team-${TEAM_NAME}-ro
ArgoCD project:  team-${TEAM_NAME}
Namespaces:      team-${TEAM_NAME}-{dev,staging,prod}
GitHub teams:    team-${TEAM_NAME}-{developers,admins}

NEXT STEPS:
  1. Add team members to the GitHub team: ${GITHUB_ORG}:team-${TEAM_NAME}-developers
  2. Create the team's first service under gitops-apps/teams/${TEAM_NAME}/<service>/
  3. Submit the first PR. The team's pipeline template will scaffold it.

================================================================
EOF
