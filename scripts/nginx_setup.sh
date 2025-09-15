#!/bin/bash

# A script to set up Nginx as a reverse proxy for R-Studio Server and other web services.
# It uses a modular structure with external configuration and template files,
# and includes robust path detection to be run from any location.

set -e

# --- Robust Path Detection ---
# Determine the absolute path to the directory where this script resides.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Define paths to dependent files and directories relative to the script's location.
# These paths are now defined globally for clarity.
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/nginx_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# --- Function Definitions ---

usage() {
    # The utility script may not be loaded yet, so use direct echo for usage.
    echo -e "\033[1;33mUsage: $0 -c /path/to/nginx_setup.vars.conf\033[0m"
    echo "  -c: Path to the configuration file (Required)."
    echo "      (Default: ${DEFAULT_CONFIG_FILE})"
    exit 1
}

# Process a template file by replacing {{VARIABLES}} with values from the config file.
process_template() {
    local template_path=$1
    local output_path=$2

    if [ ! -f "$template_path" ]; then
        log_error "Template file not found at '$template_path'."
        return 1
    fi

    local temp_file
    temp_file=$(mktemp)
    
    # Dynamically build a sed script to replace all placeholders from the sourced config file.
    local sed_script=""
    for var in $(grep -o '{{[A-Z_]*}}' "$template_path" | sort -u | tr -d '{}'); do
        sed_script+="s|{{\s*$var\s*}}|${!var}|g;"
    done

    sed "$sed_script" "$template_path" > "$temp_file"
    sudo mv "$temp_file" "$output_path"
    sudo chown root:root "$output_path"
}

# --- Main Execution ---
main() {
    # --- Step 0: Load Dependencies and Validate Environment ---
    # This block is now the VERY FIRST thing to run.
    
    # A. Source Common Utilities
    if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
        printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2
        exit 1
    fi
    source "$UTILS_SCRIPT_PATH"

    # B. Validate that functions were loaded correctly
    if ! command -v check_root &> /dev/null; then
        log_error "FATAL: Utilities were sourced, but essential functions like 'check_root' are missing."
        log_error "Please check the contents of '$UTILS_SCRIPT_PATH'."
        exit 1
    fi

    # C. NOW it is safe to call functions from the utility script.
    check_root

    # D. Parse command-line arguments
    local config_file="$DEFAULT_CONFIG_FILE"
    while getopts "c:h" opt; do
        case ${opt} in
            c) config_file="${OPTARG}" ;;
            h|*) usage ;;
        esac
    done

    # E. Load configuration file
    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found at '$config_file'."
        usage
    fi
    source "$config_file"

    # --- Step 1: Install Nginx ---
    log_info "Installing Nginx..."
    sudo apt-get update && sudo apt-get install -y nginx

    # --- Step 2: Create Directories ---
    log_info "Ensuring Nginx directories exist..."
    sudo mkdir -p "$NGINX_TEMPLATE_DIR" "$SSL_CERT_DIR"

    # --- Step 3: Create Self-Signed Certificate ---
    log_info "Creating self-signed SSL certificate..."
    local cert_path="$SSL_CERT_DIR/$DOMAIN_OR_IP.crt"
    local key_path="$SSL_CERT_DIR/$DOMAIN_OR_IP.key"
    if [ ! -f "$cert_path" ]; then
        sudo openssl req -x509 -nodes -days "$SSL_DAYS" -newkey rsa:2048 \
            -keyout "$key_path" -out "$cert_path" \
            -subj "/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/OU=$SSL_ORG_UNIT/CN=$DOMAIN_OR_IP"
    else
        log_warn "Certificate for $DOMAIN_OR_IP already exists. Skipping creation."
    fi

    # --- Step 4: Copy and Process Templates ---
    log_info "Processing and deploying Nginx templates..."
    sudo cp "${TEMPLATE_DIR}/nginx_ssl_params.conf.template" "${NGINX_TEMPLATE_DIR}/nginx_ssl_params.conf"
    process_template "${TEMPLATE_DIR}/nginx_self_signed_snippet.conf.template" "${NGINX_TEMPLATE_DIR}/nginx_self_signed_snippet.conf"
    process_template "${TEMPLATE_DIR}/nginx_proxy_location.conf.template" "${NGINX_TEMPLATE_DIR}/nginx_proxy_location.conf"
    process_template "${TEMPLATE_DIR}/nginx_self_signed_site.conf.template" "${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf"

    # --- Step 5: Enable Site and Restart Nginx ---
    log_info "Enabling site and restarting Nginx..."
    sudo ln -sf "${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf" "${NGINX_DIR}/sites-enabled/"
    sudo rm -f "${NGINX_DIR}/sites-enabled/default"
    sudo nginx -t
    sudo systemctl restart nginx

    # --- Final Output ---
    echo -e "----------------------------------------"
    log_info "Nginx setup complete!"
    echo "Services are configured for: https://${DOMAIN_OR_IP}"
    echo "- R-Studio:       https://${DOMAIN_OR_IP}/"
    echo "- Web Terminal:   https://${DOMAIN_OR_IP}/terminal/"
    echo "- Web SSH:        https://${DOMAIN_OR_IP}/ssh/"
    echo -e "----------------------------------------"
}

# Pass all command-line arguments to the main function to be processed.
main "$@"