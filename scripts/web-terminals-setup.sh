#!/bin/bash

# A manager script for installing, uninstalling, and checking web terminal services (ttyd and wetty).
# It uses a modular structure with external configuration and systemd template files.

set -e

# --- Shell Colour Definitions ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Global Variables ---
CONFIG_FILE="../config/web-terminals.conf"
SCRIPT_DIR=$(dirname "$(realpath "$0")")
BASE_DIR=$(dirname "$SCRIPT_DIR")

# --- Function Definitions ---

usage() {
    echo -e "${YELLOW}Usage: $0 [action]${NC}"
    echo "Actions:"
    echo -e "  ${CYAN}install${NC}    - Installs and enables ttyd and wetty services."
    echo -e "  ${CYAN}uninstall${NC}  - Stops, disables, and removes the services and packages."
    echo -e "  ${CYAN}status${NC}     - Checks the status of the ttyd and wetty services."
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root.${NC}" >&2
        exit 1
    fi
}

# Source config and check for required variables
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Configuration file not found at '$CONFIG_FILE'.${NC}" >&2
        exit 1
    fi
    source "$CONFIG_FILE"
    # Basic check for a critical variable
    if [ -z "$WEB_TERMINAL_PORT" ]; then
        echo -e "${RED}Error: Configuration file seems invalid or empty.${NC}" >&2
        exit 1
    fi
}

process_template() {
    local template_name=$1
    local service_name=$2
    local template_path="$BASE_DIR/templates/$template_name"
    local output_path="/etc/systemd/system/$service_name"
    
    echo "Processing template for $service_name..."
    local temp_file
    temp_file=$(mktemp)
    
    # Handle optional ttyd credentials
    if [[ "$service_name" == "ttyd.service" ]] && [ -n "$WEB_TERMINAL_CREDENTIALS" ]; then
        export WEB_TERMINAL_CREDENTIALS="--credential $WEB_TERMINAL_CREDENTIALS"
    else
        export WEB_TERMINAL_CREDENTIALS=""
    fi

    # Replace all variables and write to temp file
    eval "echo \"$(cat "$template_path")\"" > "$temp_file"
    
    # Move temp file to final destination
    sudo mv "$temp_file" "$output_path"
    sudo chown root:root "$output_path"
    sudo chmod 644 "$output_path"
}

# --- Action Functions ---

install_services() {
    echo -e "${GREEN}--- Starting Web Terminals Installation ---${NC}"
    
    echo "Step 1: Installing prerequisite packages..."
    sudo apt-get update
    sudo apt-get install -y ttyd nodejs npm

    echo "Step 2: Installing wetty globally via npm..."
    sudo npm install -g wetty

    echo "Step 3: Creating and enabling systemd services..."
    process_template "ttyd.service.template" "ttyd.service"
    process_template "wetty.service.template" "wetty.service"
    
    echo "Step 4: Reloading systemd and starting services..."
    sudo systemctl daemon-reload
    sudo systemctl enable --now ttyd.service wetty.service

    echo -e "${GREEN}--- Installation Complete! ---${NC}"
    check_status
}

uninstall_services() {
    echo -e "${YELLOW}--- Starting Web Terminals Uninstallation ---${NC}"

    echo "Step 1: Stopping and disabling systemd services..."
    sudo systemctl disable --now ttyd.service wetty.service || echo "Services were not running."

    echo "Step 2: Removing systemd service files..."
    sudo rm -f /etc/systemd/system/ttyd.service
    sudo rm -f /etc/systemd/system/wetty.service
    sudo systemctl daemon-reload

    echo "Step 3: Uninstalling packages..."
    sudo npm uninstall -g wetty
    sudo apt-get remove --purge -y ttyd
    echo -e "${YELLOW}Note: nodejs and npm were not removed as they may be used by other applications.${NC}"

    echo -e "${YELLOW}--- Uninstallation Complete! ---${NC}"
}

check_status() {
    echo -e "${CYAN}--- Checking Service Status ---${NC}"
    systemctl status --no-pager ttyd.service wetty.service || true
}

# --- Main Execution ---
main() {
    if [ -z "$1" ]; then
        usage
    fi

    check_root
    load_config

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