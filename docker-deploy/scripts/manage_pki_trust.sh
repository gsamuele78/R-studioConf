#!/bin/bash
set -u

# =====================================================================
# Manage PKI Trust Script (v1.0 - Docker Adapted)
# =====================================================================
# Fetches and installs the Root CA certificate from a remote Step-CA server.
# Adapted from Infra-Iam-PKI best practices for Docker environments.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
COMMON_UTILS="${SCRIPT_DIR}/../lib/common_utils.sh"

# Load Common Utils if available
if [ -f "$COMMON_UTILS" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_UTILS"
else
    # Fallback logging
    log() { echo "[$1] $2"; }
fi

# =====================================================================
# CONFIGURATION
# =====================================================================

# Allow args to override env vars
CA_URL="${1:-${CA_URL:-}}"
FINGERPRINT="${2:-${CA_FINGERPRINT:-}}"

# Default path for temporary download
TMP_CERT="/tmp/root_ca.crt"
TRUST_DIR="/usr/local/share/ca-certificates"
CERT_NAME="internal-infra-root-ca.crt"

# =====================================================================
# FUNCTIONS
# =====================================================================

install_trust() {
    log "INFO" "Starting PKI Trust Installation..."
    
    # 1. Validate Inputs
    if [ -z "$CA_URL" ]; then
        log "WARN" "CA_URL is not set. Skipping PKI trust setup."
        return 0
    fi
    
    log "INFO" "Target CA: $CA_URL"

    # 2. Download Root CA
    log "INFO" "Downloading Root CA..."
    if ! curl -k -sS "$CA_URL/roots.pem" -o "$TMP_CERT"; then
        log "ERROR" "Failed to download root certificate from $CA_URL/roots.pem"
        return 1
    fi
    
    if [ ! -s "$TMP_CERT" ]; then
        log "ERROR" "Downloaded certificate file is empty."
        return 1
    fi
    
    # 3. Verify Fingerprint (If provided)
    if [ -n "$FINGERPRINT" ]; then
        log "INFO" "Verifying CA Fingerprint..."
        if command -v openssl &>/dev/null; then
            # Calculate SHA256 (step-ca style is usually hex)
            local calc_fp
            calc_fp=$(openssl x509 -in "$TMP_CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)
            
            # Normalize for comparison (remove colons, lowercase)
            local norm_calc_fp="${calc_fp//:/}"
            norm_calc_fp="${norm_calc_fp,,}"
            local norm_expected_fp="${FINGERPRINT//:/}"
            norm_expected_fp="${norm_expected_fp,,}"
            
            if [[ "$norm_calc_fp" == "$norm_expected_fp" ]]; then
                log "INFO" "Fingerprint Match Verified."
            else
                log "FATAL" "Fingerprint Mismatch! Expected: $norm_expected_fp, Got: $norm_calc_fp"
                return 1
            fi
        else
            log "WARN" "OpenSSL not found. Skipping fingerprint verification."
        fi
    else
        log "WARN" "No CA_FINGERPRINT provided. Trusting server response implicitly (TOFU)."
    fi
    
    # 4. Install to Trust Store
    if [ -d "$TRUST_DIR" ]; then
        log "INFO" "Installing to system trust store ($TRUST_DIR)..."
        cp "$TMP_CERT" "$TRUST_DIR/$CERT_NAME"
        chmod 644 "$TRUST_DIR/$CERT_NAME"
        
        if command -v update-ca-certificates &>/dev/null; then
            update-ca-certificates >/dev/null
            log "INFO" "System CA trust store updated."
        else
            log "WARN" "'update-ca-certificates' command not found."
        fi
    else
        log "WARN" "Trust directory not found at $TRUST_DIR. Is this a supported OS?"
        return 1
    fi
    
    log "INFO" "PKI Trust Setup Complete."
}

# =====================================================================
# MAIN EXECUTION
# =====================================================================

# Only run if called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_trust "$@"
fi
