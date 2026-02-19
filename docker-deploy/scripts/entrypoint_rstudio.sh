#!/bin/bash
# entrypoint_rstudio.sh
# Unified entrypoint for RStudio Docker Containers
# Handles Auth (SSSD/Samba) and detailed RStudio Configuration

set -e

# Source Common Utils if available (mirrored)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
COMMON_UTILS="/rocker_scripts/lib/common_utils.sh"
# If not in rocker_scripts, try local relative path for dev
if [ ! -f "$COMMON_UTILS" ]; then
    COMMON_UTILS="${SCRIPT_DIR}/../lib/common_utils.sh"
fi

if [ -f "$COMMON_UTILS" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_UTILS"
    log "INFO" "Sourced common_utils.sh"
else
    echo "WARNING: common_utils.sh not found. Logging will be basic."
    log() { echo "[$1] $2"; }
fi

log "INFO" "Starting RStudio Container Entrypoint..."
log "INFO" "Auth Backend: ${AUTH_BACKEND}"

# 0. PKI Trust Setup (Step-CA)
if [ -n "${STEP_CA_URL:-}" ]; then
    log "INFO" "STEP_CA_URL detected. Configuring PKI Trust..."
    
    # 1. Fetch Root CA (Trust)
    # The script uses step-cli to fetch and install the root securely
    if [ -f "/scripts/pki/fetch_root.sh" ]; then
        /scripts/pki/fetch_root.sh || log "WARN" "Failed to fetch Root CA (using fetch_root.sh)."
    elif [ -x "/usr/local/bin/manage_pki_trust.sh" ]; then
        # Fallback to simple curl method if step script missing
        /usr/local/bin/manage_pki_trust.sh "${STEP_CA_URL}" "${STEP_FINGERPRINT:-}" || log "WARN" "PKI Trust Setup Failed."
    fi
fi

# 1. Template Processing (Config Generation)
# 1. RStudio Configuration (Native)
log "INFO" "Configuring RStudio Server (Native)..."

# 1.1 PAM Configuration
# We implicitly trust the system's PAM stack (common-auth, etc.) which uses SSSD/Winbind
# This mirrors the legacy script's configure_rstudio_pam function.
if [ ! -f "/etc/pam.d/rstudio" ]; then
    log "INFO" "Generating /etc/pam.d/rstudio..."
    cat > /etc/pam.d/rstudio <<EOF
#%PAM-1.0
@include common-auth
@include common-account
@include common-password
@include common-session
EOF
fi

# 1.2 RServer Configuration (rserver.conf)
# We use envsubst if template exists, AND append specific security overlays
if [ -f "/etc/docker-templates/rserver.conf.template" ]; then
    export RSERVER_WWW_PORT="${RSTUDIO_PORT:-8787}"
    export RSERVER_WWW_ADDRESS="0.0.0.0" 
    envsubst < /etc/docker-templates/rserver.conf.template > /etc/rstudio/rserver.conf
else
    # Fallback minimal config
    echo "www-port=${RSTUDIO_PORT:-8787}" > /etc/rstudio/rserver.conf
    echo "www-address=0.0.0.0" >> /etc/rstudio/rserver.conf
fi

# Append Legacy Script Security & Iframe Settings
{
    echo "www-frame-origin=same"
    echo "www-same-site=none"
    echo "www-enable-origin-check=1"
    echo "auth-pam-require-password-prompt=0"
    echo "auth-encrypt-password=0"
    echo "auth-cookies-force-secure=1" 
} >> /etc/rstudio/rserver.conf

# 1.3 RSession Configuration (rsession.conf)
# Mirrors configure_rstudio_session_env_settings
cat > /etc/rstudio/rsession.conf <<EOF
session-timeout-minutes=${RSESSION_TIMEOUT_MINUTES:-10080}
websocket-log-level=${RSESSION_WEBSOCKET_LOG_LEVEL:-1}
session-handle-offline-enabled=1
session-connections-block-suspend=1
session-external-pointers-block-suspend=1
copilot-enabled=${RSESSION_COPILOT_ENABLED:-0}
EOF

# 1.4 Environment Variables (env-vars)
cat > /etc/rstudio/env-vars <<EOF
OPENBLAS_NUM_THREADS=${OPENBLAS_NUM_THREADS:-4}
OMP_NUM_THREADS=${OMP_NUM_THREADS:-4}
EOF

log "INFO" "RStudio Configuration Complete."

# 2. Authentication Configuration
if [ "$AUTH_BACKEND" == "sssd" ]; then
    log "INFO" "Configuring SSSD Passthrough..."
    
    # Enable SSS in nsswitch if mounted
    if [ -S "/var/lib/sss/pipes/nss" ]; then
        if ! grep -q "sss" /etc/nsswitch.conf; then
             sed -i 's/passwd: *files/passwd:         files sss/' /etc/nsswitch.conf
             sed -i 's/group: *files/group:          files sss/' /etc/nsswitch.conf
             sed -i 's/shadow: *files/shadow:         files sss/' /etc/nsswitch.conf
             log "INFO" "Updated nsswitch.conf for SSSD"
        fi
    else
        log "WARN" "SSSD backend selected but /var/lib/sss/pipes/nss socket NOT found."
    fi
    
    # Configure PAM to use pam_sss
    # We can create a simple /etc/pam.d/rstudio that uses standard includes
    # which generally include pam_sss if installed.
    if ! grep -q "pam_sss.so" /etc/pam.d/common-auth; then
         log "WARN" "pam_sss.so possibly missing from common-auth."
    fi

elif [ "$AUTH_BACKEND" == "samba" ]; then
    log "INFO" "Configuring Samba/Winbind Passthrough..."
    
    # Enable Winbind in nsswitch
    if ! grep -q "winbind" /etc/nsswitch.conf; then
        sed -i 's/passwd: *files/passwd:         files winbind/' /etc/nsswitch.conf
        sed -i 's/group: *files/group:          files winbind/' /etc/nsswitch.conf
        log "INFO" "Updated nsswitch.conf for Winbind"
    fi
    
    # Ensure accessibility of winbind pipe (permissions ticklish in containers)
    # Usually works if container is privileged or user mappings match.

else
    log "INFO" "No special AD backend configured. Using local auth."
fi


# 3. Ownership Fixes (If needed)
# If mounting /home, ensure permissions are sane? 
# In "Pet" mode, we assume host manages permissions.

# 4. Hand off to S6 Init
log "INFO" "Initialization complete. Starting Services..."
exec "$@"
