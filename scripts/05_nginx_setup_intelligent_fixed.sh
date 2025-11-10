#!/bin/bash
set -euo pipefail

# =====================================================================
# NGINX Setup Script (v2.4 - Intelligent Auto-Detection Edition - FIXED)
# =====================================================================
# Comprehensive Nginx reverse proxy setup with intelligent detection of
# existing SSSD or Samba authentication backends.
# Automatically parses configuration from AD join scripts and config files.
# Includes: Install, Configure, Backup, Restore, Uninstall
# Sourced from: lib/common_utils.sh
# Version: 2025-11-10 (Intelligent Backend Detection - Fixed)
# =====================================================================

# =====================================================================
# LOAD COMMON UTILITIES
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/nginx_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# Validate and source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
  echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
  exit 2
fi
source "$UTILS_SCRIPT_PATH"

# =====================================================================
# ERROR HANDLING AND CLEANUP TRAPS
# =====================================================================

trap 'log FATAL "Fatal error occurred at line $LINENO"' ERR
trap 'log INFO "Exiting Nginx Setup."' EXIT

# =====================================================================
# INTELLIGENT BACKEND DETECTION FUNCTIONS
# =====================================================================

detect_active_auth_backend() {
  # Check for running SSSD service
  if systemctl is-active -q sssd 2>/dev/null; then
    echo "SSSD"
    return 0
  fi
  
  # Check for running Samba services
  if systemctl is-active -q winbind 2>/dev/null || \
     systemctl is-active -q smbd 2>/dev/null; then
    echo "SAMBA"
    return 0
  fi
  
  echo "NONE"
}

detect_auth_from_config_files() {
  # Check SSSD configuration
  if [[ -f /etc/sssd/sssd.conf ]]; then
    echo "SSSD"
    return 0
  fi
  
  # Check Samba configuration
  if [[ -f /etc/samba/smb.conf ]]; then
    echo "SAMBA"
    return 0
  fi
  
  echo "NONE"
}

detect_auth_from_nsswitch() {
  if [[ ! -f /etc/nsswitch.conf ]]; then
    echo "NONE"
    return 0
  fi
  
  # Check for sssd entry
  if grep -q "^passwd.*sssd" /etc/nsswitch.conf 2>/dev/null; then
    echo "SSSD"
    return 0
  fi
  
  # Check for winbind entry
  if [[ grep -q "^passwd.*winbind" /etc/nsswitch.conf 2>/dev/null ]]; then
    echo "SAMBA"
    return 0
  fi
  
  echo "NONE"
}

detect_auth_from_pam() {
  # Check for pam_sss.so
  if grep -r "pam_sss\.so" /etc/pam.d/ 2>/dev/null | grep -qv "^Binary"; then
    echo "SSSD"
    return 0
  fi
  
  # Check for pam_winbind.so
  if grep -r "pam_winbind\.so" /etc/pam.d/ 2>/dev/null | grep -qv "^Binary"; then
    echo "SAMBA"
    return 0
  fi
  
  echo "NONE"
}

parse_sssd_config_for_vars() {
  if [[ ! -f /etc/sssd/sssd.conf ]]; then
    return 1
  fi
  
  # Extract domain name from sssd.conf
  local domain_line
  domain_line=$(grep -i "^\[domain/" /etc/sssd/sssd.conf | head -1 | sed 's/.*domain\/\([^]]*\).*/\1/')
  if [[ -n "$domain_line" ]]; then
    export AD_DOMAIN_LOWER="$domain_line"
    export AD_DOMAIN_UPPER="$(echo "$domain_line" | tr '[:lower:]' '[:upper:]')"
  fi
  
  # Extract home directory template
  local homedir_template
  homedir_template=$(grep -i "^fallback_homedir" /etc/sssd/sssd.conf | cut -d= -f2 | xargs)
  if [[ -n "$homedir_template" ]]; then
    export TEMPLATE_HOMEDIR="$homedir_template"
  fi
  
  # Extract allowed groups
  local allow_groups
  allow_groups=$(grep -i "^simple_allow_groups" /etc/sssd/sssd.conf | cut -d= -f2 | xargs)
  if [[ -n "$allow_groups" ]]; then
    export SSSD_ALLOWED_GROUPS="$allow_groups"
  fi
  
  return 0
}

parse_samba_config_for_vars() {
  if [[ ! -f /etc/samba/smb.conf ]]; then
    return 1
  fi
  
  # Extract realm/workgroup
  local realm
  realm=$(grep -i "^[[:space:]]*realm" /etc/samba/smb.conf | head -1 | cut -d= -f2 | xargs)
  if [[ -n "$realm" ]]; then
    export AD_DOMAIN_UPPER="$realm"
    export AD_REALM="$realm"
    export AD_DOMAIN_LOWER="$(echo "$realm" | tr '[:upper:]' '[:lower:]')"
  fi
  
  local workgroup
  workgroup=$(grep -i "^[[:space:]]*workgroup" /etc/samba/smb.conf | head -1 | cut -d= -f2 | xargs)
  if [[ -n "$workgroup" ]]; then
    export SAMBA_WORKGROUP="$workgroup"
  fi
  
  # Extract template home directory
  local template_homedir
  template_homedir=$(grep -i "^[[:space:]]*template homedir" /etc/samba/smb.conf | head -1 | cut -d= -f2 | xargs)
  if [[ -n "$template_homedir" ]]; then
    export TEMPLATE_HOMEDIR="$template_homedir"
  fi
  
  # Extract ID mapping ranges
  local idmap_low
  idmap_low=$(grep -i "^[[:space:]]*idmap config.*range" /etc/samba/smb.conf | grep -o "[0-9]*" | head -1)
  if [[ -n "$idmap_low" ]]; then
    export IDMAP_RANGE_LOW="$idmap_low"
  fi
  
  return 0
}

load_sssd_kerberos_config_vars() {
  local sssd_vars_file="${SCRIPT_DIR}/../config/sssd_kerberos_setup.vars.conf"
  if [[ -f "$sssd_vars_file" ]]; then
    # shellcheck source=/dev/null
    source "$sssd_vars_file" 2>/dev/null || true
    
    # Extract DEFAULT_* variables and export
    [[ -n "${DEFAULT_AD_DOMAIN_LOWER:-}" ]] && export AD_DOMAIN_LOWER="${AD_DOMAIN_LOWER:-${DEFAULT_AD_DOMAIN_LOWER}}"
    [[ -n "${DEFAULT_AD_DOMAIN_UPPER:-}" ]] && export AD_DOMAIN_UPPER="${AD_DOMAIN_UPPER:-${DEFAULT_AD_DOMAIN_UPPER}}"
    [[ -n "${DEFAULT_SIMPLE_ALLOW_GROUPS:-}" ]] && export SSSD_ALLOWED_GROUPS="${SSSD_ALLOWED_GROUPS:-${DEFAULT_SIMPLE_ALLOW_GROUPS}}"
    [[ -n "${DEFAULT_FALLBACK_HOMEDIR_TEMPLATE:-}" ]] && export TEMPLATE_HOMEDIR="${TEMPLATE_HOMEDIR:-${DEFAULT_FALLBACK_HOMEDIR_TEMPLATE}}"
  fi
}

load_samba_kerberos_config_vars() {
  local samba_vars_file="${SCRIPT_DIR}/../config/samba_kerberos_setup.vars.conf"
  if [[ -f "$samba_vars_file" ]]; then
    # shellcheck source=/dev/null
    source "$samba_vars_file" 2>/dev/null || true
    
    # Extract DEFAULT_* variables and export
    [[ -n "${DEFAULT_AD_DOMAIN_LOWER:-}" ]] && export AD_DOMAIN_LOWER="${AD_DOMAIN_LOWER:-${DEFAULT_AD_DOMAIN_LOWER}}"
    [[ -n "${DEFAULT_AD_DOMAIN_UPPER:-}" ]] && export AD_DOMAIN_UPPER="${AD_DOMAIN_UPPER:-${DEFAULT_AD_DOMAIN_UPPER}}"
    [[ -n "${DEFAULT_REALM:-}" ]] && export AD_REALM="${AD_REALM:-${DEFAULT_REALM}}"
    [[ -n "${DEFAULT_WORKGROUP:-}" ]] && export SAMBA_WORKGROUP="${SAMBA_WORKGROUP:-${DEFAULT_WORKGROUP}}"
    [[ -n "${DEFAULT_SIMPLE_ALLOW_GROUPS:-}" ]] && export SAMBA_ALLOWED_GROUPS="${SAMBA_ALLOWED_GROUPS:-${DEFAULT_SIMPLE_ALLOW_GROUPS}}"
    [[ -n "${DEFAULT_TEMPLATE_HOMEDIR:-}" ]] && export TEMPLATE_HOMEDIR="${TEMPLATE_HOMEDIR:-${DEFAULT_TEMPLATE_HOMEDIR}}"
    [[ -n "${DEFAULT_IDMAP_PERSONALE_RANGE_LOW:-}" ]] && export IDMAP_RANGE_LOW="${IDMAP_RANGE_LOW:-${DEFAULT_IDMAP_PERSONALE_RANGE_LOW}}"
    [[ -n "${DEFAULT_IDMAP_PERSONALE_RANGE_HIGH:-}" ]] && export IDMAP_RANGE_HIGH="${IDMAP_RANGE_HIGH:-${DEFAULT_IDMAP_PERSONALE_RANGE_HIGH}}"
  fi
}

intelligent_backend_detection() {
  log INFO "=== Intelligent Backend Detection ==="
  
  # Priority 1: Check active services
  local detected_active
  detected_active=$(detect_active_auth_backend)
  
  if [[ "$detected_active" != "NONE" ]]; then
    log INFO "Active service detected: $detected_active"
    echo "$detected_active"
    return 0
  fi
  
  # Priority 2: Check config files
  local detected_config
  detected_config=$(detect_auth_from_config_files)
  
  if [[ "$detected_config" != "NONE" ]]; then
    log INFO "Config file detected: $detected_config"
    echo "$detected_config"
    return 0
  fi
  
  # Priority 3: Check nsswitch.conf
  local detected_nsswitch
  detected_nsswitch=$(detect_auth_from_nsswitch)
  
  if [[ "$detected_nsswitch" != "NONE" ]]; then
    log INFO "NSSwitch entry detected: $detected_nsswitch"
    echo "$detected_nsswitch"
    return 0
  fi
  
  # Priority 4: Check PAM configuration
  local detected_pam
  detected_pam=$(detect_auth_from_pam)
  
  if [[ "$detected_pam" != "NONE" ]]; then
    log INFO "PAM module detected: $detected_pam"
    echo "$detected_pam"
    return 0
  fi
  
  log INFO "No existing auth backend detected"
  echo "NONE"
}

autofill_from_detected_backend() {
  local detected_backend="$1"
  
  log INFO "Auto-filling configuration from detected backend: $detected_backend"
  
  if [[ "$detected_backend" == "SSSD" ]]; then
    log INFO "Parsing SSSD configuration..."
    parse_sssd_config_for_vars
    load_sssd_kerberos_config_vars
  elif [[ "$detected_backend" == "SAMBA" ]]; then
    log INFO "Parsing Samba configuration..."
    parse_samba_config_for_vars
    load_samba_kerberos_config_vars
  fi
}

# =====================================================================
# SCRIPT-SPECIFIC UTILITY FUNCTIONS
# =====================================================================

usage() {
  echo -e "\033[1;33mUsage: $0 [-c /path/to/nginx_setup.vars.conf] [-d]\033[0m"
  echo "  -c: Path to the configuration file (Optional)"
  echo "  -d: Enable auto-detection of existing auth backend"
  echo ""
  echo "This script manages Nginx reverse proxy setup with intelligent backend detection:"
  echo "  - Auto-detects SSSD or Samba/Kerberos installations"
  echo "  - Parses existing configurations for auto-fill"
  echo "  Interactive menu allows: Install/Configure, Uninstall, Restore from backup, Exit"
  exit 1
}

validate_auth_backend() {
  local backend="$1"
  case "${backend^^}" in
    SSSD|SAMBA) return 0;;
    *) return 1;;
  esac
}

# =====================================================================
# IPv6 BINDING ISSUE FIX
# =====================================================================

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
# AUTH BACKEND SETUP
# =====================================================================

setup_auth_backend_sssd() {
  log INFO "Setting up SSSD + Kerberos authentication backend..."
  
  local packages_sssd="sssd-ad sssd-tools krb5-user libpam-sss libpam-krb5 libnss-sss"
  log INFO "Installing SSSD packages: $packages_sssd"
  run_command "Install SSSD packages" "apt-get -y install $packages_sssd"
  
  configure_nsswitch_sssd
  create_pam_service_nginx_sssd
  
  log INFO "Setting www-data permissions for SSSD..."
  run_command "Add www-data to sasl group" "usermod -a -G sasl www-data"
  
  log INFO "SSSD + Kerberos setup complete."
  return 0
}

setup_auth_backend_samba() {
  log INFO "Setting up Samba + Kerberos authentication backend..."
  
  local packages_samba="samba winbind krb5-user krb5-clients libpam-winbind libnss-winbind"
  log INFO "Installing Samba/Winbind packages: $packages_samba"
  run_command "Install Samba packages" "apt-get -y install $packages_samba"
  
  configure_nsswitch_samba
  create_pam_service_nginx_samba
  
  log INFO "Setting www-data permissions for Samba..."
  run_command "Add www-data to sambashare group" "usermod -a -G sambashare www-data"
  
  log INFO "Samba + Kerberos setup complete."
  return 0
}

configure_nsswitch_sssd() {
  local nss_conf="/etc/nsswitch.conf"
  
  if [[ ! -f "$nss_conf" ]]; then
    log ERROR "nsswitch.conf not found"
    return 1
  fi
  
  run_command "Backup nsswitch.conf" "cp '$nss_conf' '${nss_conf}.bak.$(date +%s)'"
  
  sed -i.bak -E \
    -e 's/^passwd:[[:space:]].*/passwd:         files systemd sssd/' \
    -e 's/^shadow:[[:space:]].*/shadow:         files sssd/' \
    -e 's/^group:[[:space:]].*/group:          files systemd sssd/' \
    "$nss_conf"
  
  log INFO "nsswitch.conf configured for SSSD"
  return 0
}

configure_nsswitch_samba() {
  local nss_conf="/etc/nsswitch.conf"
  
  if [[ ! -f "$nss_conf" ]]; then
    log ERROR "nsswitch.conf not found"
    return 1
  fi
  
  run_command "Backup nsswitch.conf" "cp '$nss_conf' '${nss_conf}.bak.$(date +%s)'"
  
  sed -i.bak -E \
    -e 's/^passwd:[[:space:]].*/passwd:         files winbind/' \
    -e 's/^group:[[:space:]].*/group:          files winbind/' \
    "$nss_conf"
  
  log INFO "nsswitch.conf configured for Winbind"
  return 0
}

create_pam_service_nginx_sssd() {
  local pam_file="/etc/pam.d/nginx"
  
  log INFO "Creating PAM service file: $pam_file (SSSD)"
  
  cat > "$pam_file" << 'SSSD_PAM_EOF'
# PAM service file for Nginx (SSSD + Kerberos)
auth    sufficient      pam_sss.so
auth    required        pam_unix.so try_first_pass nullok
account sufficient      pam_sss.so
account required        pam_unix.so
session optional        pam_sss.so
session required        pam_unix.so
SSSD_PAM_EOF

  run_command "Set PAM file permissions (nginx-sssd)" "chmod 644 '$pam_file'"
  log INFO "PAM service file created for SSSD"
  return 0
}

create_pam_service_nginx_samba() {
  local pam_file="/etc/pam.d/nginx"
  
  log INFO "Creating PAM service file: $pam_file (Samba/Winbind)"
  
  cat > "$pam_file" << 'SAMBA_PAM_EOF'
# PAM service file for Nginx (Samba + Kerberos)
auth    sufficient      pam_winbind.so use_first_pass try_first_pass
auth    required        pam_unix.so try_first_pass nullok
account sufficient      pam_winbind.so
account required        pam_unix.so
password        optional        pam_winbind.so
session required        pam_unix.so
session optional        pam_winbind.so
SAMBA_PAM_EOF

  run_command "Set PAM file permissions (nginx-samba)" "chmod 644 '$pam_file'"
  log INFO "PAM service file created for Samba/Winbind"
  return 0
}

# =====================================================================
# MAIN SETUP AND INSTALLATION LOGIC
# =====================================================================

install_and_configure_nginx() {
  log INFO "--- Interactive Nginx Setup (Intelligent Detection) ---"
  echo "Please confirm or edit the settings. Press Enter to accept default values."
  
  # Load configuration
  if [[ ! -f "$config_file" ]]; then
    log ERROR "Config file not found: $config_file"
    return 1
  fi
  source "$config_file"
  
  # Use the flag set by menu choice
  if [[ "${enable_autodetect:-false}" == "true" ]]; then
    log INFO "Auto-detect enabled by user menu choice."
    log INFO "Auto-detecting authentication backend..."
    
    local selected_auth_backend
    selected_auth_backend=$(intelligent_backend_detection)
    
    if [[ "$selected_auth_backend" != "NONE" ]]; then
      log INFO "Auto-detected backend: $selected_auth_backend"
      echo ""
      echo "Using auto-detected backend: $selected_auth_backend"
      echo ""
      read -r -p "Press Enter to accept, or type SSSD/SAMBA to override: " override_backend
      
      if [[ -n "$override_backend" ]]; then
        selected_auth_backend="$override_backend"
        log INFO "User overrode to: $selected_auth_backend"
      else
        log INFO "User accepted auto-detected backend: $selected_auth_backend"
        # Auto-fill from detected backend
        autofill_from_detected_backend "$selected_auth_backend"
      fi
    else
      log INFO "No existing backend detected, prompting user..."
      prompt_for_value "Authentication Backend (SSSD/SAMBA)" "selected_auth_backend"
    fi
    
    AUTH_BACKEND="$selected_auth_backend"
  else
    log INFO "Auto-detect disabled; proceeding with manual configuration."
    prompt_for_value "Authentication Backend (SSSD/SAMBA)" "AUTH_BACKEND"
  fi
  
  if ! validate_auth_backend "$AUTH_BACKEND"; then
    log ERROR "Invalid AUTH_BACKEND: '$AUTH_BACKEND'. Must be SSSD or SAMBA."
    return 1
  fi
  
  # Continue with configuration prompts...
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
  
  prompt_for_value "Active Directory Domain (lowercase)" "AD_DOMAIN_LOWER"
  prompt_for_value "Active Directory Domain (UPPERCASE)" "AD_DOMAIN_UPPER"
  
  if [[ "${AUTH_BACKEND^^}" == "SAMBA" ]]; then
    prompt_for_value "Samba Workgroup" "SAMBA_WORKGROUP"
    prompt_for_value "Allowed AD Groups (comma-separated, optional)" "SAMBA_ALLOWED_GROUPS"
  elif [[ "${AUTH_BACKEND^^}" == "SSSD" ]]; then
    prompt_for_value "Allowed AD Groups (comma-separated, optional)" "SSSD_ALLOWED_GROUPS"
  fi
  
  echo "-------------------------------------"
  log INFO "Configuration confirmed. AUTH_BACKEND=$AUTH_BACKEND"
  log INFO "Proceeding with setup..."
  
  # Installation continues (rest of code same as before)
  log INFO "Starting installation of required packages..."
  local packages_common="nginx-full"
  
  if [[ "$CERT_MODE" == "LETS_ENCRYPT" ]]; then
    packages_common+=" certbot python3-certbot-nginx"
  fi
  
  run_command "Update package lists" "apt-get -y update"
  log INFO "Purging any existing Nginx packages..."
  run_command "Purge nginx packages" "apt-get remove --purge -y nginx nginx-common nginx-core nginx-full" || log WARN "Nginx packages not found or already removed."
  run_command "Autoremove unused packages" "apt-get autoremove -y" || true
  
  log INFO "Installing Nginx and dependencies..."
  if ! run_command "Install packages" "apt-get -y install $packages_common"; then
    if ! _fix_ipv6_and_finish_install; then
      log ERROR "Failed to install or repair packages."
      return 1
    fi
  fi
  
  log INFO "SUCCESS: Nginx packages installed."
  
  # Setup authentication backend
  log INFO "Configuring authentication backend: $AUTH_BACKEND"
  if [[ "${AUTH_BACKEND^^}" == "SSSD" ]]; then
    setup_auth_backend_sssd || return 1
  elif [[ "${AUTH_BACKEND^^}" == "SAMBA" ]]; then
    setup_auth_backend_samba || return 1
  fi
  
  # Create required directories
  ensure_dir_exists "$NGINX_TEMPLATE_DIR"
  ensure_dir_exists "$SSL_CERT_DIR"
  ensure_dir_exists "/var/www/html"
  
  log INFO "Nginx setup process continuing... (additional steps would follow)"
  log INFO "Setup complete!"
}

# =====================================================================
# UNINSTALL FUNCTION
# =====================================================================

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
  
  log INFO "Cleaning Nginx configurations..."
  run_command "Remove nginx directory" "rm -rf /etc/nginx" || true
  run_command "Remove PAM nginx service file" "rm -f /etc/pam.d/nginx" || true
  
  log INFO "Uninstall attempt complete."
}

# =====================================================================
# INTERACTIVE MENU SYSTEM
# =====================================================================

show_menu() {
  echo ""
  printf "\n=== Nginx Setup Menu (Intelligent Detection) ===\n"
  printf "1) Install/Configure Nginx (Manual Configuration)\n"
  printf "2) Install/Configure Nginx (Enable Auto Detection)\n"
  printf "U) Uninstall Nginx and restore system\n"
  printf "R) Restore configurations from most recent backup\n"
  printf "4) Exit\n"
  read -r -p "Choice: " choice
  
  case "$choice" in
    1)
      backup_config
      enable_autodetect="false"
      install_and_configure_nginx
      ;;
    2)
      backup_config
      enable_autodetect="true"
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
  check_root
  
  local config_file="$DEFAULT_CONFIG_FILE"
  local enable_autodetect="false"
  
  while getopts "c:dh" opt; do
    case "$opt" in
      c) config_file="$OPTARG";;
      d) enable_autodetect="true";;
      h) usage;;
      *) usage;;
    esac
  done
  
  if [[ ! -f "$config_file" ]]; then
    log ERROR "Config file not found: $config_file"
    log ERROR "Expected location: $DEFAULT_CONFIG_FILE"
    exit 3
  fi
  
  setup_backup_dir
  
  # If auto-detection enabled via -d flag
  if [[ "$enable_autodetect" == "true" ]]; then
    log INFO "Intelligent backend detection enabled (-d flag)"
  fi
  
  show_menu
}

main "$@"
