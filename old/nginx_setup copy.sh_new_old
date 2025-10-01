#!/bin/bash

# A script to set up Nginx as a reverse proxy for R-Studio Server and other web services.
# It uses a modular structure and leverages the functions in common_utils.sh.
# VERSION 1.1: Added a fix for systems with disabled IPv6 to ensure Nginx package installs correctly.

set -e

# --- Robust Path Detection ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Define Paths ---
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/nginx_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# --- Function Definitions ---

usage() {
    echo -e "\033[1;33mUsage: $0 -c /path/to/nginx_setup.vars.conf\033[0m"
    echo "  -c: Path to the configuration file (Required)."
    echo "      (Default: ${DEFAULT_CONFIG_FILE})"
    exit 1
}

# This helper function is called if the Nginx installation fails.
# It comments out the problematic IPv6 listen directives in the default config.
_fix_ipv6_binding_issue() {
    local default_conf="/etc/nginx/sites-available/default"
    if [[ -f "$default_conf" ]]; then
        log "WARN" "Nginx installation failed. Attempting to fix potential IPv6 binding issue..."
        # Use sed to comment out any line containing 'listen [::]:'
        # The '-i.bak' flag creates a backup of the original file.
        sudo sed -i.bak 's/listen \[::\]:/#listen \[::\]:/g' "$default_conf"
        log "INFO" "Commented out IPv6 listen directives in ${default_conf}. Retrying installation..."
        return 0
    fi
    return 1 # Return failure if the file doesn't exist
}

# --- Main Execution ---
main() {
    # Step 0: Load Dependencies and Validate
    if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
        printf "\033[0;31m[FATAL] Utility script not found at %s\n\033[0m" "$UTILS_SCRIPT_PATH" >&2
        exit 1
    fi
    source "$UTILS_SCRIPT_PATH"

    check_root

    local config_file="$DEFAULT_CONFIG_FILE"
    while getopts "c:h" opt; do
        case ${opt} in
            c) config_file="${OPTARG}" ;;
            h|*) usage ;;
        esac
    done

    if [ ! -f "$config_file" ]; then
        log "ERROR" "Configuration file not found at '$config_file'."
        usage
    fi
    source "$config_file"

    # --- Step 1: Interactive Configuration ---
    log "INFO" "--- Interactive Nginx Setup ---"
    echo "Please confirm the settings below. Press Enter to accept the default."
    prompt_for_value "Domain or IP Address" "DOMAIN_OR_IP"
    prompt_for_value "R-Studio Port" "RSTUDIO_PORT"
    prompt_for_value "Web Terminal Port" "WEB_TERMINAL_PORT"
    prompt_for_value "Web SSH Port" "WEB_SSH_PORT"
    echo "-------------------------------------"
    log "INFO" "Configuration confirmed. Proceeding with setup..."

    # Step 2: Install Nginx with Automated Fix
    # We will no longer use run_command here to handle the specific failure case.
    log "INFO" "Starting: Install Nginx package"
    if ! sudo apt-get update && sudo apt-get install -y nginx; then
        # If the installation fails, call our fix-it function
        if _fix_ipv6_binding_issue; then
            # Retry the installation one more time
            run_command "Retry Nginx installation after applying fix" "apt-get install -y nginx"
        else
            log "ERROR" "Nginx installation failed and the default config file could not be found to apply a fix."
            exit 1
        fi
    fi
    log "INFO" "SUCCESS: Install Nginx package"

    # Step 3: Create Directories using the utility function
    ensure_dir_exists "$NGINX_TEMPLATE_DIR"
    ensure_dir_exists "$SSL_CERT_DIR"

    # Step 4: Create Self-Signed Certificate
    log "INFO" "Checking for self-signed SSL certificate..."
    local cert_path="$SSL_CERT_DIR/$DOMAIN_OR_IP.crt"
    local key_path="$SSL_CERT_DIR/$DOMAIN_OR_IP.key"
    if [ ! -f "$cert_path" ]; then
        local openssl_cmd="openssl req -x509 -nodes -days \"$SSL_DAYS\" -newkey rsa:2048 \
            -keyout \"$key_path\" -out \"$cert_path\" \
            -subj \"/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/OU=$SSL_ORG_UNIT/CN=$DOMAIN_OR_IP\""
        run_command "Generate self-signed certificate" "$openssl_cmd"
    else
        log "WARN" "Certificate for $DOMAIN_OR_IP already exists. Skipping creation."
    fi

    # Step 5: Copy and Process Templates using utility functions
    log "INFO" "Processing and deploying Nginx templates..."
    run_command "Deploy static SSL params template" "cp '${TEMPLATE_DIR}/nginx_ssl_params.conf.template' '${NGINX_TEMPLATE_DIR}/nginx_ssl_params.conf'"

    local template_args=(
        "DOMAIN_OR_IP=${DOMAIN_OR_IP}"
        "RSTUDIO_PORT=${RSTUDIO_PORT}"
        "WEB_TERMINAL_PORT=${WEB_TERMINAL_PORT}"
        "WEB_SSH_PORT=${WEB_SSH_PORT}"
        "LOG_DIR=${LOG_DIR}"
        "NGINX_TEMPLATE_DIR=${NGINX_TEMPLATE_DIR}"
        "SSL_CERT_DIR=${SSL_CERT_DIR}"
    )

    local processed_content
    process_template "${TEMPLATE_DIR}/nginx_self_signed_snippet.conf.template" "processed_content" "${template_args[@]}"
    run_command "Deploy self-signed snippet" "echo \"$processed_content\" > '${NGINX_TEMPLATE_DIR}/nginx_self_signed_snippet.conf'"

    process_template "${TEMPLATE_DIR}/nginx_proxy_location.conf.template" "processed_content" "${template_args[@]}"
    run_command "Deploy proxy location snippet" "echo \"$processed_content\" > '${NGINX_TEMPLATE_DIR}/nginx_proxy_location.conf'"

    process_template "${TEMPLATE_DIR}/nginx_self_signed_site.conf.template" "processed_content" "${template_args[@]}"
    run_command "Deploy main Nginx site configuration" "echo \"$processed_content\" > '${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf'"

    # Step 6: Enable Site and Restart Nginx using utility functions
    log "INFO" "Enabling site and restarting Nginx..."
    run_command "Enable Nginx site for ${DOMAIN_OR_IP}" "ln -sf '${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf' '${NGINX_DIR}/sites-enabled/'"
    run_command "Disable default Nginx site" "rm -f '${NGINX_DIR}/sites-enabled/default'"
    run_command "Test Nginx configuration and restart service" "nginx -t && systemctl restart nginx"

    # Final Output
    echo -e "----------------------------------------"
    log "INFO" "Nginx setup complete!"
    echo "Services are configured for: https://${DOMAIN_OR_IP}"
    echo "- R-Studio:       https://${DOMAIN_OR_IP}/"
    echo "- Web Terminal:   https://${DOMAIN_OR_IP}/terminal/"
    echo "- Web SSH:        https://${DOMAIN_OR_IP}/ssh/"
    echo -e "----------------------------------------"
}

main "$@"