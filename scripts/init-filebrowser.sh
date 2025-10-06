#!/bin/bash
# scripts/init-filebrowser.sh

# This script runs after the File Browser service starts. It connects to the API
# and sets the correct proxy authentication settings.

set -e

# Configuration - these values are passed from the main script
FILEBROWSER_URL="${1:-http://127.0.0.1:2223}"
ADMIN_USERNAME="${2:-admin}"
ADMIN_PASSWORD="${3:-admin}"
MAX_RETRIES="${4:-10}"
RETRY_DELAY="${5:-2}"

# Small helper to log messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - INFO - (init-fb) - $1"
}

wait_for_filebrowser() {
    local retries=0
    log "Waiting for File Browser API to be ready..."
    
    while [ $retries -lt $MAX_RETRIES ]; do
        # The health endpoint is /api/health
        if curl -f -s "${FILEBROWSER_URL}/api/health" > /dev/null 2>&1; then
            log "File Browser API is ready!"
            return 0
        fi
        retries=$((retries + 1))
        log "Attempt ${retries}/${MAX_RETRIES} - waiting ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
    done
    
    log "ERROR: File Browser API failed to start after ${MAX_RETRIES} attempts"
    return 1
}

get_auth_token() {
    log "Logging in as initial admin user '${ADMIN_USERNAME}'..."
    
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"${ADMIN_USERNAME}\", \"password\": \"${ADMIN_PASSWORD}\", \"recaptcha\": \"\"}" \
        "${FILEBROWSER_URL}/api/login")
    
    local http_code; http_code=$(echo "$response" | tail -n1)
    local token; token=$(echo "$response" | head -n-1)
    
    if [ "$http_code" -eq 200 ] && [ -n "$token" ]; then
        log "Successfully authenticated!"
        echo "$token"
        return 0
    else
        log "ERROR: Authentication failed (HTTP ${http_code})"
        return 1
    fi
}

configure_settings() {
    local token=$1
    log "Applying proxy auth and dynamic home directory settings via API..."
    
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d '{
            "auth": {
                "method": "proxy",
                "header": "X-Forwarded-User"
            },
            "defaults": {
                "autocreate": true,
                "scope": "/nfs/home/{{ strings.Split .User.Username \"@\" | head 1 }}"
            }
        }' \
        "${FILEBROWSER_URL}/api/settings")

    local http_code; http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" -eq 200 ]; then
        log "SUCCESS: Settings applied successfully."
        return 0
    else
        log "ERROR: Failed to apply settings (HTTP ${http_code})"
        return 1
    fi
}

main() {
    if ! wait_for_filebrowser; then exit 1; fi
    local TOKEN; TOKEN=$(get_auth_token)
    if [ -z "$TOKEN" ]; then exit 1; fi
    if ! configure_settings "$TOKEN"; then exit 1; fi
    log "Initialization complete!"
}

main "$@"