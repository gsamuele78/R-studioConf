#!/bin/bash
# A manager script for installing SSSD-authenticated web services (ttyd, File Browser).

set -e

# --- Robust Path Detection & Global Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# --- Define Global Paths ---
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/web_services.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
PAM_NGINX_FILE="/etc/pam.d/nginx"


# --- Function Definitions ---

usage() {
    echo -e "\033[1;33mUsage: $0 [action]\033[0m"
    echo "Actions:"
    echo -e "  \033[0;36minstall\033[0m    - Installs and enables ttyd and wetty services."
    echo -e "  \033[0;36muninstall\033[0m  - Stops, disables, and removes the services and packages."
    echo -e "  \033[0;36mstatus\033[0m     - Checks the status of the ttyd and wetty services."
    exit 1
}



# NEW: Function to set up PAM for Nginx
setup_nginx_pam() {
    log "INFO" "Ensuring PAM is configured for Nginx..."
    if [[ -f "$PAM_NGINX_FILE" ]]; then
        log "INFO" "PAM config for Nginx already exists."
        return 0
    fi
    # This tells PAM to use the system's standard authentication stack (which includes SSSD)
    cat <<EOF | sudo tee "$PAM_NGINX_FILE" > /dev/null
#%PAM-1.0
@include common-auth;
@include common-account;
@include common-password;
@include common-session;
EOF
    log "INFO" "Created PAM configuration at $PAM_NGINX_FILE"
}

# NEW: Function to initialize File Browser
initialize_filebrowser() {
    log "INFO" "Initializing File Browser configuration..."
    ensure_dir_exists "$(dirname "$FILE_BROWSER_DB_PATH")"
    sudo chown "$FILE_BROWSER_USER":"$FILE_BROWSER_USER" "$(dirname "$FILE_BROWSER_DB_PATH")"
    
    # Configure File Browser to use a proxy authentication model
    # It will trust the 'X-Forwarded-User' header from Nginx
    sudo -u "$FILE_BROWSER_USER" filebrowser config init --database "$FILE_BROWSER_DB_PATH"
    sudo -u "$FILE_BROWSER_USER" filebrowser config set --auth.method=proxy --header=X-Forwarded-User --database "$FILE_BROWSER_DB_PATH"
    log "INFO" "File Browser configured for proxy authentication."
}

install_services() {
    log "INFO" "--- Starting SSSD-Integrated Web Services Installation ---"
    
    # MODIFIED: Install ttyd, filebrowser, and the Nginx PAM module
    run_command "Update package lists" "apt-get update"
    run_command "Install packages" "apt-get install -y ttyd filebrowser libnginx-mod-http-auth-pam"

    setup_nginx_pam
    
    log "INFO" "Creating and enabling systemd services..."
    # MODIFIED: Use new/updated templates
    process_systemd_template "ttyd.service.template" "ttyd.service"
    process_systemd_template "filebrowser.service.template" "filebrowser.service"
    
    initialize_filebrowser

    run_command "Reload systemd daemon" "systemctl daemon-reload"
    run_command "Enable and start services" "systemctl enable --now ttyd.service filebrowser.service"

    log "INFO" "--- Installation Complete! ---"
    check_status
}

uninstall_services() {
    log "INFO" "--- Starting Web Services Uninstallation ---"

    run_command "Stop and disable services" "systemctl disable --now ttyd.service filebrowser.service" || log "WARN" "Services may not have been running."
    
    log "INFO" "Removing systemd service files..."
    sudo rm -f /etc/systemd/system/ttyd.service /etc/systemd/system/filebrowser.service
    run_command "Reload systemd daemon" "systemctl daemon-reload"

    # MODIFIED: Purge the new packages
    run_command "Remove packages" "apt-get remove --purge -y ttyd filebrowser libnginx-mod-http-auth-pam"
    
    log "INFO" "Cleaning up configuration files..."
    sudo rm -f "$PAM_NGINX_FILE"
    sudo rm -rf "$(dirname "$FILE_BROWSER_DB_PATH")"

    log "INFO" "--- Uninstallation Complete! ---"
}

check_status() {
    log "INFO" "--- Checking Service Status ---"
    systemctl status --no-pager ttyd.service filebrowser.service || true
}

# --- Main Execution ---
main() {
    # ... (main function can remain mostly the same, just ensure it sources the correct config file) ...
}

main "$@"