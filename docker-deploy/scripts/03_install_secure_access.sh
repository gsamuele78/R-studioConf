#!/bin/bash
# docker-deploy/scripts/03_install_secure_access.sh
# Verifies TTYD and Xterm installation in the specific container context.
# Sources configuration from ../.env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Source Common Utils
if [ -f "${SCRIPT_DIR}/../lib/common_utils.sh" ]; then
    source "${SCRIPT_DIR}/../lib/common_utils.sh"
else
    echo "ERROR: common_utils.sh not found."
    exit 1
fi

# Docker Deploy: Source .env instead of legacy config
if [ -f "$ENV_FILE" ]; then
    log "INFO" "Sourcing configuration from .env..."
    set -a
    source "$ENV_FILE"
    set +a
else
    log "WARN" ".env file not found at $ENV_FILE"
fi

install_services() {
    log "INFO" "--- Verifying Secure Access (Docker) ---"
    
    # In Docker, we rely on the implementation in the Image
    log "INFO" "Checking if TTYD is installed in container context..."
    if command -v ttyd &>/dev/null; then
        log "INFO" "SUCCESS: ttyd is installed."
    else
        log "WARN" "ttyd is NOT found. If running inside container, please rebuild."
    fi

    log "INFO" "Checking TTYD Login Wrapper..."
    if [ -f "/usr/local/bin/ttyd_login_wrapper.sh" ]; then
        log "INFO" "SUCCESS: ttyd_login_wrapper is present."
    else
        log "WARN" "ttyd_login_wrapper is missing from /usr/local/bin."
    fi

    log "INFO" "Secure Access services are managed by S6 overlay."
}

uninstall_services() {
    log "INFO" "Uninstallation in Docker means rebuilding the image without these components."
}

main() {
    case "$1" in
        install) install_services ;;
        uninstall) uninstall_services ;;
        *) install_services ;;
    esac
}

main "$@"
