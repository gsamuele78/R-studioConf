#!/bin/bash

# A script to set up Nginx as a reverse proxy for R-Studio Server and other web services.
# VERSION 4.0: Comprehensive & Interactive. This version fixes all known bugs related to
# template processing and state management, and correctly implements both Self-Signed
# and Let's Encrypt certificate flows.

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
    exit 1
}

_fix_ipv6_binding_issue() {
    local default_conf="/etc/nginx/sites-available/default"
    if [[ -f "$default_conf" ]]; then
        log "WARN" "Nginx installation failed. Attempting to fix IPv6 binding issue..."
        sudo sed -i.bak 's/listen \[::\]:/#listen \[::\]:/g' "$default_conf"
        log "INFO" "Commented out IPv6 listen directives. Retrying..."
        return 0
    fi
    return 1
}

# --- Main Execution ---
main() {
    # Step 0: Load Dependencies and Validate
    source "$UTILS_SCRIPT_PATH"
    check_root

    local config_file="$DEFAULT_CONFIG_FILE"
    while getopts "c:h" opt; do case ${opt} in c) config_file="${OPTARG}" ;; h|*) usage ;; esac; done
    source "$config_file"

    # Step 1: Interactive Configuration
    log "INFO" "--- Interactive Nginx Setup ---"
    echo "Please confirm or edit the settings. Press Enter to accept the default."
    prompt_for_value "Certificate Mode (SELF_SIGNED/LETS_ENCRYPT)" "CERT_MODE"
    prompt_for_value "Domain or IP Address" "DOMAIN_OR_IP"
    
    if [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
        prompt_for_value "Let's Encrypt Email" "LE_EMAIL"
    else # SELF_SIGNED
        prompt_for_value "Self-Signed: Country (2-letter code)" "SSL_COUNTRY"
        prompt_for_value "Self-Signed: State or Province" "SSL_STATE"
        prompt_for_value "Self-Signed: Locality (eg, city)" "SSL_LOCALITY"
        prompt_for_value "Self-Signed: Organization Name" "SSL_ORGANIZATION"
        prompt_for_value "Self-Signed: Organizational Unit" "SSL_ORG_UNIT"
    fi
    
    prompt_for_value "R-Studio Port" "RSTUDIO_PORT"
    prompt_for_value "Web Terminal Port" "WEB_TERMINAL_PORT"
    prompt_for_value "FileBrowser Port" "FILEBROWSER_PORT" # CORRECTED
    echo "-------------------------------------"
    log "INFO" "Configuration confirmed. Proceeding with setup..."
    
    # Step 2: Install Packages with Automated Fix
    log "INFO" "Starting: Install required packages"
    local packages_to_install="nginx"
    if [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
        packages_to_install+=" certbot python3-certbot-nginx"
    fi

    if ! sudo apt-get -y update && sudo apt-get -y install $packages_to_install; then
        if _fix_ipv6_binding_issue; then
            run_command "Retry package installation after applying fix" "apt-get -y install $packages_to_install"
        else
            log "ERROR" "Package installation failed and could not be fixed."
            exit 1
        fi
    fi
    log "INFO" "SUCCESS: Required packages are installed."

    # Step 3: Create Directories
    ensure_dir_exists "$NGINX_TEMPLATE_DIR"
    ensure_dir_exists "$SSL_CERT_DIR"
    ensure_dir_exists "/var/www/html"

    # Step 4: Generate Diffie-Hellman Parameters
    log "INFO" "Checking for Diffie-Hellman parameter file..."
    if [ ! -f "$DHPARAM_PATH" ]; then
        run_command "Generate Diffie-Hellman parameters (2048 bit)" "openssl dhparam -out \"$DHPARAM_PATH\" 2048"
    else
        log "WARN" "Diffie-Hellman parameter file already exists. Skipping."
    fi

    # Step 5: Obtain/Generate SSL Certificate
    local cert_fullpath=""
    local key_fullpath=""

    if [[ "$CERT_MODE" == "SELF_SIGNED" ]]; then
        log "INFO" "Certificate Mode: SELF_SIGNED"
        cert_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.crt"
        key_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.key"
        if [ ! -f "$cert_fullpath" ]; then
            local openssl_cmd="openssl req -x509 -nodes -days \"$SSL_DAYS\" -newkey rsa:2048 -keyout \"$key_fullpath\" -out \"$cert_fullpath\" -subj \"/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/OU=$SSL_ORG_UNIT/CN=$DOMAIN_OR_IP\""
            run_command "Generate self-signed certificate" "$openssl_cmd"
        else
            log "WARN" "Self-signed certificate for $DOMAIN_OR_IP already exists. Skipping."
        fi
    elif [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
        log "INFO" "Certificate Mode: LETS_ENCRYPT"
        cert_fullpath="${LE_CERT_DIR}/${DOMAIN_OR_IP}/fullchain.pem"
        key_fullpath="${LE_CERT_DIR}/${DOMAIN_OR_IP}/privkey.pem"
        if [ ! -f "$cert_fullpath" ]; then {
            # Note: certbot --nginx plugin requires a temporary valid config to exist first.
            # This is a complex chicken-and-egg problem. Using standalone is more reliable here.
            run_command "Temporarily stop Nginx for Certbot" "systemctl stop nginx"
            local certbot_cmd="certbot certonly --standalone -d \"$DOMAIN_OR_IP\" --non-interactive --agree-tos -m \"$LE_EMAIL\""
            run_command "Obtain Let's Encrypt certificate" "$certbot_cmd"
        } else {
            log "WARN" "Let's Encrypt certificate for $DOMAIN_OR_IP already exists. Skipping."
        } fi
    else
        log "FATAL" "Invalid CERT_MODE: '$CERT_MODE'. Must be 'SELF_SIGNED' or 'LETS_ENCRYPT'."
        exit 1
    fi

    # Step 6: Process and Deploy ALL Templates
    log "INFO" "Processing and deploying Nginx templates..."
    
    local template_args=(
        "DOMAIN_OR_IP=${DOMAIN_OR_IP}" "RSTUDIO_PORT=${RSTUDIO_PORT}" "WEB_TERMINAL_PORT=${WEB_TERMINAL_PORT}"
        "FILEBROWSER_PORT=${FILEBROWSER_PORT}" "LOG_DIR=${LOG_DIR}" "NGINX_TEMPLATE_DIR=${NGINX_TEMPLATE_DIR}"
        "CERT_FULLPATH=${cert_fullpath}" "KEY_FULLPATH=${key_fullpath}" "DHPARAM_FULLPATH=${DHPARAM_PATH}"
    )

    local processed_content
    
    process_template "${TEMPLATE_DIR}/nginx_ssl_params.conf.template" "processed_content" "${template_args[@]}"
    echo "$processed_content" | sudo tee "${NGINX_TEMPLATE_DIR}/nginx_ssl_params.conf" > /dev/null
    
    process_template "${TEMPLATE_DIR}/nginx_ssl_certificate.conf.template" "processed_content" "${template_args[@]}"
    echo "$processed_content" | sudo tee "${NGINX_TEMPLATE_DIR}/nginx_ssl_certificate.conf" > /dev/null

    process_template "${TEMPLATE_DIR}/nginx_proxy_location.conf.template" "processed_content" "${template_args[@]}"
    echo "$processed_content" | sudo tee "${NGINX_TEMPLATE_DIR}/nginx_proxy_location.conf" > /dev/null

    process_template "${TEMPLATE_DIR}/nginx_site.conf.template" "processed_content" "${template_args[@]}"
    echo "$processed_content" | sudo tee "${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf" > /dev/null
    log "INFO" "SUCCESS: All templates processed and deployed."

    # Step 7: Enable Site and Restart Nginx
    log "INFO" "Enabling site and restarting Nginx..."
    run_command "Clean Nginx 'sites-enabled' directory" "rm -f '${NGINX_DIR}/sites-enabled/'*"
    run_command "Enable Nginx site for ${DOMAIN_OR_IP}" "ln -sf '${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf' '${NGINX_DIR}/sites-enabled/'"
    run_command "Test Nginx configuration and restart service" "nginx -t && systemctl restart nginx"

    # Step 8: Final Output
    log "INFO" "----------------------------------------"
    log "INFO" "Nginx setup complete!"
    echo "Services are configured for: https://${DOMAIN_OR_IP}"
    echo "- R-Studio:       https://${DOMAIN_OR_IP}/"
    echo "- Web Terminal:   https://${DOMAIN_OR_IP}/terminal/"
    echo "- Web SSH:        https://${DOMAIN_OR_IP}/ssh/"
    echo -e "----------------------------------------"
}

main "$@"