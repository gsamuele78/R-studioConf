#!/bin/bash

# A manager script for installing, uninstalling, and checking web terminal services (ttyd and wetty).
# It uses a modular structure with external configuration and systemd template files.

set -e

# --- Robust Path Detection ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Define Paths ---
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/web-terminals.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# --- Function Definitions ---

usage() {
    echo -e "\033[1;33mUsage: $0 [action]\033[0m"
    echo "Actions:"
    echo -e "  \033[0;36minstall\033[0m    - Installs and enables ttyd and wetty services."
    echo -e "  \033[0;36muninstall\033[0m  - Stops, disables, and removes the services and packages."
    echo -e "  \033[0;36mstatus\033[0m     - Checks the status of the ttyd and wetty services."
    exit 1
}

# Process a systemd template file.
process_systemd_template() {
    local template_name=$1
    local service_name=$2
    local template_path="${TEMPLATE_DIR}/${template_name}"
    local output_path="/etc/systemd/system/${service_name}"
    
    log_info "Processing template for ${service_name}..."
    local temp_file
    temp_file=$(mktemp)
    
    # Handle optional ttyd credentials to avoid an empty '--credential' flag
    local ttyd_creds_arg=""
    if [[ -n "$WEB_TERMINAL_CREDENTIALS" ]]; then
        ttyd_creds_arg="--credential $WEB_TERMINAL_CREDENTIALS"
    fi

    # Replace all variables using sed for robustness.
    local sed_script=""
    for var in $(grep -o '{{[A-Z_]*}}' "$template_path" | sort -u | tr -d '{}'); do
        sed_script+="s|{{\s*$var\s*}}|${!var}|g;"
    done
    # Manually substitute the special credential argument
    sed_script+="s|{{WEB_TERMINAL_CREDENTIALS}}|${ttyd_creds_arg}|g;"

    sed "$sed_script" "$template_path" > "$temp_file"
    
    sudo mv "$temp_file" "$output_path"
    sudo chown root:root "$output_path"
    sudo chmod 644 "$output_path"
}

# --- Action Functions ---

install_services() {
    log_info "--- Starting Web Terminals Installation ---"
    
    log_info "Step 1: Installing prerequisite packages..."
    sudo apt-get update
    sudo apt-get install -y ttyd nodejs npm

    log_info "Step 2: Installing wetty globally via npm..."
    sudo npm install -g wetty

    log_info "Step 3: Creating and enabling systemd services..."
    process_systemd_template "ttyd.service.template" "ttyd.service"
    process_systemd_template "wetty.service.template" "wetty.service"
    
    log_info "Step 4: Reloading systemd and starting services..."
    sudo systemctl daemon-reload
    sudo systemctl enable --now ttyd.service wetty.service

    log_info "--- Installation Complete! ---"
    check_status
}

uninstall_services() {
    log_info "--- Starting Web Terminals Uninstallation ---"

    log_info "Step 1: Stopping and disabling systemd services..."
    sudo systemctl stop ttyd.service wetty.service || log_warn "Services were not running."
    sudo systemctl disable ttyd.service wetty.service || log_warn "Services were not enabled."

    log_info "Step 2: Removing systemd service files..."
    sudo rm -f /etc/systemd/system/ttyd.service /etc/systemd/system/wetty.service
    sudo systemctl daemon-reload

    log_info "Step 3: Uninstalling packages..."
    sudo npm uninstall -g wetty
    sudo apt-get remove --purge -y ttyd
    log_warn "Note: nodejs and npm were not removed as they may be used by other applications."

    log_info "--- Uninstallation Complete! ---"
}

check_status() {
    log_info "--- Checking Service Status ---"
    # Use '|| true' to prevent the script from exiting if a service is not found (e.g., after uninstall)
    systemctl status --no-pager ttyd.service wetty.service || true
}

# --- Main Execution ---
main() {
    # --- Step 0: Load Dependencies and Validate ---
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
        log_error "Configuration file not found at '$DEFAULT_CONFIG_FILE'."
        exit 1
    fi
    source "$DEFAULT_CONFIG_FILE"

    # --- Action Routing ---
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