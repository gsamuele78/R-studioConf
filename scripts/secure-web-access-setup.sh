#!/bin/bash
# scripts/secure-web-access-setup.sh
# VERSION 15.1: VICTORIOUS. Final simplification based on developer documentation.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/secure-web-access.conf"
PAM_CONFIG_PATH="/etc/pam.d/nginx"
TTYD_OVERRIDE_DIR="/etc/systemd/system/ttyd.service.d"
FILEBROWSER_CONFIG_DIR="/etc/filebrowser"
FILEBROWSER_CONFIG_FILE="${FILEBROWSER_CONFIG_DIR}/filebrowser.yml"

usage() { echo "Usage: $0 [install|uninstall|status]"; exit 1; }

install_services() {
    log "INFO" "--- Starting Secure Web Access Installation ---"
    
    log "INFO" "Attempting to repair any broken package dependencies..."; run_command "Force configure all pending packages" "dpkg --configure -a"; run_command "Fix broken dependencies" "apt-get -f install -y";
    log "INFO" "Installing prerequisite packages..."; run_command "Update package lists" "apt-get -y update";
    log "INFO" "Installing ttyd..."; if ! DEBIAN_FRONTEND=noninteractive apt-get -y install ttyd; then handle_error $? "Failed to install ttyd."; return 1; fi;
    log "INFO" "Installing curl..."; if ! DEBIAN_FRONTEND=noninteractive apt-get -y install curl; then handle_error $? "Failed to install curl."; return 1; fi;
    log "INFO" "SUCCESS: Prerequisites are correctly installed."
    
    log "INFO" "Downloading gtsteffaniak/filebrowser fork..."; local LATEST_URL="https://github.com/gtsteffaniak/filebrowser/releases/latest/download/linux-amd64-filebrowser"; local BINARY_PATH="/usr/local/bin/filebrowser"; run_command "Download filebrowser binary" "curl -L -o ${BINARY_PATH} \"${LATEST_URL}\""; run_command "Set executable permission for filebrowser" "chmod +x ${BINARY_PATH}";

    log "INFO" "Creating YAML config file for File Browser..."
    local processed_content
    if ! process_template "${SCRIPT_DIR}/../templates/filebrowser.yml.template" "processed_content" \
        "FILEBROWSER_PORT=${FILEBROWSER_PORT}" \
        "FILEBROWSER_DB_PATH=${FILEBROWSER_DB_PATH}"; then
        handle_error 1 "Failed to process filebrowser.yml.template."
        return 1
    fi
    ensure_dir_exists "${FILEBROWSER_CONFIG_DIR}"
    echo "$processed_content" | sudo tee "${FILEBROWSER_CONFIG_FILE}" > /dev/null
    run_command "Set ownership for File Browser config" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${FILEBROWSER_CONFIG_DIR}"

    # The database directory still needs to exist and have correct permissions.
    # The server will create the .db file itself on first run.
    local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}"); ensure_dir_exists "$fb_db_dir";
    run_command "Set ownership for File Browser data dir" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${fb_db_dir}";

    log "INFO" "Creating and enabling File Browser service..."; process_systemd_template "${SCRIPT_DIR}/../templates/filebrowser.service.template" "filebrowser.service"
    log "INFO" "Creating systemd override to configure ttyd..."; ensure_dir_exists "${TTYD_OVERRIDE_DIR}"; process_systemd_template "${SCRIPT_DIR}/../templates/ttyd.service.override.template" "ttyd.service.d/override.conf"
    log "INFO" "Creating PAM service configuration for Nginx (if not exists)..."; if [ ! -f "${PAM_CONFIG_PATH}" ]; then echo "@include common-auth" | sudo tee "${PAM_CONFIG_PATH}" > /dev/null; fi
    
    log "INFO" "Reloading systemd and restarting services..."; run_command "Reload systemd daemon" "systemctl daemon-reload"; run_command "Enable ttyd service" "systemctl enable ttyd.service"; run_command "Enable filebrowser service" "systemctl enable filebrowser.service"; run_command "Restart services to apply all configs" "systemctl restart ttyd.service filebrowser.service"

    log "INFO" "--- Installation Complete! ---"; log "WARN" "You must now run the Nginx setup script."; check_status
}

uninstall_services() {
    log "INFO" "--- Starting Secure Web Access Uninstallation ---"
    run_command "Stop and disable systemd services" "systemctl disable --now ttyd.service filebrowser.service" || log "WARN" "Services may not have been running."
    log "INFO" "Removing systemd service files and config..."; sudo rm -f /etc/systemd/system/filebrowser.service; run_command "Remove ttyd override" "rm -rf ${TTYD_OVERRIDE_DIR}"; run_command "Reload systemd daemon" "systemctl daemon-reload";
    log "INFO" "Removing packages, binaries, and data..."; run_command "Remove filebrowser binary" "rm -f /usr/local/bin/filebrowser"; run_command "Remove File Browser config dir" "rm -rf ${FILEBROWSER_CONFIG_DIR}"; local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}"); run_command "Remove filebrowser data directory" "rm -rf ${fb_db_dir}"; 
    log "INFO" "Removing ttyd package..."; if ! DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ttyd; then handle_error $? "Failed to remove ttyd package."; fi; log "INFO" "SUCCESS: Packages removed.";
    log "INFO" "--- Uninstallation Complete! ---"
}

# (The rest of the functions are unchanged)
check_status() { log "INFO" "--- Checking Service Status ---"; log "INFO" "Status for ttyd:"; systemctl status ttyd.service || true; log "INFO" "Status for filebrowser:"; systemctl status filebrowser.service || true; log "INFO" "Checking for detailed filebrowser errors..."; journalctl -u filebrowser.service --no-pager -n 20 || true; }
main() { if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2; exit 1; fi; source "$UTILS_SCRIPT_PATH"; if [ -z "$1" ]; then usage; fi; check_root; if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then log "ERROR" "Configuration file not found at '$DEFAULT_CONFIG_FILE'."; exit 1; fi; source "$DEFAULT_CONFIG_FILE"; case "$1" in install) install_services ;; uninstall) uninstall_services ;; status) check_status ;; *) usage ;; esac; }
process_systemd_template() { local template_name=$1; local service_name=$2; local extra_vars=${3:-}; local template_path="$template_name"; local output_path="/etc/systemd/system/${service_name}"; if [[ "$service_name" == *"/"* ]]; then output_path="/etc/systemd/system/$service_name"; fi; log "INFO" "Processing template for ${service_name}..."; local temp_file; temp_file=$(mktemp); local sed_script=""; for var in $(grep -o '{{[A-Z_]*}}' "$template_path" | sort -u | tr -d '{}'); do sed_script+="s|{{\s*$var\s*}}|${!var}|g;"; done; if [[ -n "$extra_vars" ]]; then IFS='=' read -r key value <<< "$extra_vars"; sed_script+="s|{{\s*$key\s*}}|$value|g;"; fi; sed "$sed_script" "$template_path" > "$temp_file"; sudo mv "$temp_file" "$output_path"; sudo chown root:root "$output_path"; sudo chmod 644 "$output_path"; }

main "$@"