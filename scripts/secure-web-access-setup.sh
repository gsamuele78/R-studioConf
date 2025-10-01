#!/bin/bash
# scripts/secure-web-access-setup.sh

# A manager script for installing, uninstalling, and checking secure web access services.
# It uses Nginx with PAM for authentication and proxies to ttyd (web terminal)
# and File Browser (web file manager).
# VERSION 2.0: Fixes hanging issue during package installation.

set -e

# --- Robust Path Detection ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Define Global Paths ---
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/secure-web-access.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
PAM_CONFIG_PATH="/etc/pam.d/nginx"

# --- Function Definitions ---

usage() {
    echo -e "\033[1;33mUsage: $0 [action]\033[0m"
    echo "Actions:"
    echo -e "  \033[0;36minstall\033[0m    - Installs and enables ttyd and File Browser with Nginx PAM auth."
    echo -e "  \033[0;36muninstall\033[0m  - Stops, disables, and removes the services and packages."
    echo -e "  \033[0;36mstatus\033[0m     - Checks the status of the ttyd and filebrowser services."
    exit 1
}

process_systemd_template() {
    local template_name=$1
    local service_name=$2
    local template_path="${TEMPLATE_DIR}/${template_name}"
    local output_path="/etc/systemd/system/${service_name}"
    
    log "INFO" "Processing template for ${service_name}..."
    local temp_file
    temp_file=$(mktemp)
    
    local sed_script=""
    # Dynamically create the sed script from variables in the template
    for var in $(grep -o '{{[A-Z_]*}}' "$template_path" | sort -u | tr -d '{}'); do
        sed_script+="s|{{\s*$var\s*}}|${!var}|g;"
    done

    sed "$sed_script" "$template_path" > "$temp_file"
    
    sudo mv "$temp_file" "$output_path"
    sudo chown root:root "$output_path"
    sudo chmod 644 "$output_path"
}

install_services() {
    log "INFO" "--- Starting Secure Web Access Installation ---"
    
    # ### MODIFIED BLOCK ###
    # Call apt-get update directly to prevent hanging.
    log "INFO" "Updating package lists. Apt output will follow:"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
        handle_error $? "Failed to update package lists."
        return 1
    fi
    log "INFO" "SUCCESS: Package lists updated."

    # ### MODIFIED BLOCK ###
    # Step 1: Install Nginx PAM module and ttyd directly.
    log "INFO" "Installing prerequisite packages (ttyd, nginx-auth-pam). Apt output will follow:"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ttyd libnginx-mod-http-auth-pam; then
        handle_error $? "Failed to install prerequisite packages."
        return 1
    fi
    log "INFO" "SUCCESS: Prerequisite packages installed."

    # ### MODIFIED BLOCK ###
    # Step 2: Download and install File Browser binary directly.
    log "INFO" "Downloading and installing File Browser. Installer output will follow:"
    local filebrowser_install_cmd="curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash"
    if ! eval "$filebrowser_install_cmd"; then
        handle_error $? "Failed to install File Browser. Please check network or run the command manually."
        return 1
    fi
    #run_command "Move filebrowser to /usr/local/bin" "mv ./filebrowser /usr/local/bin/"
    log "INFO" "SUCCESS: File Browser installed."

    # Step 3: Create PAM configuration for Nginx
    log "INFO" "Creating PAM service configuration for Nginx at ${PAM_CONFIG_PATH}"
    echo "# Instructs PAM to use the default system authentication stack (which includes SSSD)
@include common-auth" | sudo tee "${PAM_CONFIG_PATH}" > /dev/null
    
    # Step 4: Creating and enabling systemd services from templates
    log "INFO" "Creating and enabling systemd services..."
    process_systemd_template "ttyd.service.template" "ttyd.service"
    process_systemd_template "filebrowser.service.template" "filebrowser.service"
    
    run_command "Reload systemd daemon" "systemctl daemon-reload"
    run_command "Enable and start ttyd and filebrowser services" "systemctl enable --now ttyd.service filebrowser.service"

    log "INFO" "--- Installation Complete! ---"
    log "WARN" "You must now re-run the Nginx setup script to apply the new proxy configuration."
    check_status
}

uninstall_services() {
    log "INFO" "--- Starting Secure Web Access Uninstallation ---"

    run_command "Stop and disable systemd services" "systemctl disable --now ttyd.service filebrowser.service" || log "WARN" "Services may not have been running."
    
    log "INFO" "Removing systemd service files and PAM config..."
    sudo rm -f /etc/systemd/system/ttyd.service /etc/systemd/system/filebrowser.service "${PAM_CONFIG_PATH}"
    run_command "Reload systemd daemon after removing services" "systemctl daemon-reload"

    log "INFO" "Removing packages and binaries..."
    run_command "Remove filebrowser binary" "rm -f /usr/local/bin/filebrowser"
    
    # ### MODIFIED BLOCK ###
    # Call apt-get remove directly to prevent hanging.
    log "INFO" "Removing ttyd and Nginx PAM module. Apt output will follow:"
    if ! DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ttyd libnginx-mod-http-auth-pam; then
        handle_error $? "Failed to remove packages."
        # Don't exit, just warn and continue cleanup
    fi
    log "INFO" "SUCCESS: Packages removed."

    log "INFO" "--- Uninstallation Complete! ---"
}

check_status() {
    log "INFO" "--- Checking Service Status ---"
    systemctl status --no-pager ttyd.service filebrowser.service || true
}

# --- Main Execution ---
main() {
    # Step 0: Load Dependencies and Validate Environment
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

    # Action Routing
    case "$1" in
        install) install_services ;;
        uninstall) uninstall_services ;;
        status) check_status ;;
        *) usage ;;
    esac
}

main "$@"