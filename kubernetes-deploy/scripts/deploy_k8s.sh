#!/bin/bash
# kubernetes-deploy/scripts/deploy_k8s.sh
# ---------------------------------------------------------
# Sysadmin Master Deployment Script for R-Studio RKE2
# Handles environment variable injection, namespace creation, 
# and Kustomize manifest application.
# ---------------------------------------------------------

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
K8S_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${K8S_ROOT_DIR}/env/.env.prd"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[DEPLOY-K8S] $1"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }

# 1. Environment Validation
log "Checking for environment file: $ENV_FILE"
if [ ! -f "$ENV_FILE" ]; then
    warn "Environment file not found at $ENV_FILE!"
    if [ -f "${K8S_ROOT_DIR}/env/.env.example" ]; then
        log "Copying .env.example to .env.prd..."
        cp "${K8S_ROOT_DIR}/env/.env.example" "$ENV_FILE"
        error "Please configure ${ENV_FILE} before running the deployment."
    else
        error "No environment template found."
    fi
fi

# Load variables safely
set -a
source "$ENV_FILE"
set +a

# 2. Pre-Flight Linter
log "Running pre-flight Linter & Validation..."
if [ -f "${K8S_ROOT_DIR}/scripts/validate_k8s.sh" ]; then
    "${K8S_ROOT_DIR}/scripts/validate_k8s.sh" || error "Validation script failed. Fix YAML errors first."
fi

# 3. Dynamic Secrets Generation
# Standard practice: Do not commit Secrets YAML. Generate them via script or SOPS.
log "Generating Kubernetes Secrets from Environment..."

# Create namespace if it doesn't exist so secret creation doesn't fail
kubectl apply -f "${K8S_ROOT_DIR}/namespace.yaml" >/dev/null

kubectl create secret generic rstudio-secrets \
    --namespace botanical \
    --from-literal=STEP_TOKEN="${STEP_TOKEN:-PLACEHOLDER}" \
    --from-literal=STEP_FINGERPRINT="${STEP_CA_FINGERPRINT:-PLACEHOLDER}" \
    --from-literal=AD_JOIN_USER="${AD_BIND_USER:-admin}" \
    --from-literal=AD_JOIN_PASS="${AD_BIND_PASS:-PLACEHOLDER}" \
    --from-literal=OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-rstudio-portal}" \
    --from-literal=OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-PLACEHOLDER}" \
    --from-literal=OAUTH2_COOKIE_SECRET="${OAUTH2_COOKIE_SECRET:-PLACEHOLDER_32_BYTES_MINIMUM}" \
    --dry-run=client -o yaml > "${K8S_ROOT_DIR}/secrets.yaml"

log "${GREEN}✓ Secrets generated safely.${NC}"

# 4. Storage Provisioning Check
log "Applying Persistent Volume Claims..."
kubectl apply -f "${K8S_ROOT_DIR}/storage.yaml"
# In a real environment, wait for bound status depending on the CSI driver
log "${GREEN}✓ Storage applied.${NC}"

# 5. Core Application Deployment
log "Applying Kustomize configuration to Cluster..."
kubectl apply -k "${K8S_ROOT_DIR}/"

log "========================================================"
log "${GREEN}Deployment applied successfully!${NC}"
log "Monitor pod startup with: kubectl get pods -n botanical -w"
log "========================================================"
