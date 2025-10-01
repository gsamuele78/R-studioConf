#!/bin/bash
# scripts/secure-web-access-setup.sh

# A manager script for installing, uninstalling, and checking secure web access services.
# VERSION 6.1: VICTORIOUS. Adds a dummy user to File Browser to satisfy startup requirements.

set -e

# --- Robust Path Detection ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Define Global Paths ---
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/secure-web-access.conf"
PAM_CONFIG_PATH="/etc/pam.d/nginx"
FILEBROWSER_CONFIG_DIR="/etc/filebrowser"
FILEBROWSER_CONFIG_FILE="${FILEBROWSER_CONFIG_DIR}/.filebrowser.json"
TTYD_OVERRIDE_DIR="/etc/systemd/system/ttyd.service.d"

# --- Function Definitions ---
# (usage function remains the same)
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
    
    log "INFO" "Updating package lists..."; if ! DEBIAN_FRONTEND=noninteractive apt-get update; then handle_error $? "Failed to update package lists."; return 1; fi; log "INFO" "SUCCESS: Package lists updated."
    log "INFO" "Installing prerequisite packages..."; if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ttyd libnginx-mod-http-auth-pam; then handle_error $? "Failed to install prerequisite packages."; return 1; fi; log "INFO" "SUCCESS: Prerequisite packages installed."
    
    ## --- CRITICAL PAM INTEGRATION STEP ---
    #log "INFO" "Ensuring Nginx PAM module is loaded..."
    #local module_line="load_module modules/ngx_http_auth_pam_module.so;"
    ## Check if the line is already present in the main nginx.conf
    #if ! grep -qF -- "$module_line" "$NGINX_CONF_PATH"; then
    #    # If not, add it near the top of the file. '1i' is a sed command to insert at line 1.
    #    run_command "Add PAM module to nginx.conf" "sudo sed -i '1i ${module_line}' ${NGINX_CONF_PATH}"
    #    log "INFO" "SUCCESS: Nginx PAM module loading has been configured."
    #else
    #    log "WARN" "Nginx PAM module is already configured to load."
    #fi
    
    # --- THE DEFINITIVE PERMISSIONS FIX ---
    log "INFO" "Granting Nginx permission to communicate with SSSD..."
    # The 'sasl' group is commonly used to grant services access to authentication daemons.
    # Adding www-data to this group allows Nginx to correctly use PAM with SSSD.
    run_command "Add www-data user to the sasl group" "usermod -a -G sasl www-data"
    log "INFO" "SUCCESS: Nginx permissions have been configured."


    log "INFO" "Downloading and installing File Browser..."; if ! curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash; then handle_error $? "Failed to install File Browser."; return 1; fi; log "INFO" "SUCCESS: File Browser installer finished."

    log "INFO" "Creating static config file for File Browser..."
    ensure_dir_exists "${FILEBROWSER_CONFIG_DIR}"
    cat << EOF > "${FILEBROWSER_CONFIG_FILE}"
{ "address": "127.0.0.1", "port": ${FILEBROWSER_PORT}, "root": "/", "database": "${FILEBROWSER_DB_PATH}", "auth": { "method": "proxy", "proxy": { "header": "X-Forwarded-User" } } }
EOF
    run_command "Set ownership for File Browser config" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${FILEBROWSER_CONFIG_DIR}"

    local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}"); ensure_dir_exists "$fb_db_dir"; run_command "Set ownership for File Browser data dir" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${fb_db_dir}";
    
    # ### DEFINITIVE FIX for File Browser ###
    # 1. Initialize the database.
    run_command "Initialize File Browser database" "sudo -u ${FILEBROWSER_USER} filebrowser config init --database ${FILEBROWSER_DB_PATH}"
    # 2. Add a dummy user to satisfy the startup requirement. The user/pass don't matter.
    run_command "Add dummy user to File Browser DB" "sudo -u ${FILEBROWSER_USER} filebrowser users add dummyuser dummypass!@2025 --database ${FILEBROWSER_DB_PATH}"

    log "INFO" "Creating and enabling File Browser service..."
    process_systemd_template "${SCRIPT_DIR}/../templates/filebrowser.service.template" "filebrowser.service"
    
    log "INFO" "Creating systemd override to configure ttyd..."
    ensure_dir_exists "${TTYD_OVERRIDE_DIR}"
    process_systemd_template "${SCRIPT_DIR}/../templates/ttyd.service.override.template" "ttyd.service.d/override.conf"

    log "INFO" "Creating PAM service configuration for Nginx at ${PAM_CONFIG_PATH}"
    echo "@include common-auth" | sudo tee "${PAM_CONFIG_PATH}" > /dev/null
    
    log "INFO" "Enabling and starting services..."
    run_command "Reload systemd daemon" "systemctl daemon-reload"
    run_command "Enable and start services" "systemctl enable --now filebrowser.service ttyd.service"
    run_command "Restart services to ensure all configs are applied" "systemctl restart filebrowser.service ttyd.service"

    log "INFO" "--- Installation Complete! ---"
    log "WARN" "You must now re-run the Nginx setup script to apply the new proxy configuration."
    check_status
}

# (Other functions remain unchanged)
process_systemd_template() {
    local template_name=$1; local service_name=$2; local template_path="$template_name"; local output_path="/etc/systemd/system/${service_name}"; log "INFO" "Processing template for ${service_name}..."; local temp_file; temp_file=$(mktemp); local sed_script=""; for var in $(grep -o '{{[A-Z_]*}}' "$template_path" | sort -u | tr -d '{}'); do sed_script+="s|{{\s*$var\s*}}|${!var}|g;"; done; sed "$sed_script" "$template_path" > "$temp_file"; sudo mv "$temp_file" "$output_path"; sudo chown root:root "$output_path"; sudo chmod 644 "$output_path"
}
uninstall_services() {
    log "INFO" "--- Starting Secure Web Access Uninstallation ---"; run_command "Stop and disable systemd services" "systemctl disable --now ttyd.service filebrowser.service" || log "WARN" "Services may not have been running."; log "INFO" "Removing systemd service files and config..."; sudo rm -f /etc/systemd/system/filebrowser.service "${PAM_CONFIG_PATH}"; run_command "Remove ttyd override" "rm -rf ${TTYD_OVERRIDE_DIR}"; run_command "Reload systemd daemon" "systemctl daemon-reload"; log "INFO" "Removing packages, binaries, and data..."; run_command "Remove filebrowser binary" "rm -f /usr/local/bin/filebrowser"; local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}"); run_command "Remove filebrowser data directory" "rm -rf ${fb_db_dir}"; run_command "Remove File Browser config dir" "rm -rf ${FILEBROWSER_CONFIG_DIR}"; log "INFO" "Removing ttyd and Nginx PAM module..."; if ! DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ttyd libnginx-mod-http-auth-pam; then handle_error $? "Failed to remove packages."; fi; log "INFO" "SUCCESS: Packages removed."; log "INFO" "--- Uninstallation Complete! ---"
}
check_status() {
    log "INFO" "--- Checking Service Status ---"; systemctl status --no-pager ttyd.service filebrowser.service || true
}
main() {
    if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2; exit 1; fi; source "$UTILS_SCRIPT_PATH"; if [ -z "$1" ]; then usage; fi; check_root; if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then log "ERROR" "Configuration file not found at '$DEFAULT_CONFIG_FILE'."; exit 1; fi; source "$DEFAULT_CONFIG_FILE"; case "$1" in install) install_services ;; uninstall) uninstall_services ;; status) check_status ;; *) usage ;; esac
}

main "$@"