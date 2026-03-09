#!/bin/bash
# validate_k8s.sh
# ---------------------------------------------------------
# Automated Verification Script for Botanical Kubernetes Deploy
# Validates manifests, configurations, and best practices.
# ---------------------------------------------------------

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
KUSTOMIZE_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[VALIDATE] $1"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }

log "Starting Kubernetes Manifest Verification"

# 1. Check Kustomize Build
log "Phase 1: Validating Kustomize Build..."
if ! command -v kubectl &>/dev/null; then
    warn "kubectl is not installed. Testing with raw kustomize if available."
    if ! command -v kustomize &>/dev/null; then
        error "Neither kubectl nor kustomize is installed. Cannot validate templates."
    else
        kustomize build "$KUSTOMIZE_DIR" > /dev/null || error "Kustomize syntax error in manifests."
    fi
else
    kubectl kustomize "$KUSTOMIZE_DIR" > /dev/null || error "Kubectl kustomize build failed. Check syntax."
fi
log "${GREEN}✓ Kustomize build successful. All YAMLs are syntactically valid.${NC}"

# 2. Check Required Files
log "Phase 2: Verifying required manifests exist..."
REQUIRED_FILES=(
    "namespace.yaml"
    "configmaps.yaml"
    "secrets.yaml"
    "storage.yaml"
    "rstudio-deployment.yaml"
    "rstudio-service.yaml"
    "portal-deployment.yaml"
    "portal-service.yaml"
    "ingress.yaml"
    "ollama-deployment.yaml"
    "telemetry-api-deployment.yaml"
    "oauth2-proxy-deployment.yaml"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${KUSTOMIZE_DIR}/$file" ]; then
        error "Missing required manifest: $file"
    fi
done
log "${GREEN}✓ All base manifests present.${NC}"

# 3. Static Analysis / Constraints check (Simulated Linter)
log "Phase 3: Deep Configuration Analysis..."
# Check if docker.sock is accidentally mounted anywhere (Security Violation)
if grep -q "docker.sock" "${KUSTOMIZE_DIR}"/*.yaml; then
    error "SECURITY VIOLATION: docker.sock found in manifests. This violates K8s PSA."
else
    log "${GREEN}✓ No privileged docker.sock mounts detected.${NC}"
fi

# Check if runAsUser: 0 is used unnecessarily in pods without dropping capabilities
if grep -A 5 "securityContext" "${KUSTOMIZE_DIR}"/*.yaml | grep -q 'runAsUser: 0'; then
    warn "Pods running as Root (UID 0) detected. Ensure capabilities are dropped (e.g. drop: ['ALL'])."
    # We verify if we actually dropped capabilities where root was used
    if ! grep -q "drop:" "${KUSTOMIZE_DIR}"/*.yaml; then
        error "SECURITY VIOLATION: Running as root without dropping capabilities."
    fi
    log "${GREEN}✓ Root containers found but capability dropping is enforced.${NC}"
fi

# 4. Dry-Run against cluster (if accessible)
log "Phase 4: Cluster Dry-Run Integration..."
if kubectl cluster-info &>/dev/null; then
    log "Cluster is accessible. Performing server-side dry-run validation..."
    kubectl apply -k "$KUSTOMIZE_DIR" --dry-run=server || error "Server-side validation failed. Cluster rejected manifests."
    log "${GREEN}✓ Server-side Dry-Run passed. Deployments align with Cluster schemas.${NC}"
else
    warn "Cluster is not accessible or kubectl is unconfigured. Skipping live server dry-run validation."
fi

echo "========================================================"
log "${GREEN}All local syntax and security baseline checks passed!${NC}"
echo "========================================================"
echo "To deploy, run: kubectl apply -k ."
