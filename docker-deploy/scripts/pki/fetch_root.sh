#!/bin/bash
set -euo pipefail

# =====================================================================
# fetch_root.sh - Step-CA Integration
# =====================================================================
# Fetches the Root CA certificate from a remote Step-CA server using 'step'.
# Adapts logic from Infra-Iam-PKI for Docker usage.
# =====================================================================

DEFAULT_OUTPUT="/usr/local/share/ca-certificates/step_root_ca.crt"
OUTPUT_FILE=${1:-$DEFAULT_OUTPUT}

# Config from Env
: "${STEP_CA_URL:=${CA_URL:-}}"
: "${STEP_FINGERPRINT:=${CA_FINGERPRINT:-}}"

if [ -z "$STEP_CA_URL" ] || [ -z "$STEP_FINGERPRINT" ]; then
    echo "WARN: STEP_CA_URL or STEP_FINGERPRINT not set. Skipping Step-CA Root Fetch."
    exit 0
fi

if ! command -v step &> /dev/null; then
    echo "ERROR: 'step' command not found. Cannot fetch root CA via Step protocol."
    exit 1
fi

echo "Fetching Root CA from $STEP_CA_URL..."
echo "Fingerprint: $STEP_FINGERPRINT"

# Create output dir if missing
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Fetch Root CA
# --force overwrites if exists
step ca root "$OUTPUT_FILE" \
    --ca-url "$STEP_CA_URL" \
    --fingerprint "$STEP_FINGERPRINT" \
    --force

if [ -s "$OUTPUT_FILE" ]; then
    echo "Success: Root CA saved to $OUTPUT_FILE"
    chmod 644 "$OUTPUT_FILE"
    
    # Update system trust store
    if command -v update-ca-certificates &>/dev/null; then
        update-ca-certificates >/dev/null
        echo "System trust store updated."
    fi
else
    echo "Error: Failed to fetch Root CA."
    exit 1
fi
