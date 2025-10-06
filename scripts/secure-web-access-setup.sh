#!/bin/bash
# scripts/secure-web-access-setup.sh

# A manager script for installing, uninstalling, and checking secure web access services.
# VERSION 7.0: Migrated to gtsteffaniak/filebrowser fork for robust multi-user support.

set -e

# --- Robust Path Detection ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Define Global Paths ---
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/secure-web-access.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
PAM_CONFIG_PATH="/etc/pam.d/nginx"
FILEBROWSER_CONFIG_DIR="/etc/filebrowser"
FILEBROWSER_CONFIG_FILE="${FILEBROWSER_CONFIG_DIR}/config.yml"
TTYD_OVERRIDE_DIR="/etc/systemd/system/ttyd.service.d"

# --- Function Definitions ---
# (usage function remains the same)
usage() {
    echo -e "\033[1;33mUsage: $0 [action]\033[0m"
    echo "Actions:"
    echo -e "  \033[0;36minstall\033[0m    - Installs ttyd and the gtsteffaniak/filebrowser fork."
    echo -e "  \033[0;36muninstall\033[0m  - Stops, disables, and removes the services and packages."
    echo -e "  \033[0;36mstatus\033[0m     - Checks the status of the services."
    exit 1
}

install_services() {
    log "INFO" "--- Starting Secure Web Access Installation (gtsteffaniak/filebrowser fork) ---"
    
    run_command "Update package lists" "apt-get update"
    run_command "Install prerequisite packages" "apt-get install -y ttyd libnginx-mod-http-auth-pam curl"

    # ### MIGRATION: Download the gtsteffaniak fork binary ###
    log "INFO" "Downloading and installing gtsteffaniak/filebrowser fork..."
    local release_url="https://github.com/gtsteffaniak/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz"
    local download_cmd="curl -L \"${release_url}\" | tar -xz -C /usr/local/bin/"
    if ! run_command "Install gtsteffaniak/filebrowser" "$download_cmd"; then
        handle_error $? "Failed to download or extract filebrowser."; return 1;
    fi; log "INFO" "SUCCESS: gtsteffaniak/filebrowser installed."

    # ### MIGRATION: Create the new YAML config file ###
    log "INFO" "Creating static YAML config file for File Browser..."
    ensure_dir_exists "${FILEBROWSER_CONFIG_DIR}"
    process_systemd_template "${TEMPLATE_DIR}/filebrowser.config.yml.template" "${FILEBROWSER_CONFIG_FILE}"

    log "INFO" "Creating and enabling File Browser service..."
    process_systemd_template "${TEMPLATE_DIR}/filebrowser.service.template" "filebrowser.service"
    
    log "INFO" "Creating systemd override to configure ttyd..."
    ensure_dir_exists "${TTYD_OVERRIDE_DIR}"
    process_systemd_template "${TEMPLATE_DIR}/ttyd.service.override.template" "ttyd.service.d/override.conf"

    log "INFO" "Creating PAM service configuration for Nginx at ${PAM_CONFIG_PATH}"
    echo "@include common-auth" | sudo tee "${PAM_CONFIG_PATH}" > /dev/null
    
    log "INFO" "Enabling and restarting services..."
    run_command "Reload systemd daemon" "systemctl daemon-reload"
    run_command "Enable and start services" "systemctl enable --now filebrowser.service ttyd.service"
    run_command "Restart services to ensure all configs are applied" "systemctl restart filebrowser.service ttyd.service"

    log "INFO" "--- Installation Complete! ---"
    log "WARN" "You must now re-run the Nginx setup script to apply the new proxy configuration."
    check_status
}

# (Helper function process_systemd_template needs a small update to work with any path)
process_systemd_template() {
    local template_path=$1
    local output_path=$2 # Can now be a full path
    log "INFO" "Processing template ${template_path} -> ${output_path}..."
    local temp_file; temp_file=$(mktemp)
    # This sed script replaces all {{VAR}} placeholders with shell variables of the same name
    # It reads the variables from the template itself to be dynamic
    local sed_script=""; for var in $(grep -o '{{[A-Z_]*}}' "$template_path" | sort -u | tr -d '{}'); do sed_script+="s|{{\s*$var\s*}}|${!var}|g;"; done
    sed "$sed_script" "$template_path" > "$temp_file"
    sudo mv "$temp_file" "$output_path"
    sudo chown root:root "$output_path"
}

# (Other functions remain unchanged but are included for completeness)
uninstall_services() { log "INFO" "--- Starting Secure Web Access Uninstallation ---"; run_command "Stop and disable systemd services" "systemctl disable --now ttyd.service filebrowser.service" || log "WARN" "Services may not have been running."; log "INFO" "Removing systemd service files and config..."; sudo rm -f /etc/systemd/system/filebrowser.service "${PAM_CONFIG_PATH}"; run_command "Remove ttyd override" "rm -rf ${TTYD_OVERRIDE_DIR}"; run_command "Reload systemd daemon" "systemctl daemon-reload"; log "INFO" "Removing packages, binaries, and data..."; run_command "Remove filebrowser binary" "rm -f /usr/local/bin/filebrowser"; run_command "Remove File Browser config dir" "rm -rf ${FILEBROWSER_CONFIG_DIR}"; log "INFO" "Removing ttyd and Nginx PAM module..."; if ! DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ttyd libnginx-mod-http-auth-pam; then handle_error $? "Failed to remove packages."; fi; log "INFO" "SUCCESS: Packages removed."; log "INFO" "--- Uninstallation Complete! ---"; }
check_status() { log "INFO" "--- Checking Service Status ---"; systemctl status --no-pager ttyd.service filebrowser.service || true; }
main() { if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2; exit 1; fi; source "$UTILS_SCRIPT_PATH"; if [ -z "$1" ]; then usage; fi; check_root; if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then log "ERROR" "Configuration file not found at '$DEFAULT_CONFIG_FILE'."; exit 1; fi; source "$DEFAULT_CONFIG_FILE"; case "$1" in install) install_services ;; uninstall) uninstall_services ;; status) check_status ;; *) usage ;; esac; }

main "$@"