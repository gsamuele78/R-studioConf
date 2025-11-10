#!/bin/bash
set -euo pipefail

# =====================================================================
# NGINX Setup Script (Definitive v2.2 - Optimized Edition)
# =====================================================================
# Comprehensive Nginx reverse proxy setup with full lifecycle management
# Includes: Install, Configure, Backup, Restore, Uninstall
# Sourced from: lib/common_utils.sh
# Version: 2025-11-06 (System Engineer Review - Optimized)
# =====================================================================

# =====================================================================
# LOAD COMMON UTILITIES
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/nginx_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
NGINX_CONF_PATH="/etc/nginx/nginx.conf"

# Validate and source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
  echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
  exit 2
fi
source "$UTILS_SCRIPT_PATH"

# =====================================================================
# ERROR HANDLING AND CLEANUP TRAPS
# =====================================================================
# Note: Leverages log() function from common_utils.sh for consistent
# logging and error reporting across the entire script ecosystem.

trap 'log FATAL "Fatal error occurred at line $LINENO"' ERR
trap 'log INFO "Exiting Nginx Setup."' EXIT

# =====================================================================
# SCRIPT-SPECIFIC UTILITY FUNCTIONS
# =====================================================================
# These functions are custom to the Nginx setup workflow and not
# available in common_utils.sh

usage() {
  echo -e "\033[1;33mUsage: $0 [-c /path/to/nginx_setup.vars.conf]\033[0m"
  echo "  -c: Path to the configuration file (Optional)"
  echo ""
  echo "This script manages Nginx reverse proxy setup with the following modes:"
  echo "  Interactive menu allows: Install/Configure, Uninstall, Restore from backup, Exit"
  exit 1
}

# =====================================================================
# IPV6 BINDING ISSUE FIX
# =====================================================================
# Handles systems with disabled IPv6 stack that prevent standard Nginx
# installation. Comments out IPv6 directives and reconfigures packages.

_fix_ipv6_and_finish_install() {
  log WARN "Initial Nginx installation failed, likely due to disabled IPv6 stack."
  log INFO "Attempting to fix by commenting out IPv6 listen directives..."
  
  local conf_files=()
  if [[ -d "/etc/nginx/conf.d" ]]; then
    mapfile -t conf_files < <(find /etc/nginx/conf.d -maxdepth 1 -name "*.conf")
  fi
  if [[ -d "/etc/nginx/sites-enabled" ]]; then
    mapfile -t conf_files < <(find /etc/nginx/sites-enabled -maxdepth 1 -type f)
  fi
  
  for conf_file in "${conf_files[@]}"; do
    if [[ -f "$conf_file" ]]; then
      log INFO "Scanning ${conf_file}..."
      sed -i.bak 's/listen \[::\]:/# listen [::]:/' "$conf_file" || true
    fi
  done
  
  log INFO "IPv6 directives commented out. Forcing reconfiguration of pending packages..."
  if ! run_command "Force configure pending packages" "dpkg --configure -a"; then
    log ERROR "Failed to fix broken packages with 'dpkg --configure -a'."
    return 1
  fi
  
  log INFO "SUCCESS: Nginx installation has been repaired."
  return 0
}

# =====================================================================
# MAIN SETUP AND INSTALLATION LOGIC
# =====================================================================

install_and_configure_nginx() {
  log INFO "--- Interactive Nginx Setup ---"
  echo "Please confirm or edit the settings. Press Enter to accept default values."
  
  # Load configuration
  if [[ ! -f "$config_file" ]]; then
    log ERROR "Config file not found: $config_file"
    return 1
  fi
  source "$config_file"
  
  # Interactive prompts (using prompt_for_value from common_utils.sh)
  prompt_for_value "Certificate Mode (SELF_SIGNED/LETS_ENCRYPT)" "CERT_MODE"
  prompt_for_value "Domain or IP Address" "DOMAIN_OR_IP"
  
  if [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
    prompt_for_value "Let's Encrypt Email" "LE_EMAIL"
  else
    prompt_for_value "Self-Signed: Country (2-letter code)" "SSL_COUNTRY"
    prompt_for_value "Self-Signed: State or Province" "SSL_STATE"
    prompt_for_value "Self-Signed: Locality (eg, city)" "SSL_LOCALITY"
    prompt_for_value "Self-Signed: Organization Name" "SSL_ORGANIZATION"
    prompt_for_value "Self-Signed: Organizational Unit" "SSL_ORG_UNIT"
  fi
  
  prompt_for_value "R-Studio Port" "RSTUDIO_PORT"
  prompt_for_value "Web Terminal Port" "WEB_TERMINAL_PORT"
  prompt_for_value "FileBrowser Port" "FILEBROWSER_PORT"
  
  echo "-------------------------------------"
  log INFO "Configuration confirmed. Proceeding with setup..."
  
  # Step 1: Package installation with automated fix
  log INFO "Starting installation of required packages..."
  local packages_to_install="nginx-full"
  
  if [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
    packages_to_install+=" certbot python3-certbot-nginx"
  fi
  
  run_command "Update package lists" "apt-get -y update"
  log INFO "Purging any existing Nginx packages..."
  run_command "Purge nginx packages" "apt-get remove --purge -y nginx nginx-common nginx-core nginx-full" || log WARN "Nginx packages not found or already removed."
  run_command "Autoremove unused packages" "apt-get autoremove -y" || true
  
  log INFO "Installing required packages..."
  if ! run_command "Install packages" "apt-get -y install $packages_to_install"; then
    if ! _fix_ipv6_and_finish_install; then
      log ERROR "Failed to install or repair packages."
      return 1
    fi
  fi
  
  log INFO "SUCCESS: Required packages installed."
  
  # Step 2: SSSD/PAM permissions
  log INFO "Granting Nginx permission to communicate with SSSD..."
  run_command "Add www-data to sasl group" "usermod -a -G sasl www-data"
  log INFO "SUCCESS: Nginx permissions configured."
  
  # Step 3: Create required directories (using ensure_dir_exists from common_utils.sh)
  ensure_dir_exists "$NGINX_TEMPLATE_DIR"
  ensure_dir_exists "$SSL_CERT_DIR"
  ensure_dir_exists "/var/www/html"
  
  # Step 4: Generate Diffie-Hellman parameters
  log INFO "Checking for Diffie-Hellman parameter file..."
  if [[ ! -f "$DHPARAM_PATH" ]]; then
    run_command "Generate Diffie-Hellman parameters (2048 bit)" "openssl dhparam -out \"$DHPARAM_PATH\" 2048"
  else
    log WARN "Diffie-Hellman parameter file already exists. Skipping."
  fi
  
  # Step 5: Obtain/Generate SSL Certificate
  local cert_fullpath=""
  local key_fullpath=""
  
  if [[ "$CERT_MODE" == "SELF_SIGNED" ]]; then
    log INFO "Certificate Mode: SELF_SIGNED"
    cert_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.crt"
    key_fullpath="$SSL_CERT_DIR/$DOMAIN_OR_IP.key"
    
    if [[ ! -f "$cert_fullpath" ]]; then
      local openssl_cmd="openssl req -x509 -nodes -days \"$SSL_DAYS\" -newkey rsa:2048 -keyout \"$key_fullpath\" -out \"$cert_fullpath\" -subj \"/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/OU=$SSL_ORG_UNIT/CN=$DOMAIN_OR_IP\""
      run_command "Generate self-signed certificate" "$openssl_cmd"
    else
      log WARN "Self-signed certificate for $DOMAIN_OR_IP already exists. Skipping."
    fi
    
  elif [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
    log INFO "Certificate Mode: LETS_ENCRYPT"
    cert_fullpath="${LE_CERT_DIR}/${DOMAIN_OR_IP}/fullchain.pem"
    key_fullpath="${LE_CERT_DIR}/${DOMAIN_OR_IP}/privkey.pem"
    
    if [[ ! -f "$cert_fullpath" ]]; then
      run_command "Stop Nginx for Certbot" "systemctl stop nginx"
      local certbot_cmd="certbot certonly --standalone -d \"$DOMAIN_OR_IP\" --non-interactive --agree-tos -m \"$LE_EMAIL\""
      run_command "Obtain Let's Encrypt certificate" "$certbot_cmd"
    else
      log WARN "Let's Encrypt certificate for $DOMAIN_OR_IP already exists. Skipping."
    fi
  else
    log ERROR "Invalid CERT_MODE: '$CERT_MODE'. Must be 'SELF_SIGNED' or 'LETS_ENCRYPT'."
    return 1
  fi
  
  # Step 6: Process and deploy templates (using process_template from common_utils.sh)
  log INFO "Processing and deploying Nginx templates..."
  local template_args=(
    "DOMAIN_OR_IP=${DOMAIN_OR_IP}"
    "RSTUDIO_PORT=${RSTUDIO_PORT}"
    "WEB_TERMINAL_PORT=${WEB_TERMINAL_PORT}"
    "FILEBROWSER_PORT=${FILEBROWSER_PORT}"
    "LOG_DIR=${LOG_DIR}"
    "NGINX_TEMPLATE_DIR=${NGINX_TEMPLATE_DIR}"
    "CERT_FULLPATH=${cert_fullpath}"
    "KEY_FULLPATH=${key_fullpath}"
    "DHPARAM_FULLPATH=${DHPARAM_PATH}"
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
  
  log INFO "SUCCESS: All templates processed and deployed."
  
  # Step 7: Enable site and restart Nginx
  log INFO "Enabling site and restarting Nginx..."
  run_command "Clean sites-enabled directory" "rm -f '${NGINX_DIR}/sites-enabled/'*"
  run_command "Enable Nginx site for ${DOMAIN_OR_IP}" "ln -sf '${NGINX_DIR}/sites-available/${DOMAIN_OR_IP}.conf' '${NGINX_DIR}/sites-enabled/'"
  run_command "Test Nginx configuration" "nginx -t"
  run_command "Restart Nginx service" "systemctl restart nginx"
  
  # Step 8: Final output
  log INFO "-----------------------------------------------------------"
  log INFO "Nginx setup complete!"
  echo ""
  echo "Services are configured for: https://${DOMAIN_OR_IP}"
  echo "  - R-Studio:       https://${DOMAIN_OR_IP}/"
  echo "  - Web Terminal:   https://${DOMAIN_OR_IP}/terminal/"
  echo "  - FileBrowser:    https://${DOMAIN_OR_IP}/files/"
  echo "  - FileBrowser API: https://${DOMAIN_OR_IP}/files/api"
  echo "-----------------------------------------------------------"
}

# =====================================================================
# UNINSTALL FUNCTION
# =====================================================================
# Complete removal of Nginx packages and configurations with backup

uninstall_nginx() {
  log INFO "Starting Nginx Uninstallation..."
  backup_config
  
  local confirm_uninstall
  read -r -p "This will remove Nginx packages and clean configs. Continue? (y/n): " confirm_uninstall
  
  if [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]]; then
    log INFO "Uninstallation cancelled."
    return 0
  fi
  
  log INFO "Stopping and disabling Nginx..."
  run_command "Stop Nginx" "systemctl stop nginx" || log WARN "Nginx was not running."
  run_command "Disable Nginx" "systemctl disable nginx" || log WARN "Nginx was not enabled."
  
  log INFO "Removing Nginx packages..."
  run_command "Remove Nginx packages" "apt-get remove --purge -y nginx nginx-common nginx-core nginx-full" || log WARN "Some packages could not be removed."
  run_command "Autoremove unused packages" "apt-get autoremove -y" || true
  
  log INFO "Cleaning Nginx configurations (backups kept in session backup dir)..."
  run_command "Remove nginx directory" "rm -rf /etc/nginx" || true
  
  log INFO "Uninstall attempt complete."
  log INFO "Review logs and backups in $CURRENT_BACKUP_DIR to restore if needed."
}

# =====================================================================
# INTERACTIVE MENU SYSTEM
# =====================================================================
# Menu-driven interface for comprehensive Nginx lifecycle management

show_menu() {
  echo ""
  printf "\n=== Nginx Setup Menu ===\n"
  printf "1) Install/Configure Nginx\n"
  printf "U) Uninstall Nginx and restore system\n"
  printf "R) Restore configurations from most recent backup\n"
  printf "4) Exit\n"
  read -r -p "Choice: " choice
  
  case "$choice" in
    1)
      backup_config
      install_and_configure_nginx
      ;;
    U|u)
      uninstall_nginx
      ;;
    R|r)
      restore_config
      ;;
    4|*) 
      log INFO "Exiting Nginx Setup."
      return 0
      ;;
  esac
}

# =====================================================================
# MAIN ENTRY POINT
# =====================================================================

main() {
  # Validate root privileges (using check_root from common_utils.sh)
  check_root
  
  # Parse command-line arguments
  local config_file="$DEFAULT_CONFIG_FILE"
  while getopts "c:h" opt; do
    case "$opt" in
      c) config_file="$OPTARG";;
      h) usage;;
      *) usage;;
    esac
  done
  
  # Validate config file
  if [[ ! -f "$config_file" ]]; then
    log ERROR "Config file not found: $config_file"
    log ERROR "Expected location: $DEFAULT_CONFIG_FILE"
    exit 3
  fi
  
  # Initialize backup directory (using setup_backup_dir from common_utils.sh)
  setup_backup_dir
  
  # Show interactive menu
  show_menu
}

# =====================================================================
# SCRIPT EXECUTION
# =====================================================================

main "$@"
