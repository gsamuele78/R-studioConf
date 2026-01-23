#!/bin/bash
set -euo pipefail

# =====================================================================
# Update Nginx Templates Script
# =====================================================================
# Regenerates Nginx configuration files from templates using current variables.
# Useful for applying template changes without full reinstallation.
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
CONFIG_FILE="${SCRIPT_DIR}/../config/install_nginx.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# Validate and source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
  echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
  exit 2
fi
source "$UTILS_SCRIPT_PATH"

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    log ERROR "Config file not found: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

log INFO "--- Updating Nginx Configuration from Templates ---"

# Derive implied variables (logic borrowed from 30_install_nginx.sh)
cert_fullpath=""
key_fullpath=""

if [[ "$CERT_MODE" == "SELF_SIGNED" ]]; then
    cert_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.crt"
    key_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.key"
elif [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
    cert_fullpath="${LE_CERT_DIR}/${DOMAIN_OR_IP}/fullchain.pem"
    key_fullpath="${LE_CERT_DIR}/${DOMAIN_OR_IP}/privkey.pem"
else
    log ERROR "Unknown CERT_MODE: $CERT_MODE"
    exit 1
fi

log INFO "Using Certificate: $cert_fullpath"
log INFO "Using Key: $key_fullpath"

# Ensure directories exist (just in case)
ensure_dir_exists "$NGINX_TEMPLATE_DIR"

# Process Templates
log INFO "Processing templates..."

declare -a template_args=(
    "DOMAIN_OR_IP=${DOMAIN_OR_IP}" "RSTUDIO_PORT=${RSTUDIO_PORT}" "WEB_TERMINAL_PORT=${WEB_TERMINAL_PORT}"
    "NEXTCLOUD_TARGET_URL=${NEXTCLOUD_TARGET_URL}" "LOG_DIR=${LOG_DIR}" "NGINX_TEMPLATE_DIR=${NGINX_TEMPLATE_DIR}"
    "CERT_FULLPATH=${cert_fullpath}" "KEY_FULLPATH=${key_fullpath}" "DHPARAM_FULLPATH=${DHPARAM_PATH}"
)
processed_content=""

# 1. SSL Params
process_template "${TEMPLATE_DIR}/nginx_ssl_params.conf.template" "processed_content" "${template_args[@]}"
echo "$processed_content" | sudo tee "${NGINX_TEMPLATE_DIR}/nginx_ssl_params.conf" > /dev/null
log INFO "Updated ${NGINX_TEMPLATE_DIR}/nginx_ssl_params.conf"

# 2. SSL Certificate
process_template "${TEMPLATE_DIR}/nginx_ssl_certificate.conf.template" "processed_content" "${template_args[@]}"
echo "$processed_content" | sudo tee "${NGINX_TEMPLATE_DIR}/nginx_ssl_certificate.conf" > /dev/null
log INFO "Updated ${NGINX_TEMPLATE_DIR}/nginx_ssl_certificate.conf"

# 3. Proxy Location (The critical one)
process_template "${TEMPLATE_DIR}/nginx_proxy_location.conf.template" "processed_content" "${template_args[@]}"
echo "$processed_content" | sudo tee "${NGINX_TEMPLATE_DIR}/nginx_proxy_location.conf" > /dev/null
log INFO "Updated ${NGINX_TEMPLATE_DIR}/nginx_proxy_location.conf"

# 4. Site Config
process_template "${TEMPLATE_DIR}/nginx_site.conf.template" "processed_content" "${template_args[@]}"
echo "$processed_content" | sudo tee "${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf" > /dev/null
log INFO "Updated ${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf"

# Reload Nginx
log INFO "Testing Nginx configuration..."
if run_command "nginx -t" "nginx -t"; then
    log INFO "Configuration valid. Restarting Nginx..."
    run_command "Restart Nginx" "systemctl restart nginx"
    log INFO "SUCCESS: Nginx configuration updated and service restarted."
else
    log ERROR "Nginx configuration test failed. Changes applied but service NOT restarted. Please check 'nginx -t' output."
    exit 1
fi
