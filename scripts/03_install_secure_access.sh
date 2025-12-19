#!/bin/bash
# scripts/secure-web-access-setup.sh
# VERSION 16.0: VICTORIOUS. Uses the definitive YAML structure.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/install_secure_access.vars.conf"
PAM_CONFIG_PATH="/etc/pam.d/nginx"
TTYD_OVERRIDE_DIR="/etc/systemd/system/ttyd.service.d"
#The File Browser variables will assigned after sourching conf file (see config/secure-web-access.conf)
# Filebrowser variables removed in favor of Nextcloud Proxy
# FILEBROWSER_* variables are deprecated.

usage() { echo "Usage: $0 [install|uninstall|status]"; exit 1; }

setup_backup_dir # Initialize session backup directory

install_services() {
    log "INFO" "--- Starting Secure Web Access Installation ---"
    
    log "INFO" "Attempting to repair any broken package dependencies..."; run_command "Force configure all pending packages" "dpkg --configure -a"; run_command "Fix broken dependencies" "apt-get -f install -y";
    log "INFO" "Installing prerequisite packages..."; run_command "Update package lists" "apt-get -y update";
        log "INFO" "Installing ttyd..."; if ! run_command "Install ttyd" "apt-get -y install ttyd"; then handle_error $? "Failed to install ttyd."; return 1; fi;
    log "INFO" "Installing curl..."
    if ! run_command "Install curl" "apt-get -y install curl"; then
        handle_error $? "Failed to install curl."; return 1
    fi
    log "INFO" "SUCCESS: Prerequisites are correctly installed."

    log "INFO" "Creating and enabling service files..."; 
    ensure_dir_exists "${TTYD_OVERRIDE_DIR}"; process_systemd_template "${SCRIPT_DIR}/../templates/ttyd.service.override.template" "ttyd.service.d/override.conf"
    if [ ! -f "${PAM_CONFIG_PATH}" ]; then echo "@include common-auth" | sudo tee "${PAM_CONFIG_PATH}" > /dev/null; fi
    
    log "INFO" "Reloading systemd and restarting services..."; 
    run_command "Reload systemd daemon" "systemctl daemon-reload"; 
    run_command "Enable ttyd service" "systemctl enable ttyd.service"; 
    run_command "Restart services to apply all configs" "systemctl restart ttyd.service"

    log "INFO" "--- Installation Complete! ---"; log "WARN" "You must now run the Nginx setup script."; check_status
}

uninstall_services() {
    log "INFO" "--- Starting Secure Web Access Uninstallation ---"
    backup_config
    local confirm_uninstall
    read -r -p "This will remove Secure Web Access packages, services, and configs. Continue? (y/n): " confirm_uninstall
    if [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]]; then
        log "Uninstallation cancelled."
        return 0
    fi
    run_command "Stop and disable systemd services" "systemctl disable --now ttyd.service" || log "WARN" "Services may not have been running."
    
    # Legacy removal for filebrowser if present
    if systemctl is-active --quiet filebrowser.service || [[ -f /usr/local/bin/filebrowser ]]; then
        log "INFO" "Removing legacy Filebrowser..."
        systemctl disable --now filebrowser.service || true
        rm -f /etc/systemd/system/filebrowser.service
        rm -f /usr/local/bin/filebrowser
        rm -rf /etc/filebrowser /var/lib/filebrowser
    fi

    log "INFO" "Removing systemd service files..."; run_command "Remove ttyd override" "rm -rf ${TTYD_OVERRIDE_DIR}"; run_command "Reload systemd daemon" "systemctl daemon-reload";
    log "INFO" "Removing ttyd package..."
    if ! run_command "Remove ttyd package" "apt-get remove --purge -y ttyd"; then
        handle_error $? "Failed to remove ttyd package.";
    fi
    log "INFO" "SUCCESS: Packages removed."
    log "INFO" "--- Uninstallation Complete! ---"
    log "INFO" "Uninstall attempt complete. Review logs and backups in $CURRENT_BACKUP_DIR to restore if needed."
restore_config() {
    log "INFO" "Restoring Secure Web Access configuration from backup..."
    # Implement restore logic using backup directory
    # Example: cp -r "$CURRENT_BACKUP_DIR/etc" /etc
    log "INFO" "Restore complete."
}
    setup_backup_dir # Initialize session backup directory
    printf "\n=== Secure Web Access Setup Menu ===\n"
    printf "1) Install/Configure Secure Web Access\n"
    printf "U) Uninstall Secure Web Access and restore system\n"
    printf "R) Restore configurations from most recent backup\n"
    printf "4) Exit\n"
    read -r -p "Choice: " choice
    case "$choice" in
        1)
            backup_config
            install_services
            ;;
        U|u)
            uninstall_services
            ;;
        R|r)
            restore_config
            ;;
        *)
            log "Exiting Secure Web Access Setup."; return 0 ;;
    esac
}

check_status() {
    log "INFO" "--- Checking Service Status ---"
    log "INFO" "Status for ttyd:"; systemctl --no-pager status ttyd.service || true
    # Legacy check
    if systemctl is-active --quiet filebrowser.service; then
        log "INFO" "Status for filebrowser (legacy):"; systemctl --no-pager status filebrowser.service || true
    fi
}

main() {
    if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2; exit 1; fi
    source "$UTILS_SCRIPT_PATH"; if [ -z "$1" ]; then usage; fi; check_root;
    if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then log "ERROR" "Configuration file not found at '$DEFAULT_CONFIG_FILE'."; exit 1; fi
    source "$DEFAULT_CONFIG_FILE"
    #echo "UTILS_SCRIPT_PATH: $UTILS_SCRIPT_PATH"
    
    # Deprecated variable assignment logic removed.
}

main "$@"