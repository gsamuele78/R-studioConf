#!/bin/bash
# scripts/secure-web-access-setup.sh

# A manager script for installing, uninstalling, and checking secure web access services.
# It uses Nginx with PAM for authentication and proxies to ttyd (web terminal)
# and File Browser (web file manager).
# VERSION 3.0: FINAL. Initializes File Browser DB and configures ttyd via /etc/default/ttyd.

set -e

# --- Robust Path Detection ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Define Global Paths ---
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/secure-web-access.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
PAM_CONFIG_PATH="/etc/pam.d/nginx"
TTYD_DEFAULT_CONFIG="/etc/default/ttyd"

# --- Function Definitions ---
usage() {
    echo -e "\033[1;33mUsage: $0 [action]\033[0m"
    echo "Actions:"
    echo -e "  \033[0;36minstall\033[0m    - Installs and enables ttyd and File Browser with Nginx PAM auth."
    echo -e "  \033[0;36muninstall\033[0m  - Stops, disables, and removes the services and packages."
    echo -e "  \033[0;36mstatus\033[0m     - Checks the status of the ttyd and filebrowser services."
    exit 1
}

install_services() {
    log "INFO" "--- Starting Secure Web Access Installation ---"
    
    log "INFO" "Updating package lists..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
        handle_error $? "Failed to update package lists."; return 1;
    fi; log "INFO" "SUCCESS: Package lists updated."

    log "INFO" "Installing prerequisite packages (ttyd, nginx-auth-pam)..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ttyd libnginx-mod-http-auth-pam; then
        handle_error $? "Failed to install prerequisite packages."; return 1;
    fi; log "INFO" "SUCCESS: Prerequisite packages installed."

    log "INFO" "Downloading and installing File Browser..."
    if ! curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash; then
        handle_error $? "Failed to install File Browser."; return 1;
    fi; log "INFO" "SUCCESS: File Browser installer finished."

    # ### FINAL DEFINITIVE FIX for File Browser ###
    log "INFO" "Initializing File Browser configuration..."
    local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}")
    ensure_dir_exists "$fb_db_dir"
    run_command "Set ownership for File Browser data dir" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${fb_db_dir}"
    
    # 1. Initialize the database file as the correct user
    run_command "Initialize File Browser database" "sudo -u ${FILEBROWSER_USER} filebrowser config init --database ${FILEBROWSER_DB_PATH}"
    # 2. Set the authentication method to 'proxy' in the new database
    run_command "Set File Browser auth method to proxy" "sudo -u ${FILEBROWSER_USER} filebrowser config set --auth.method proxy --database ${FILEBROWSER_DB_PATH}"
    # 3. Set the proxy header in the new database
    run_command "Set File Browser proxy header" "sudo -u ${FILEBROWSER_USER} filebrowser config set --auth.proxy.header 'X-Forwarded-User' --database ${FILEBROWSER_DB_PATH}"
    
    log "INFO" "Creating and enabling File Browser service..."
    process_systemd_template "filebrowser.service.template" "filebrowser.service"
    
    # ### FINAL DEFINITIVE FIX for ttyd ###
    log "INFO" "Configuring ttyd via ${TTYD_DEFAULT_CONFIG}..."
    # This overwrites the default config file with our specific settings.
    echo "TTYD_OPTIONS='--port ${WEB_TERMINAL_PORT} --writable --once login'" | sudo tee "${TTYD_DEFAULT_CONFIG}" > /dev/null
    
    log "INFO" "Creating PAM service configuration for Nginx at ${PAM_CONFIG_PATH}"
    echo "@include common-auth" | sudo tee "${PAM_CONFIG_PATH}" > /dev/null
    
    log "INFO" "Enabling and restarting services..."
    run_command "Reload systemd daemon" "systemctl daemon-reload"
    run_command "Enable File Browser and restart ttyd" "systemctl enable --now filebrowser.service && systemctl restart ttyd.service"

    log "INFO" "--- Installation Complete! ---"
    log "WARN" "You must now re-run the Nginx setup script to apply the new proxy configuration."
    check_status
}

uninstall_services() {
    log "INFO" "--- Starting Secure Web Access Uninstallation ---"

    run_command "Stop and disable systemd services" "systemctl disable --now ttyd.service filebrowser.service" || log "WARN" "Services may not have been running."
    
    log "INFO" "Removing systemd service files and config..."
    sudo rm -f /etc/systemd/system/filebrowser.service "${PAM_CONFIG_PATH}" "${TTYD_DEFAULT_CONFIG}"
    run_command "Reload systemd daemon" "systemctl daemon-reload"

    log "INFO" "Removing packages, binaries, and data..."
    run_command "Remove filebrowser binary" "rm -f /usr/local/bin/filebrowser"
    local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}")
    run_command "Remove filebrowser data directory" "rm -rf ${fb_db_dir}"
    
    log "INFO" "Removing ttyd and Nginx PAM module..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ttyd libnginx-mod-http-auth-pam; then
        handle_error $? "Failed to remove packages.";
    fi; log "INFO" "SUCCESS: Packages removed."

    log "INFO" "--- Uninstallation Complete! ---"
}

check_status() {
    log "INFO" "--- Checking Service Status ---"
    systemctl status --no-pager ttyd.service filebrowser.service || true
}

# --- Main Execution ---
# (This function remains unchanged)
main() {
    if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
        printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2; exit 1;
    fi; source "$UTILS_SCRIPT_PATH"
    if [ -z "$1" ]; then usage; fi; check_root
    if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then
        log "ERROR" "Configuration file not found at '$DEFAULT_CONFIG_FILE'."; exit 1;
    fi; source "$DEFAULT_CONFIG_FILE"
    case "$1" in
        install) install_services ;; uninstall) uninstall_services ;; status) check_status ;; *) usage ;;
    esac
}

main "$@"