#!/bin/bash
# scripts/03_install_secure_access.sh
# VERSION 16.1: FIXED. Corrects dependency loading and structure.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/install_secure_access.vars.conf"
PAM_CONFIG_PATH="/etc/pam.d/nginx"
TTYD_OVERRIDE_DIR="/etc/systemd/system/ttyd.service.d"

usage() { echo "Usage: $0 [install|uninstall|status]"; exit 1; }

install_services() {
    setup_backup_dir
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
    setup_backup_dir
    log "INFO" "--- Starting Secure Web Access Uninstallation ---"
    backup_config
    
    # Non-interactive if confirmed via wrapper, otherwise confirm here?
    # For script consistency, we assume the wrapper handles interaction or we simply proceed if called directly with 'uninstall'
    # BUT, to be safe, we can ask if not NONINTERACTIVE.
    if [[ "${NONINTERACTIVE_CONFIGURED:-}" != "true" ]]; then
         read -r -p "This will remove Secure Web Access packages, services, and configs. Continue? (y/n): " confirm_uninstall
         if [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]]; then
             log "INFO" "Uninstallation cancelled."
             return 0
         fi
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
    source "$UTILS_SCRIPT_PATH"
    
    check_root

    if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then 
        log "WARN" "Configuration file not found at '$DEFAULT_CONFIG_FILE'. Using defaults."
    else
        source "$DEFAULT_CONFIG_FILE"
    fi

    if [ $# -eq 0 ]; then usage; fi

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