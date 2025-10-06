#!/bin/bash
# scripts/secure-web-access-setup.sh

# A manager script for installing, uninstalling, and checking secure web access services.
# VERSION 7.0: Migrated to the gtsteffaniak/filebrowser fork for superior proxy integration.

set -e

# --- Robust Path Detection ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Define Global Paths ---
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/secure-web-access.conf"
PAM_CONFIG_PATH="/etc/pam.d/nginx"
FILEBROWSER_CONFIG_DIR="/etc/filebrowser"
FILEBROWSER_CONFIG_FILE="${FILEBROWSER_CONFIG_DIR}/filebrowser.yml" # Switched to YAML
TTYD_OVERRIDE_DIR="/etc/systemd/system/ttyd.service.d"

# --- Function Definitions ---
# (usage function remains the same)
usage() {
    echo -e "\033[1;33mUsage: $0 [action]\033[0m"
    echo "Actions:"
    echo -e "  \033[0;36minstall\033[0m    - Installs ttyd and gtsteffaniak/filebrowser fork."
    echo -e "  \033[0;36muninstall\033[0m  - Stops, disables, and removes the services and packages."
    echo -e "  \033[0;36mstatus\033[0m     - Checks the status of the services."
    exit 1
}

install_services() {
    log "INFO" "--- Starting Secure Web Access Installation (using gtsteffaniak/filebrowser fork) ---"
    
    log "INFO" "Updating package lists..."; if ! DEBIAN_FRONTEND=noninteractive apt-get update; then handle_error $? "Failed to update package lists."; return 1; fi; log "INFO" "SUCCESS: Package lists updated."
    log "INFO" "Installing prerequisite packages..."; if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ttyd libnginx-mod-http-auth-pam curl; then handle_error $? "Failed to install prerequisite packages."; return 1; fi; log "INFO" "SUCCESS: Prerequisite packages installed."

    # ### MODIFIED: Install the gtsteffaniak fork ###
    log "INFO" "Downloading and installing gtsteffaniak/filebrowser fork..."
    local LATEST_URL="https://github.com/gtsteffaniak/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz"
    run_command "Download filebrowser fork" "curl -L -o /tmp/filebrowser.tar.gz \"${LATEST_URL}\""
    run_command "Extract filebrowser binary" "tar -xvzf /tmp/filebrowser.tar.gz -C /usr/local/bin/ filebrowser"
    run_command "Clean up downloaded archive" "rm /tmp/filebrowser.tar.gz"
    log "INFO" "SUCCESS: gtsteffaniak/filebrowser has been installed."

    # ### MODIFIED: Create YAML configuration from a template ###
    log "INFO" "Creating YAML config file for File Browser..."
    ensure_dir_exists "${FILEBROWSER_CONFIG_DIR}"
    process_systemd_template "${SCRIPT_DIR}/../config/filebrowser.yml" "${FILEBROWSER_CONFIG_DIR}/filebrowser.yml"
    run_command "Set ownership for File Browser config" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${FILEBROWSER_CONFIG_DIR}"

    # The database only needs to be created, not configured via CLI
    local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}"); ensure_dir_exists "$fb_db_dir";
    run_command "Set ownership for File Browser data dir" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${fb_db_dir}";
    # We no longer need to add a dummy user.

    log "INFO" "Creating and enabling File Browser service..."
    process_systemd_template "${SCRIPT_DIR}/../templates/filebrowser.service.template" "filebrowser.service"
    
    log "INFO" "Creating systemd override to configure ttyd..."
    ensure_dir_exists "${TTYD_OVERRIDE_DIR}"
    process_systemd_template "${SCRIPT_DIR}/../templates/ttyd.service.override.template" "ttyd.service.d/override.conf"

    log "INFO" "Creating PAM service configuration for Nginx at ${PAM_CONFIG_PATH}"
    echo "@include common-auth" | sudo tee "${PAM_CONFIG_PATH}" > /dev/null
    
    log "INFO" "Enabling and restarting services..."
    run_command "Reload systemd daemon" "systemctl daemon-reload"
    run_command "Enable services" "systemctl enable filebrowser.service ttyd.service"
    run_command "Restart services to ensure all configs are applied" "systemctl restart filebrowser.service ttyd.service"

    log "INFO" "--- Installation Complete! ---"
    log "WARN" "You must now re-run the Nginx setup script to apply the new proxy configuration."
    check_status
}

# (Other functions remain mostly unchanged but are included for completeness)
# ...
process_systemd_template() { local template_name=$1; local service_name=$2; local template_path="$template_name"; local output_path="/etc/systemd/system/${service_name}"; if [[ "$service_name" == *"/"* ]]; then output_path="/etc/systemd/system/$service_name"; fi; log "INFO" "Processing template for ${service_name}..."; local temp_file; temp_file=$(mktemp); local sed_script=""; for var in $(grep -o '{{[A-Z_]*}}' "$template_path" | sort -u | tr -d '{}'); do sed_script+="s|{{\s*$var\s*}}|${!var}|g;"; done; sed "$sed_script" "$template_path" > "$temp_file"; sudo mv "$temp_file" "$output_path"; sudo chown root:root "$output_path"; sudo chmod 644 "$output_path"; }
uninstall_services() { log "INFO" "--- Starting Secure Web Access Uninstallation ---"; run_command "Stop and disable systemd services" "systemctl disable --now ttyd.service filebrowser.service" || log "WARN" "Services may not have been running."; log "INFO" "Removing systemd service files and config..."; sudo rm -f /etc/systemd/system/filebrowser.service "${PAM_CONFIG_PATH}"; run_command "Remove ttyd override" "rm -rf ${TTYD_OVERRIDE_DIR}"; run_command "Reload systemd daemon" "systemctl daemon-reload"; log "INFO" "Removing packages, binaries, and data..."; run_command "Remove filebrowser binary" "rm -f /usr/local/bin/filebrowser"; local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}"); run_command "Remove filebrowser data directory" "rm -rf ${fb_db_dir}"; run_command "Remove File Browser config dir" "rm -rf ${FILEBROWSER_CONFIG_DIR}"; log "INFO" "Removing ttyd and Nginx PAM module..."; if ! DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ttyd libnginx-mod-http-auth-pam; then handle_error $? "Failed to remove packages."; fi; log "INFO" "SUCCESS: Packages removed."; log "INFO" "--- Uninstallation Complete! ---"; }
check_status() { log "INFO" "--- Checking Service Status ---"; systemctl status --no-pager ttyd.service filebrowser.service || true; }
main() { if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2; exit 1; fi; source "$UTILS_SCRIPT_PATH"; if [ -z "$1" ]; then usage; fi; check_root; if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then log "ERROR" "Configuration file not found at '$DEFAULT_CONFIG_FILE'."; exit 1; fi; source "$DEFAULT_CONFIG_FILE"; case "$1" in install) install_services ;; uninstall) uninstall_services ;; status) check_status ;; *) usage ;; esac; }
main "$@"