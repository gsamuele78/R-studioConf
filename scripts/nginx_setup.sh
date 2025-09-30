#!/bin/bash

# A script to set up Nginx as a reverse proxy for R-Studio Server and other web services.
# It uses a modular structure and leverages the functions in common_utils.sh.
# VERSION 2.1: FINAL. Fixes shell variable expansion issue during template deployment.

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
    while getopts "c:h" opt; do
        case ${opt} in
            c) config_file="${OPTARG}" ;;
            h|*) usage ;;
        esac
    done
    
    source "$config_file"

    # Step 1: Interactive Configuration
    log "INFO" "--- Interactive Nginx Setup ---"
    echo "Please confirm the settings below. Press Enter to accept the default."
    prompt_for_value "Domain or IP Address" "DOMAIN_OR_IP"
    prompt_for_value "R-Studio Port" "RSTUDIO_PORT"
    prompt_for_value "Web Terminal Port" "WEB_TERMINAL_PORT"
    prompt_for_value "Web SSH Port" "WEB_SSH_PORT"
    echo "-------------------------------------"
    log "INFO" "Configuration confirmed. Proceeding with setup..."
    
    # Step 2: Install Nginx with Automated Fix
    log "INFO" "Starting: Install Nginx package"
    if ! sudo apt-get update && sudo apt-get install -y nginx; then
        if _fix_ipv6_binding_issue; then
            run_command "Retry Nginx installation after applying fix" "apt-get install -y nginx"
        else
            log "ERROR" "Nginx installation failed and could not be fixed."
            exit 1
        fi
    fi
    log "INFO" "SUCCESS: Install Nginx package"

    # Step 3: Create Directories
    ensure_dir_exists "$NGINX_TEMPLATE_DIR"
    ensure_dir_exists "$SSL_CERT_DIR"

    # Step 4: Create Self-Signed Certificate
    # (This section is unchanged and correct)
    log "INFO" "Checking for self-signed SSL certificate..."
    local cert_path="$SSL_CERT_DIR/$DOMAIN_OR_IP.crt"
    local key_path="$SSL_CERT_DIR/$DOMAIN_OR_IP.key"
    if [ ! -f "$cert_path" ]; then
        local openssl_cmd="openssl req -x509 -nodes -days \"$SSL_DAYS\" -newkey rsa:2048 -keyout \"$key_path\" -out \"$cert_path\" -subj \"/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/OU=$SSL_ORG_UNIT/CN=$DOMAIN_OR_IP\""
        run_command "Generate self-signed certificate" "$openssl_cmd"
    else
        log "WARN" "Certificate for $DOMAIN_OR_IP already exists. Skipping creation."
    fi

    # Step 5: Process and Deploy Templates
    log "INFO" "Processing and deploying Nginx templates..."
    run_command "Deploy static SSL params template" "cp '${TEMPLATE_DIR}/nginx_ssl_params.conf.template' '${NGINX_TEMPLATE_DIR}/nginx_ssl_params.conf'"
    
    local template_args=(
        "DOMAIN_OR_IP=${DOMAIN_OR_IP}" "RSTUDIO_PORT=${RSTUDIO_PORT}" "WEB_TERMINAL_PORT=${WEB_TERMINAL_PORT}"
        "WEB_SSH_PORT=${WEB_SSH_PORT}" "LOG_DIR=${LOG_DIR}" "NGINX_TEMPLATE_DIR=${NGINX_TEMPLATE_DIR}" "SSL_CERT_DIR=${SSL_CERT_DIR}"
    )

    local processed_content

    # --- THE FIX IS HERE ---
    # We now use a temporary file and a 'here document' to deploy the templates.
    # This prevents the shell from expanding variables like $host and $http_upgrade.

    process_template "${TEMPLATE_DIR}/nginx_self_signed_snippet.conf.template" "processed_content" "${template_args[@]}"
    sudo bash -c "cat > '${NGINX_TEMPLATE_DIR}/nginx_self_signed_snippet.conf' <<'EOF'
${processed_content}
EOF"
    log "INFO" "SUCCESS: Deploy self-signed snippet"

    process_template "${TEMPLATE_DIR}/nginx_proxy_location.conf.template" "processed_content" "${template_args[@]}"
    sudo bash -c "cat > '${NGINX_TEMPLATE_DIR}/nginx_proxy_location.conf' <<'EOF'
${processed_content}
EOF"
    log "INFO" "SUCCESS: Deploy proxy location snippet"

    process_template "${TEMPLATE_DIR}/nginx_self_signed_site.conf.template" "processed_content" "${template_args[@]}"
    sudo bash -c "cat > '${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf' <<'EOF'
${processed_content}
EOF"
    log "INFO" "SUCCESS: Deploy main Nginx site configuration"

    # Step 6: Enable Site and Restart Nginx
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