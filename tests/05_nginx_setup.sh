#!/bin/bash
set -euo pipefail
# NGINX Setup Script (Revised)
# Script revision: 2025-11-06 (system engineer review)

# Load utility functions from common_utils.sh
UTILS_SCRIPT_PATH="$(dirname "$BASH_SOURCE")/../lib/common_utils.sh"
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
  echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
  exit 2
fi
source "$UTILS_SCRIPT_PATH"

# Load configuration
DEFAULT_CONFIG_FILE="$(dirname "$BASH_SOURCE")/../config/nginx_setup.vars.conf"
TEMPLATE_DIR="$(dirname "$BASH_SOURCE")/../templates"
NGINX_CONF_PATH="/etc/nginx/nginx.conf"

usage() {
  echo -e "\033[1;33mUsage: $0 [-c path_to_nginx_setup.vars.conf]\033[0m"
  echo "  -c    Path to nginx_setup.vars.conf (optional)"
  exit 1
}

trap 'handleerror $? "Fatal error occurred. Exiting."' ERR
trap 'log INFO "Exiting Nginx Setup."' EXIT

main() {
  checkroot
  local configfile="$DEFAULT_CONFIG_FILE"
  while getopts "c:h" opt; do
    case "$opt" in
      c) configfile="$OPTARG";;
      h) usage;;
    esac
  done
  if [[ ! -f "$configfile" ]]; then
    echo "ERROR: Config file missing: $configfile" >&2
    exit 3
  fi
  source "$configfile"
  
  log INFO "--- Interactive Nginx Setup ---"

  echo "Please confirm or edit the settings. Press Enter to accept default values."
  promptforvalue "Certificate Mode [SELF_SIGNED/LETS_ENCRYPT]" CERT_MODE
  promptforvalue "Domain or IP Address" DOMAIN_OR_IP
  if [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
    promptforvalue "Let's Encrypt Email" LE_EMAIL
  else
    promptforvalue "Country (2 letters)" SSL_COUNTRY
    promptforvalue "State or Province" SSL_STATE
    promptforvalue "Locality (City)" SSL_LOCALITY
    promptforvalue "Organization" SSL_ORGANIZATION
    promptforvalue "Org Unit" SSL_ORG_UNIT
  fi
  promptforvalue "R-Studio Port" RSTUDIO_PORT
  promptforvalue "Web Terminal Port" WEB_TERMINAL_PORT
  promptforvalue "FileBrowser Port" FILEBROWSER_PORT
  echo "--------------------------------------"

  log INFO "Configuration confirmed. Proceeding."

  # Step 1: Installation
  log INFO "Installing nginx-full..."
  runcommand "Update package lists" "apt-get -y update"
  runcommand "Purge nginx packages" "apt-get remove --purge -y nginx nginx-common nginx-core nginx-full"
  runcommand "Autoremove unused packages" "apt-get autoremove -y"
  log INFO "Installing nginx-full..."
  if ! runcommand "Install nginx-full" "apt-get -y install nginx-full"; then
    if ! fixipv6andfinishinstall; then
      log ERROR "Failed to install/repair nginx-full."
      exit 4
    fi
  fi
  log INFO "nginx-full package installed."

  # SSSD permission
  log INFO "Configuring permissions for www-data to SASL..."
  runcommand "Add www-data to sasl group" "usermod -a -G sasl www-data"
  log INFO "Permissions configured."

  # Ensure paths exist
  ensuredirexists "$NGINX_TEMPLATE_DIR"
  ensuredirexists "$SSL_CERT_DIR"
  ensuredirexists "/var/www/html"

  log INFO "Checking DH param file..."
  if [[ ! -f "$DHPARAM_PATH" ]]; then
    runcommand "Generate Diffie-Hellman parameters" "openssl dhparam -out $DHPARAM_PATH 2048"
  else
    log WARN "DH param file already exists. Skipping."
  fi

  local cert_fullpath
  local key_fullpath
  if [[ "$CERT_MODE" == "SELF_SIGNED" ]]; then
    cert_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.crt"
    key_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.key"
    if [[ ! -f "$cert_fullpath" ]]; then
      local opensslcmd="openssl req -x509 -nodes -days $SSL_DAYS -newkey rsa:2048 -keyout $key_fullpath -out $cert_fullpath -subj /C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/OU=$SSL_ORG_UNIT/CN=$DOMAIN_OR_IP"
      runcommand "Generate self-signed certificate" "$opensslcmd"
    else
      log WARN "Self-signed certificate already exists. Skipping."
    fi
  elif [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
    cert_fullpath="$LE_CERT_DIR/$DOMAIN_OR_IP/fullchain.pem"
    key_fullpath="$LE_CERT_DIR/$DOMAIN_OR_IP/privkey.pem"
    if [[ ! -f "$cert_fullpath" ]]; then
      runcommand "Stop nginx for Certbot" "systemctl stop nginx"
      local certbotcmd="certbot certonly --standalone -d $DOMAIN_OR_IP --non-interactive --agree-tos -m $LE_EMAIL"
      runcommand "Obtain Let's Encrypt certificate" "$certbotcmd"
    else
      log WARN "Let's Encrypt certificate already exists. Skipping."
    fi
  else
    log FATAL "Invalid CERT_MODE: $CERT_MODE"
    exit 5
  fi

  # Template processing
  local templateargs=(DOMAIN_OR_IP "$DOMAIN_OR_IP" RSTUDIO_PORT "$RSTUDIO_PORT" WEB_TERMINAL_PORT "$WEB_TERMINAL_PORT" FILEBROWSER_PORT "$FILEBROWSER_PORT" LOG_DIR "$LOG_DIR" NGINX_TEMPLATE_DIR "$NGINX_TEMPLATE_DIR" CERT_FULLPATH "$cert_fullpath" KEY_FULLPATH "$key_fullpath" DHPARAM_FULLPATH "$DHPARAM_PATH")

  local processedcontent
  processtemplate "$TEMPLATE_DIR/nginx_ssl_params.conf.template" processedcontent "${templateargs[@]}"
  echo "$processedcontent" | sudo tee "$NGINX_TEMPLATE_DIR/nginx_ssl_params.conf" >/dev/null
  processtemplate "$TEMPLATE_DIR/nginx_ssl_certificate.conf.template" processedcontent "${templateargs[@]}"
  echo "$processedcontent" | sudo tee "$NGINX_TEMPLATE_DIR/nginx_ssl_certificate.conf" >/dev/null
  processtemplate "$TEMPLATE_DIR/nginx_proxy_location.conf.template" processedcontent "${templateargs[@]}"
  echo "$processedcontent" | sudo tee "$NGINX_TEMPLATE_DIR/nginx_proxy_location.conf" >/dev/null
  processtemplate "$TEMPLATE_DIR/nginx_site.conf.template" processedcontent "${templateargs[@]}"
  echo "$processedcontent" | sudo tee "$NGINX_DIR/sites-available/$DOMAIN_OR_IP.conf" >/dev/null

  log INFO "All templates processed and deployed."
  log INFO "Enabling site and restarting nginx..."
  runcommand "Clean sites-enabled" "rm -f $NGINX_DIR/sites-enabled/*"
  runcommand "Enable Nginx site" "ln -sf $NGINX_DIR/sites-available/$DOMAIN_OR_IP.conf $NGINX_DIR/sites-enabled/"
  runcommand "Test nginx config" "nginx -t"
  runcommand "Restart nginx" "systemctl restart nginx"

  log INFO "Nginx setup complete!"
  echo "Services are configured for https://$DOMAIN_OR_IP"
  echo " - R-Studio:        https://$DOMAIN_OR_IP"
  echo " - Terminal:        https://$DOMAIN_OR_IP/terminal"
  echo " - File Browser:    https://$DOMAIN_OR_IP/files"
  echo " - FileBrowser API: https://$DOMAIN_OR_IP/files/api"
  echo "-----------------------------------------"
}

main "$@"
