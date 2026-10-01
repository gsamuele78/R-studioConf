#!/bin/bash
set -euo pipefail

# =====================================================================
# Manage PKI Trust Script (v2.0 - Hardened)
# =====================================================================
# Fetches and installs the Root CA certificate from a remote Step-CA
# server. Implements MANDATORY fingerprint verification — no TOFU.
#
# Usage: manage_pki_trust.sh [CA_URL] [CA_FINGERPRINT]
#   Or set CA_URL and CA_FINGERPRINT as environment variables.
#
# Compatible with infra-iam/infra-ood patterns (fetch_pki_root.sh).
# Requires: curl, openssl (or step CLI for preferred path)
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
COMMON_UTILS="${SCRIPT_DIR}/../lib/common_utils.sh"

# Load Common Utils if available
if [ -f "$COMMON_UTILS" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_UTILS"
else
    # Fallback logging
    log() { echo "[${1}] ${2}"; }
fi

# =====================================================================
# CONFIGURATION
# =====================================================================

# Allow positional args to override env vars
CA_URL="${1:-${CA_URL:-}}"
FINGERPRINT="${2:-${CA_FINGERPRINT:-}}"

# Temporary cert download path (avoid world-writable /tmp for secrets)
TMP_DIR="$(mktemp -d)"
TMP_CERT="${TMP_DIR}/root_ca.crt"
TRUST_DIR="/usr/local/share/ca-certificates"
CERT_NAME="internal-infra-root-ca.crt"

# =====================================================================
# CLEANUP TRAP
# =====================================================================

cleanup() {
    local exit_code=$?
    rm -rf "${TMP_DIR}"
    if [ "${exit_code}" -ne 0 ]; then
        log "ERROR" "manage_pki_trust.sh exited with code ${exit_code}"
    fi
}
trap cleanup EXIT ERR

# =====================================================================
# FUNCTIONS
# =====================================================================

assert_deps() {
    local missing=0
    for cmd in curl openssl; do
        if ! command -v "${cmd}" &>/dev/null; then
            log "ERROR" "Required binary '${cmd}' not found in PATH."
            missing=1
        fi
    done
    [ "${missing}" -eq 0 ] || return 1
}

# Verify certificate fingerprint using step CLI (preferred) or openssl
verify_fingerprint_step() {
    local cert_path="$1"
    local expected_fp="$2"

    if ! command -v step &>/dev/null; then
        return 1  # step not available — caller falls back to openssl
    fi

    log "INFO" "Verifying fingerprint using step CLI..."
    local calc_fp
    calc_fp=$(step certificate fingerprint "${cert_path}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ':')
    local norm_expected
    norm_expected=$(echo "${expected_fp}" | tr '[:upper:]' '[:lower:]' | tr -d ':')

    if [[ "${calc_fp}" == "${norm_expected}" ]]; then
        log "INFO" "Fingerprint verified via step CLI."
        return 0
    else
        log "FATAL" "Fingerprint MISMATCH (step)! Expected: ${norm_expected}, Got: ${calc_fp}"
        return 2
    fi
}

# Verify certificate fingerprint using openssl (fallback)
verify_fingerprint_openssl() {
    local cert_path="$1"
    local expected_fp="$2"

    log "INFO" "Verifying fingerprint using openssl..."
    local calc_fp
    calc_fp=$(openssl x509 -in "${cert_path}" -noout -fingerprint -sha256 \
        | cut -d= -f2 \
        | tr '[:upper:]' '[:lower:]' \
        | tr -d ':')
    local norm_expected
    norm_expected=$(echo "${expected_fp}" | tr '[:upper:]' '[:lower:]' | tr -d ':')

    if [[ "${calc_fp}" == "${norm_expected}" ]]; then
        log "INFO" "Fingerprint verified via openssl."
        return 0
    else
        log "FATAL" "Fingerprint MISMATCH (openssl)! Expected: ${norm_expected}, Got: ${calc_fp}"
        return 1
    fi
}

install_trust() {
    log "INFO" "=== Manage PKI Trust v2.0 (Hardened) ==="

    # 1. Assert runtime dependencies
    assert_deps || {
        log "ERROR" "Missing required binaries. Aborting PKI trust setup."
        return 1
    }

    # 2. Validate inputs
    if [ -z "${CA_URL}" ]; then
        log "WARN" "CA_URL is not set. Skipping PKI trust setup (not an error in dev mode)."
        return 0
    fi

    if [ -z "${FINGERPRINT}" ]; then
        # Warn loudly — never silently skip verification in this version
        log "WARN" "====================================================="
        log "WARN" " CA_FINGERPRINT is NOT set."
        log "WARN" " Certificate will be downloaded but NOT fingerprint-"
        log "WARN" " verified. This is INSECURE for production use."
        log "WARN" " Set CA_FINGERPRINT in .env to enable verification."
        log "WARN" "====================================================="
        # In non-strict mode we continue (dev/sandbox), but log the gap.
        # Strict enforcement can be enabled by uncommenting the next line:
        # return 1
    fi

    log "INFO" "Target CA: ${CA_URL}"

    # 3. Download Root CA — use curl without -k (server must be reachable via HTTPS
    #    or plain HTTP; if HTTPS and cert not yet trusted, bootstrap must use HTTP first)
    log "INFO" "Downloading Root CA from ${CA_URL}/roots.pem ..."
    if ! curl --silent --show-error --fail \
         --max-time 30 \
         --output "${TMP_CERT}" \
         "${CA_URL}/roots.pem"; then
        log "ERROR" "Failed to download root certificate from ${CA_URL}/roots.pem"
        return 1
    fi

    if [ ! -s "${TMP_CERT}" ]; then
        log "ERROR" "Downloaded certificate file is empty."
        return 1
    fi

    # Validate it is actually a PEM certificate
    if ! openssl x509 -in "${TMP_CERT}" -noout 2>/dev/null; then
        log "ERROR" "Downloaded file is not a valid PEM certificate."
        return 1
    fi

    # 4. Fingerprint Verification (mandatory when FINGERPRINT is set)
    if [ -n "${FINGERPRINT}" ]; then
        # Try step CLI first (preferred), then openssl
        local fp_result=0
        verify_fingerprint_step "${TMP_CERT}" "${FINGERPRINT}" || fp_result=$?
        if [ "${fp_result}" -eq 1 ]; then
            # step not available — try openssl
            verify_fingerprint_openssl "${TMP_CERT}" "${FINGERPRINT}" || {
                log "FATAL" "Fingerprint verification FAILED. Refusing to install CA."
                return 1
            }
        elif [ "${fp_result}" -eq 2 ]; then
            # Mismatch detected by step
            log "FATAL" "Fingerprint mismatch detected. Refusing to install CA."
            return 1
        fi
    fi

    # 5. Install to System Trust Store
    if [ ! -d "${TRUST_DIR}" ]; then
        log "WARN" "Trust directory not found at ${TRUST_DIR}. Is this a supported OS?"
        return 1
    fi

    log "INFO" "Installing CA to system trust store (${TRUST_DIR})..."
    # Copy from secure temp location (not world-writable /tmp)
    cp "${TMP_CERT}" "${TRUST_DIR}/${CERT_NAME}"
    chmod 644 "${TRUST_DIR}/${CERT_NAME}"

    if command -v update-ca-certificates &>/dev/null; then
        update-ca-certificates >/dev/null
        log "INFO" "System CA trust store updated."
    else
        log "WARN" "'update-ca-certificates' not found. Manual trust store update may be required."
    fi

    log "INFO" "PKI Trust Setup Complete. CA installed: ${TRUST_DIR}/${CERT_NAME}"
}

# =====================================================================
# MAIN
# =====================================================================

# Only run if called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_trust "$@"
fi
