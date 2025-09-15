#!/bin/bash

# A script to set up Nginx as a reverse proxy for R-Studio Server and other web services.
# It uses a modular structure with external configuration and template files.

set -e

# --- Shell Colour Definitions ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Function Definitions ---

usage() {
    echo -e "${YELLOW}Usage: $0 -c /path/to/nginx_setup.vars.conf${NC}"
    echo "  -c: Path to the configuration file (Required)."
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root.${NC}" >&2
        exit 1
    fi
}

# Process a template file by replacing variables with values from the config file.
process_template() {
    local template_path=$1
    local output_path=$2

    if [ ! -f "$template_path" ]; then
        echo -e "${RED}Error: Template file not found at '$template_path'.${NC}" >&2
        return 1
    fi

    # Create a temporary file to hold the processed content
    local temp_file
    temp_file=$(mktemp)

    # Use sed to replace all {{VAR}} placeholders.
    # The config file is sourced, so its variables are available in the shell.
    sed_script=""
    for var in $(grep -o '{{[A-Z_]*}}' "$template_path" | sort -u | tr -d '{}'); do
        # Use indirect expansion to get the variable's value
        sed_script+="s|{{\s*$var\s*}}|${!var}|g;"
    done

    sed "$sed_script" "$template_path" > "$temp_file"
    sudo mv "$temp_file" "$output_path"
    sudo chown root:root "$output_path"
}

# --- Main Execution ---
main() {
    local config_file=""

    while getopts "c:h" opt; do
        case ${opt} in
            c) config_file="${OPTARG}" ;;
            h|*) usage ;;
        esac
    done

    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        echo -e "${RED}Error: A valid configuration file must be provided.${NC}" >&2
        usage
    fi

    check_root

    # Source the configuration variables to make them available to the script
    source "$config_file"
    local script_dir
    script_dir=$(dirname "$(realpath "$0")")
    local base_dir
    base_dir=$(dirname "$script_dir")

    # --- Step 1: Install Nginx ---
    echo -e "${GREEN}Installing Nginx...${NC}"
    sudo apt-get update && sudo apt-get install -y nginx

    # --- Step 2: Create Directories ---
    echo -e "${GREEN}Ensuring Nginx directories exist...${NC}"
    sudo mkdir -p "$NGINX_TEMPLATE_DIR"
    sudo mkdir -p "$SSL_CERT_DIR"

    # --- Step 3: Create Self-Signed Certificate ---
    echo -e "${GREEN}Creating self-signed SSL certificate...${NC}"
    local cert_path="$SSL_CERT_DIR/$DOMAIN_OR_IP.crt"
    local key_path="$SSL_CERT_DIR/$DOMAIN_OR_IP.key"
    if [ ! -f "$cert_path" ]; then
        sudo openssl req -x509 -nodes -days "$SSL_DAYS" -newkey rsa:2048 \
            -keyout "$key_path" -out "$cert_path" \
            -subj "/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/OU=$SSL_ORG_UNIT/CN=$DOMAIN_OR_IP"
    else
        echo -e "${YELLOW}Certificate for $DOMAIN_OR_IP already exists. Skipping creation.${NC}"
    fi

    # --- Step 4: Copy and Process Templates ---
    echo -e "${GREEN}Processing and deploying Nginx templates...${NC}"
    # Copy static templates
    sudo cp "$base_dir/templates/nginx_ssl_params.conf.template" "$NGINX_TEMPLATE_DIR/nginx_ssl_params.conf"
    
    # Process templates that contain variables
    process_template "$base_dir/templates/nginx_self_signed_snippet.conf.template" "$NGINX_TEMPLATE_DIR/nginx_self_signed_snippet.conf"
    process_template "$base_dir/templates/nginx_proxy_location.conf.template" "$NGINX_TEMPLATE_DIR/nginx_proxy_location.conf"
    process_template "$base_dir/templates/nginx_self_signed_site.conf.template" "$NGINX_DIR/sites-available/$DOMAIN_OR_IP.conf"

    # --- Step 5: Enable Site and Restart Nginx ---
    echo -e "${GREEN}Enabling site and restarting Nginx...${NC}"
    sudo ln -sf "$NGINX_DIR/sites-available/$DOMAIN_OR_IP.conf" "$NGINX_DIR/sites-enabled/"
    sudo rm -f "$NGINX_DIR/sites-enabled/default"
    sudo nginx -t
    sudo systemctl restart nginx

    # --- Final Output ---
    echo -e "----------------------------------------"
    echo -e "${GREEN}Nginx setup complete!${NC}"
    echo "Services are configured for: https://$DOMAIN_OR_IP"
    echo "- R-Studio:       https://$DOMAIN_OR_IP/"
    echo "- Web Terminal:   https://$DOMAIN_OR_IP/terminal/"
    echo "- Web SSH:        https://$DOMAIN_OR_IP/ssh/"
    echo -e "----------------------------------------"
}

main "$@"