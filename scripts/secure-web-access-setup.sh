#!/bin/bash
# scripts/secure-web-access-setup.sh
# VERSION 14.0: VICTORIOUS. Actively repairs dpkg state before installation.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/secure-web-access.conf"
PAM_CONFIG_PATH="/etc/pam.d/nginx"
TTYD_OVERRIDE_DIR="/etc/systemd/system/ttyd.service.d"
FILEBROWSER_INIT_SCRIPT_DEST="/usr/local/bin/init-filebrowser.sh"

usage() {
    echo -e "\033[1;33mUsage: $0 [action]\033[0m"
    echo "Actions:"
    echo -e "  \033[0;36minstall\033[0m    - Installs ttyd and the gtsteffaniak/filebrowser fork."
    echo -e "  \033[0;36muninstall\033[0m  - Stops, disables, and removes the services and packages."
    echo -e "  \033[0;36mstatus\033[0m     - Checks the status of the services."
    exit 1
}

install_services() {
    log "INFO" "--- Starting Secure Web Access Installation (API method) ---"
    
    # ### DEFINITIVE FIX: Repair any broken package manager state first ###
    log "INFO" "Attempting to repair any broken package dependencies..."
    run_command "Force configure all pending packages" "DEBIAN_FRONTEND=noninteractive dpkg --configure -a"
    run_command "Fix broken dependencies" "DEBIAN_FRONTEND=noninteractive apt-get -f install -y"
    
    log "INFO" "Installing prerequisite packages (ttyd and curl)..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y ttyd curl; then 
        handle_error $? "Failed to install prerequisites."; return 1; 
    fi; log "INFO" "SUCCESS: Prerequisites installed."
    
    log "INFO" "Downloading gtsteffaniak/filebrowser fork..."; local LATEST_URL="https://github.com/gtsteffaniak/filebrowser/releases/latest/download/linux-amd64-filebrowser"; local BINARY_PATH="/usr/local/bin/filebrowser"; run_command "Download filebrowser binary" "curl -L -o ${BINARY_PATH} \"${LATEST_URL}\""; run_command "Set executable permission for filebrowser" "chmod +x ${BINARY_PATH}"; log "INFO" "SUCCESS: gtsteffaniak/filebrowser has been installed."

    log "INFO" "Copying File Browser init script..."; run_command "Copy init script" "cp ${SCRIPT_DIR}/init-filebrowser.sh ${FILEBROWSER_INIT_SCRIPT_DEST}"; run_command "Make init script executable" "chmod +x ${FILEBROWSER_INIT_SCRIPT_DEST}";
    local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}"); ensure_dir_exists "$fb_db_dir"; run_command "Set ownership for File Browser data dir" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${fb_db_dir}";

    log "INFO" "Creating and enabling File Browser service..."
    process_systemd_template "${SCRIPT_DIR}/../templates/filebrowser.service.template" "filebrowser.service"
    
    log "INFO" "Creating systemd override to configure ttyd..."
    ensure_dir_exists "${TTYD_OVERRIDE_DIR}"
    process_systemd_template "${SCRIPT_DIR}/../templates/ttyd.service.override.template" "ttyd.service.d/override.conf"

    log "INFO" "Creating PAM service configuration for Nginx (if not exists)..."
    if [ ! -f "${PAM_CONFIG_PATH}" ]; then
        echo "@include common-auth" | sudo tee "${PAM_CONFIG_PATH}" > /dev/null
    fi
    
    log "INFO" "Reloading systemd and restarting services..."
    run_command "Reload systemd daemon" "systemctl daemon-reload"
    run_command "Enable ttyd service" "systemctl enable ttyd.service"
    run_command "Enable filebrowser service" "systemctl enable filebrowser.service"
    run_command "Restart services to apply all configs" "systemctl restart ttyd.service filebrowser.service"

    log "INFO" "--- Installation Complete! ---"
    log "WARN" "You must now run the Nginx setup script to apply the new proxy configuration."
    check_status
}

uninstall_services() {
    log "INFO" "--- Starting Secure Web Access Uninstallation ---"
    run_command "Stop and disable systemd services" "systemctl disable --now ttyd.service filebrowser.service" || log "WARN" "Services may not have been running."
    
    log "INFO" "Removing systemd service files and config..."
    sudo rm -f /etc/systemd/system/filebrowser.service
    run_command "Remove ttyd override" "rm -rf ${TTYD_OVERRIDE_DIR}"
    # We do not remove the shared PAM config file on uninstall, as other services might need it.
    
    run_command "Reload systemd daemon" "systemctl daemon-reload"
    
    log "INFO" "Removing packages, binaries, and data..."
    run_command "Remove filebrowser binary" "rm -f /usr/local/bin/filebrowser"
    run_command "Remove filebrowser init script" "rm -f ${FILEBROWSER_INIT_SCRIPT_DEST}"
    local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}"); run_command "Remove filebrowser data directory" "rm -rf ${fb_db_dir}"; 
    
    log "INFO" "Removing ttyd package..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ttyd; then 
        handle_error $? "Failed to remove ttyd package."; 
    fi
    log "INFO" "SUCCESS: Packages removed."
    log "INFO" "--- Uninstallation Complete! ---"
}

check_status() {
    log "INFO" "--- Checking Service Status ---"
    systemctl status --no-pager ttyd.service filebrowser.service || true
}

main() {
    if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
        printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2
        exit 1
    fi
    source "$UTILS_SCRIPT_PATH"

    if [ -z "$1" ]; then
        usage
    fi
    check_root

    if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then
        log "ERROR" "Configuration file not found at '$DEFAULT_CONFIG_FILE'."
        exit 1
    fi
    source "$DEFAULT_CONFIG_FILE"

    case "$1" in
        install)
            install_services
            ;;
        uninstall)
            uninstall_services
            ;;
        status)
            check_status
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"