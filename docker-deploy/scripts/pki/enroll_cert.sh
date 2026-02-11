#!/bin/bash
set -euo pipefail

# =====================================================================
# enroll_cert.sh - Step-CA ACME/Token Enrollment
# =====================================================================
# Handles initial enrollment (via Token) and renewal of certificates.
# Designed to be run by entrypoint scripts (e.g., Nginx).
# =====================================================================

CRT_FILE="$1"
KEY_FILE="$2"

# Config from Env
: "${STEP_CA_URL:=${CA_URL:-}}"
: "${STEP_FINGERPRINT:=${CA_FINGERPRINT:-}}"
: "${STEP_TOKEN:=${TOKEN:-}}"
: "${HOST_DOMAIN:=${DOMAIN:-localhost}}" # Default subject

if [ -z "$STEP_CA_URL" ]; then
    echo "WARN: STEP_CA_URL not set. Skipping Certificate Enrollment."
    exit 0
fi

if [ -z "$CRT_FILE" ] || [ -z "$KEY_FILE" ]; then
    echo "ERROR: Usage: $0 <cert_path> <key_path>"
    exit 1
fi

# Ensure directory exists
mkdir -p "$(dirname "$CRT_FILE")"
mkdir -p "$(dirname "$KEY_FILE")"

# 1. Check if Certificate Exists
if [ ! -f "$CRT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "Certificate or Key missing. Attempting initial enrollment for $HOST_DOMAIN..."
    
    if [ -z "$STEP_TOKEN" ]; then
        echo "ERROR: STEP_TOKEN is missing. Cannot enroll new certificate."
        echo "Please generate a token on the CA server and add it to .env"
        exit 1
    fi

    echo "Enrolling with Step-CA..."
    # Initial Enrollment (Token-based)
    # Note: For Nginx, we typically want a leaf certificate (not SSH)
    step ca certificate "$HOST_DOMAIN" "$CRT_FILE" "$KEY_FILE" \
        --token "$STEP_TOKEN" \
        --ca-url "$STEP_CA_URL" \
        --fingerprint "$STEP_FINGERPRINT" \
        --force

    if [ $? -eq 0 ]; then
        echo "Enrollment successful."
        chmod 644 "$CRT_FILE"
        chmod 600 "$KEY_FILE"
    else
        echo "ERROR: Enrollment failed."
        exit 1
    fi
else
    # 2. Certificate Exists - Auto-Renew
    echo "Certificate exists at $CRT_FILE. Checking for renewal..."
    
    # We use 'step ca renew' which only renews if necessary (expires soon)
    # The --force flag here forces overwrite of the file ON SUCCESS, not forced renewal if valid?
    # step ca renew defaults to renewing if within 2/3 of lifetime.
    
    # We capture output to avoid spamming logs if it's not time yet, unless it fails.
    if step ca renew "$CRT_FILE" "$KEY_FILE" \
        --ca-url "$STEP_CA_URL" \
        --force 2>/dev/null; then
        
        echo "Certificate renewed successfully."
        # If running in Nginx, we might need to reload?
        # The caller (entrypoint loop or cron) should handle reload.
    else
        echo "Certificate not yet ready for renewal or renewal failed (check logs/connectivity)."
    fi
fi
