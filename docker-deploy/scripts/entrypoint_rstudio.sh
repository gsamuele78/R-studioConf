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

# 1. Template Processing (Config Generation)
# We use envsubst to process templates from /etc/docker-templates into /etc/rstudio
if [ -d "/etc/docker-templates" ]; then
    log "INFO" "Processing RStudio Configuration Templates..."
    
    # RServer.conf
    if [ -f "/etc/docker-templates/rserver.conf.template" ]; then
        # Export vars for envsubst (defaults)
        export RSERVER_WWW_PORT="${RSTUDIO_PORT:-8787}"
        export RSERVER_WWW_ADDRESS="0.0.0.0" # Listen on all interfaces in container
        
        envsubst < /etc/docker-templates/rserver.conf.template > /etc/rstudio/rserver.conf
        log "INFO" "Generated /etc/rstudio/rserver.conf"
    fi
    # PAM (Using generic rstudio pam template if exists)
else
    log "WARN" "No templates found in /etc/docker-templates"
fi

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
