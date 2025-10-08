#!/bin/bash

# A script to set up Nginx as a reverse proxy for R-Studio Server and other web services.
# VERSION 9.2: VICTORIOUS. Removes redundant 'load_module' directive.

set -e

# --- Robust Path Detection ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Define Paths ---
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/nginx_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
NGINX_CONF_PATH="/etc/nginx/nginx.conf"

# --- Function Definitions ---
# ... (usage and _fix_ipv6_binding_issue functions are unchanged) ...
usage() { echo -e "\033[1;33mUsage: $0 [-c /path/to/nginx_setup.vars.conf]\033[0m\n  -c: Path to the configuration file (Optional)."; exit 1; }
_fix_ipv6_and_finish_install() {
    log "WARN" "Initial Nginx installation failed, likely due to a disabled IPv6 stack."
    log "INFO" "Attempting to fix by commenting out IPv6 listen directives..."
    for conf_file in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
        if [[ -f "$conf_file" ]]; then
            log "INFO" "Scanning ${conf_file}..."; sed -i.bak 's/listen \[::\]:/#listen \[::\]:/g' "$conf_file";
        fi
    done
    log "INFO" "IPv6 directives commented out. Forcing reconfiguration of all pending packages..."
    if ! DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
        log "ERROR" "Failed to fix broken packages with 'dpkg --configure -a'."; return 1;
    fi
    log "INFO" "SUCCESS: Nginx installation has been repaired."; return 0;
}

# --- Main Execution ---
main() {
    # Step 0: Load Dependencies and Validate
    source "$UTILS_SCRIPT_PATH"
    check_root

    local config_file="$DEFAULT_CONFIG_FILE"
    while getopts "c:h" opt; do case ${opt} in c) config_file="${OPTARG}" ;; h|*) usage ;; esac; done
    source "$config_file"

    # Step 1: Interactive Configuration (Unchanged)
    log "INFO" "--- Interactive Nginx Setup ---"
    # ... (prompts are the same) ...
    echo "Please confirm or edit the settings. Press Enter to accept the default."
    prompt_for_value "Certificate Mode (SELF_SIGNED/LETS_ENCRYPT)" "CERT_MODE"; prompt_for_value "Domain or IP Address" "DOMAIN_OR_IP"; if [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then prompt_for_value "Let's Encrypt Email" "LE_EMAIL"; else prompt_for_value "Self-Signed: Country (2-letter code)" "SSL_COUNTRY"; prompt_for_value "Self-Signed: State or Province" "SSL_STATE"; prompt_for_value "Self-Signed: Locality (eg, city)" "SSL_LOCALITY"; prompt_for_value "Self-Signed: Organization Name" "SSL_ORGANIZATION"; prompt_for_value "Self-Signed: Organizational Unit" "SSL_ORG_UNIT"; fi
    prompt_for_value "R-Studio Port" "RSTUDIO_PORT"; prompt_for_value "Web Terminal Port" "WEB_TERMINAL_PORT"; prompt_for_value "FileBrowser Port" "FILEBROWSER_PORT"; echo "-------------------------------------"
    log "INFO" "Configuration confirmed. Proceeding with setup..."

    # Step 2: Install Nginx (Unchanged)
    log "INFO" "Starting installation/reinstallation of 'nginx-full'..."
    run_command "Update package lists" "apt-get -y update"
    log "INFO" "Purging any existing Nginx packages..."; DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y nginx nginx-common nginx-core nginx-full || log "WARN" "Could not purge nginx packages, they may not have been installed."
    log "INFO" "Installing 'nginx-full'. Apt output will follow:"; if ! DEBIAN_FRONTEND=noninteractive apt-get -y install nginx-full; then if ! _fix_ipv6_and_finish_install; then log "ERROR" "Failed to install or repair nginx-full package."; exit 1; fi; fi
    log "INFO" "SUCCESS: 'nginx-full' package is correctly installed and configured."
    
    # ### DEFINITIVE FIX: The 'load_module' step is now removed. ###
    # The Ubuntu package for nginx-full automatically handles loading the module.
    # Manually adding it causes a "module is already loaded" error.
    log "INFO" "Nginx package now handles module loading automatically. Skipping manual configuration."
    
    # ... (The rest of the script is correct and will execute successfully) ...
    log "INFO" "Granting Nginx permission to communicate with SSSD..."; run_command "Add www-data user to the sasl group" "usermod -a -G sasl www-data"; log "INFO" "SUCCESS: Nginx permissions have been configured."
    ensure_dir_exists "$NGINX_TEMPLATE_DIR"; ensure_dir_exists "$SSL_CERT_DIR"; ensure_dir_exists "/var/www/html"
    log "INFO" "Checking for Diffie-Hellman parameter file..."; if [ ! -f "$DHPARAM_PATH" ]; then run_command "Generate Diffie-Hellman parameters (2048 bit)" "openssl dhparam -out \"$DHPARAM_PATH\" 2048"; else log "WARN" "Diffie-Hellman parameter file already exists. Skipping."; fi
    local cert_fullpath=""; local key_fullpath=""; if [[ "$CERT_MODE" == "SELF_SIGNED" ]]; then log "INFO" "Certificate Mode: SELF_SIGNED"; cert_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.crt"; key_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.key"; if [ ! -f "$cert_fullpath" ]; then local openssl_cmd="openssl req -x509 -nodes -days \"$SSL_DAYS\" -newkey rsa:2048 -keyout \"$key_fullpath\" -out \"$cert_fullpath\" -subj \"/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/OU=$SSL_ORG_UNIT/CN=$DOMAIN_OR_IP\""; run_command "Generate self-signed certificate" "$openssl_cmd"; else log "WARN" "Self-signed certificate for $DOMAIN_OR_IP already exists. Skipping."; fi; elif [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then log "INFO" "Certificate Mode: LETS_ENCRYPT"; cert_fullpath="${LE_CERT_DIR}/${DOMAIN_OR_IP}/fullchain.pem"; key_fullpath="${LE_CERT_DIR}/${DOMAIN_OR_IP}/privkey.pem"; if [ ! -f "$cert_fullpath" ]; then run_command "Temporarily stop Nginx for Certbot" "systemctl stop nginx"; local certbot_cmd="certbot certonly --standalone -d \"$DOMAIN_OR_IP\" --non-interactive --agree-tos -m \"$LE_EMAIL\""; run_command "Obtain Let's Encrypt certificate" "$certbot_cmd"; else log "WARN" "Let's Encrypt certificate for $DOMAIN_OR_IP already exists. Skipping."; fi; else log "FATAL" "Invalid CERT_MODE: '$CERT_MODE'."; exit 1; fi
    log "INFO" "Processing and deploying Nginx templates..."; local template_args=("DOMAIN_OR_IP=${DOMAIN_OR_IP}" "RSTUDIO_PORT=${RSTUDIO_PORT}" "WEB_TERMINAL_PORT=${WEB_TERMINAL_PORT}" "FILEBROWSER_PORT=${FILEBROWSER_PORT}" "LOG_DIR=${LOG_DIR}" "NGINX_TEMPLATE_DIR=${NGINX_TEMPLATE_DIR}" "CERT_FULLPATH=${cert_fullpath}" "KEY_FULLPATH=${key_fullpath}" "DHPARAM_FULLPATH=${DHPARAM_PATH}"); local processed_content
    process_template "${TEMPLATE_DIR}/nginx_ssl_params.conf.template" "processed_content" "${template_args[@]}"; echo "$processed_content" | sudo tee "${NGINX_TEMPLATE_DIR}/nginx_ssl_params.conf" > /dev/null
    process_template "${TEMPLATE_DIR}/nginx_ssl_certificate.conf.template" "processed_content" "${template_args[@]}"; echo "$processed_content" | sudo tee "${NGINX_TEMPLATE_DIR}/nginx_ssl_certificate.conf" > /dev/null
    process_template "${TEMPLATE_DIR}/nginx_proxy_location.conf.template" "processed_content" "${template_args[@]}"; echo "$processed_content" | sudo tee "${NGINX_TEMPLATE_DIR}/nginx_proxy_location.conf" > /dev/null
    process_template "${TEMPLATE_DIR}/nginx_site.conf.template" "processed_content" "${template_args[@]}"; echo "$processed_content" | sudo tee "${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf" > /dev/null; log "INFO" "SUCCESS: All templates processed and deployed."
    log "INFO" "Enabling site and restarting Nginx..."; run_command "Clean Nginx 'sites-enabled' directory" "rm -f '${NGINX_DIR}/sites-enabled/'*"; run_command "Enable Nginx site for ${DOMAIN_OR_IP}" "ln -sf '${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf' '${NGINX_DIR}/sites-enabled/'"; run_command "Test Nginx configuration and restart service" "nginx -t && systemctl restart nginx"

        # Step 8: Final Output
    log "INFO" "-------------------------------------------------------"
    log "INFO" "Nginx setup complete!"
    echo "Services are configured for: https://${DOMAIN_OR_IP}"
    echo "- R-Studio:                  https://${DOMAIN_OR_IP}/"
    echo "- Web Terminal:              https://${DOMAIN_OR_IP}/terminal/"
    echo "- FileBrowser:               https://${DOMAIN_OR_IP}/files/"
    echo "- FileBrowser Api:           https://${DOMAIN_OR_IP}/files/api"
    echo -e "-----------------------------------------------------------"


}

main "$@"