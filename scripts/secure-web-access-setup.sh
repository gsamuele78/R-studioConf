#!/bin/bash
# scripts/secure-web-access-setup.sh
# VERSION 16.0: VICTORIOUS. Uses the definitive YAML structure.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/secure-web-access.conf"
PAM_CONFIG_PATH="/etc/pam.d/nginx"
TTYD_OVERRIDE_DIR="/etc/systemd/system/ttyd.service.d"
#FILEBROWSER_CONFIG_DIR="/etc/filebrowser"
FILEBROWSER_CONFIG_DIR="$(dirname "${FILEBROWSER_CONFIG_PATH}")"
#FILEBROWSER_CONFIG_FILE="${FILEBROWSER_CONFIG_DIR}/filebrowser.yml"
FILEBROWSER_CONFIG_FILE="${FILEBROWSER_CONFIG_PATH}"
FILEBROWSER_DB_DIR="$(dirname "${FILEBROWSER_DB_PATH}")"
FILEBROWSER_CACHE_DIR="${FILEBROWSER_CACHE_PATH}"
FILEBROWSER_LOG_DIR="$(dirname "${FILEBROWSER_LOG_PATH}")"

usage() { echo "Usage: $0 [install|uninstall|status]"; exit 1; }

install_services() {
    log "INFO" "--- Starting Secure Web Access Installation ---"
    
    log "INFO" "Attempting to repair any broken package dependencies..."; run_command "Force configure all pending packages" "dpkg --configure -a"; run_command "Fix broken dependencies" "apt-get -f install -y";
    log "INFO" "Installing prerequisite packages..."; run_command "Update package lists" "apt-get -y update";
    log "INFO" "Installing ttyd..."; if ! DEBIAN_FRONTEND=noninteractive apt-get -y install ttyd; then handle_error $? "Failed to install ttyd."; return 1; fi;
    log "INFO" "Installing curl..."; if ! DEBIAN_FRONTEND=noninteractive apt-get -y install curl; then handle_error $? "Failed to install curl."; return 1; fi;
    log "INFO" "SUCCESS: Prerequisites are correctly installed."
    
    log "INFO" "Downloading gtsteffaniak/filebrowser fork..."; local LATEST_URL="https://github.com/gtsteffaniak/filebrowser/releases/latest/download/linux-amd64-filebrowser"; local BINARY_PATH="/usr/local/bin/filebrowser"; run_command "Download filebrowser binary" "curl -L -o ${BINARY_PATH} \"${LATEST_URL}\""; run_command "Set executable permission for filebrowser" "chmod +x ${BINARY_PATH}";

    log "INFO" "Creating directories and config for File Browser..."
    #local fb_db_dir; fb_db_dir=$(dirname "${FILEBROWSER_DB_PATH}"); 
    local fb_db_dir; fb_db_dir="${FILEBROWSER_DB_DIR}"; 
    #local fb_cache_dir="/var/lib/filebrowser/cache"
    #local fb_cache_dir; fb_cache_dir=$(dirname "${FILEBROWSER_CACHE_PATH}");
    local fb_cache_dir; fb_cache_dir="${FILEBROWSER_CACHE_DIR}";
    #local fb_log_dir; fb_log_dir=$(dirname "${FILEBROWSER_LOG_PATH}");
    local fb_log_dir; fb_log_dir="${FILEBROWSER_LOG_DIR}";
    ensure_dir_exists "${FILEBROWSER_CONFIG_DIR}"; ensure_dir_exists "$fb_db_dir"; ensure_dir_exists "$fb_cache_dir"; ensure_dir_exists "$fb_log_dir";
    
    log "INFO" "Generating YAML config from template..."
    local processed_content; if ! process_template "${SCRIPT_DIR}/../templates/filebrowser.yml.template" "processed_content" "FILEBROWSER_PORT=${FILEBROWSER_PORT}" "FILEBROWSER_DB_PATH=${FILEBROWSER_DB_PATH}" "FILEBROWSER_CACHE_PATH=${FILEBROWSER_CACHE_PATH}" "FILEBROWSER_CONFIG_PATH=${FILEBROWSER_CONFIG_PATH}" "FILEBROWSER_ROOT_DIR=${FILEBROWSER_ROOT_DIR}" "FILEBROWSER_ADMIN_USER=${FILEBROWSER_ADMIN_USER}" "FILEBROWSER_ADMIN_PASSWORD=${FILEBROWSER_ADMIN_PASSWORD}" "FILEBROWSER_LOG_PATH=${FILEBROWSER_LOG_PATH}" "FILEBROWSER_LOG_LEVEL=${FILEBROWSER_LOG_LEVEL}"; then handle_error 1 "Failed to process filebrowser.yml.template."; return 1; fi
    echo "$processed_content" | sudo tee "${FILEBROWSER_CONFIG_FILE}" > /dev/null
    
    log "INFO" "Setting permissions for File Browser directories..."
    run_command "Set ownership for File Browser config" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${FILEBROWSER_CONFIG_DIR}"
    #run_command "Set ownership for File Browser library dir" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} /var/lib/filebrowser"
    run_command "Set ownership for File Browser library dir" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${FILEBROWSER_DB_DIR}"
    #run_command "Set ownership for File Browser log dir" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} /var/log/filebrowser"
    run_command "Set ownership for File Browser log dir" "chown -R ${FILEBROWSER_USER}:${FILEBROWSER_USER} ${FILEBROWSER_LOG_DIR}"

    log "INFO" "Creating and enabling service files..."; 
    process_systemd_template "${SCRIPT_DIR}/../templates/filebrowser.service.template" "filebrowser.service"
    ensure_dir_exists "${TTYD_OVERRIDE_DIR}"; process_systemd_template "${SCRIPT_DIR}/../templates/ttyd.service.override.template" "ttyd.service.d/override.conf"
    if [ ! -f "${PAM_CONFIG_PATH}" ]; then echo "@include common-auth" | sudo tee "${PAM_CONFIG_PATH}" > /dev/null; fi
    
    log "INFO" "Reloading systemd and restarting services..."; 
    run_command "Reload systemd daemon" "systemctl daemon-reload"; 
    run_command "Enable ttyd service" "systemctl enable ttyd.service"; 
    run_command "Enable filebrowser service" "systemctl enable filebrowser.service"; 
    run_command "Restart services to apply all configs" "systemctl restart ttyd.service filebrowser.service"

    log "INFO" "--- Installation Complete! ---"; log "WARN" "You must now run the Nginx setup script."; check_status
}

uninstall_services() {
    log "INFO" "--- Starting Secure Web Access Uninstallation ---"
    run_command "Stop and disable systemd services" "systemctl disable --now ttyd.service filebrowser.service" || log "WARN" "Services may not have been running."
    log "INFO" "Removing systemd service files..."; sudo rm -f /etc/systemd/system/filebrowser.service; run_command "Remove ttyd override" "rm -rf ${TTYD_OVERRIDE_DIR}"; run_command "Reload systemd daemon" "systemctl daemon-reload";
    log "INFO" "Removing binaries, configs, and data..."; run_command "Remove filebrowser binary" "rm -f /usr/local/bin/filebrowser"; run_command "Remove File Browser config dir" "rm -rf ${FILEBROWSER_CONFIG_DIR}"; run_command "Remove File Browser library dir" "rm -rf /var/lib/filebrowser"; 
    log "INFO" "Removing ttyd package..."; if ! DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ttyd; then handle_error $? "Failed to remove ttyd package."; fi; log "INFO" "SUCCESS: Packages removed.";
    log "INFO" "--- Uninstallation Complete! ---"
}

check_status() {
    log "INFO" "--- Checking Service Status ---"
    log "INFO" "Status for ttyd:"; systemctl --no-pager status ttyd.service || true
    log "INFO" "Status for filebrowser:"; systemctl --no-pager status filebrowser.service || true
    log "INFO" "Checking for detailed filebrowser errors..."; journalctl -u filebrowser.service --no-pager -n 20 || true
}

main() {
    if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2; exit 1; fi
    source "$UTILS_SCRIPT_PATH"; if [ -z "$1" ]; then usage; fi; check_root;
    if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then log "ERROR" "Configuration file not found at '$DEFAULT_CONFIG_FILE'."; exit 1; fi
    source "$DEFAULT_CONFIG_FILE"
    case "$1" in install) install_services ;; uninstall) uninstall_services ;; status) check_status ;; *) usage ;; esac
}

main "$@"