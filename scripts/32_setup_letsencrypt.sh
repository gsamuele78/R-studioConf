#!/bin/bash
# =====================================================================
# Let's Encrypt Certificate Setup Script (v1.0)
# =====================================================================
# Comprehensive Let's Encrypt certificate management:
# - Production and staging (test) modes
# - Auto-detection of domain from AD join
# - Auto-renewal crontab setup
# - Certificate status and renewal management
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
CONFIG_FILE="${SCRIPT_DIR}/../config/install_nginx.vars.conf"

# Source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
  echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
  exit 2
fi
source "$UTILS_SCRIPT_PATH"

# =====================================================================
# DOMAIN DETECTION FUNCTIONS
# =====================================================================

# Auto-detect domain from AD join or system configuration
detect_domain_for_letsencrypt() {
  local detected_domain=""
  
  # Priority 1: realm list (works for both SSSD and Samba)
  if command -v realm &>/dev/null; then
    detected_domain=$(realm list --name-only 2>/dev/null | head -1)
    if [[ -n "$detected_domain" ]]; then
      log INFO "Domain detected from realm: $detected_domain"
      echo "$detected_domain"
      return 0
    fi
  fi
  
  # Priority 2: SSSD config
  if [[ -f /etc/sssd/sssd.conf ]]; then
    detected_domain=$(grep -i "^\[domain/" /etc/sssd/sssd.conf 2>/dev/null | head -1 | sed 's/.*domain\/\([^]]*\).*/\1/')
    if [[ -n "$detected_domain" ]]; then
      log INFO "Domain detected from sssd.conf: $detected_domain"
      echo "$detected_domain"
      return 0
    fi
  fi
  
  # Priority 3: Samba config (realm)
  if [[ -f /etc/samba/smb.conf ]]; then
    detected_domain=$(grep -i "^[[:space:]]*realm" /etc/samba/smb.conf 2>/dev/null | head -1 | cut -d= -f2 | xargs | tr '[:upper:]' '[:lower:]')
    if [[ -n "$detected_domain" ]]; then
      log INFO "Domain detected from smb.conf: $detected_domain"
      echo "$detected_domain"
      return 0
    fi
  fi
  
  # Priority 4: hostname -f (FQDN)
  detected_domain=$(hostname -f 2>/dev/null)
  if [[ -n "$detected_domain" && "$detected_domain" == *.* ]]; then
    log INFO "Domain detected from hostname: $detected_domain"
    echo "$detected_domain"
    return 0
  fi
  
  # Fallback: return empty
  log WARN "Could not auto-detect domain"
  echo ""
  return 1
}

# =====================================================================
# CERTBOT INSTALLATION
# =====================================================================

install_certbot() {
  log INFO "Installing Certbot and Nginx plugin..."
  
  run_command "Update package lists" "apt-get update -y"
  run_command "Install certbot" "apt-get install -y certbot python3-certbot-nginx"
  
  log INFO "Certbot installed successfully."
  certbot --version
}

# =====================================================================
# CERTIFICATE MANAGEMENT
# =====================================================================

obtain_certificate() {
  local mode="${1:-PRODUCTION}"
  
  # Source config
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  fi
  
  # Get or prompt for domain
  local domain="${DOMAIN_OR_IP:-}"
  if [[ -z "$domain" || "$domain" == "your_domain_or_ip" ]]; then
    local detected
    detected=$(detect_domain_for_letsencrypt) || detected=""
    if [[ -n "$detected" ]]; then
      echo "Detected domain: $detected"
      read -r -p "Use this domain? (Enter to accept, or type different): " user_domain
      domain="${user_domain:-$detected}"
    else
      read -r -p "Enter domain for certificate: " domain
    fi
  fi
  
  if [[ -z "$domain" ]]; then
    log ERROR "Domain is required"
    return 1
  fi
  
  # Get email
  local email="${LE_EMAIL:-}"
  if [[ -z "$email" || "$email" == "your-email@example.com" ]]; then
    read -r -p "Enter email for Let's Encrypt notifications: " email
  fi
  
  if [[ -z "$email" ]]; then
    log ERROR "Email is required"
    return 1
  fi
  
  # Build certbot command
  local certbot_cmd="certbot certonly --nginx"
  certbot_cmd+=" -d \"$domain\""
  certbot_cmd+=" --non-interactive --agree-tos"
  certbot_cmd+=" -m \"$email\""
  
  # Add additional domains if specified
  if [[ -n "${LE_ADDITIONAL_DOMAINS:-}" ]]; then
    IFS=',' read -ra extra_domains <<< "$LE_ADDITIONAL_DOMAINS"
    for extra in "${extra_domains[@]}"; do
      extra=$(echo "$extra" | xargs)  # trim whitespace
      [[ -n "$extra" ]] && certbot_cmd+=" -d \"$extra\""
    done
  fi
  
  # Staging mode for testing
  if [[ "${mode^^}" == "STAGING" ]]; then
    certbot_cmd+=" --staging"
    log WARN "STAGING MODE: Certificate will NOT be trusted by browsers (for testing)"
  else
    log INFO "PRODUCTION MODE: Obtaining trusted certificate"
  fi
  
  log INFO "Obtaining certificate for: $domain"
  log INFO "Command: $certbot_cmd"
  
  eval "$certbot_cmd"
  
  if [[ $? -eq 0 ]]; then
    log INFO "Certificate obtained successfully!"
    echo ""
    echo "Certificate location: /etc/letsencrypt/live/$domain/"
    echo "  - fullchain.pem (certificate + chain)"
    echo "  - privkey.pem (private key)"
  else
    log ERROR "Failed to obtain certificate"
    return 1
  fi
}

# =====================================================================
# AUTO-RENEWAL SETUP
# =====================================================================

setup_auto_renewal() {
  log INFO "Setting up automatic certificate renewal..."
  
  local cron_file="/etc/cron.d/certbot-renew"
  
  # Create cron job
  cat > "$cron_file" << 'CRON_EOF'
# Certbot automatic certificate renewal
# Runs daily at 3:00 AM, renews if cert expires within 30 days
0 3 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"
CRON_EOF

  chmod 644 "$cron_file"
  
  log INFO "Auto-renewal cron job created: $cron_file"
  echo ""
  echo "Renewal schedule: Daily at 3:00 AM"
  echo "Post-renewal: Nginx will be reloaded automatically"
  
  # Test renewal (dry run)
  log INFO "Testing renewal process (dry run)..."
  certbot renew --dry-run
}

# =====================================================================
# CERTIFICATE STATUS
# =====================================================================

show_certificate_status() {
  log INFO "Checking certificate status..."
  certbot certificates
}

renew_certificate() {
  log INFO "Attempting certificate renewal..."
  certbot renew --post-hook "systemctl reload nginx"
}

revoke_certificate() {
  local domain
  read -r -p "Enter domain to revoke certificate for: " domain
  
  if [[ -z "$domain" ]]; then
    log ERROR "Domain is required"
    return 1
  fi
  
  local cert_path="/etc/letsencrypt/live/$domain/cert.pem"
  if [[ ! -f "$cert_path" ]]; then
    log ERROR "Certificate not found: $cert_path"
    return 1
  fi
  
  log WARN "This will revoke the certificate for: $domain"
  read -r -p "Are you sure? (yes/no): " confirm
  
  if [[ "$confirm" == "yes" ]]; then
    certbot revoke --cert-path "$cert_path"
    log INFO "Certificate revoked"
  else
    log INFO "Revocation cancelled"
  fi
}

# =====================================================================
# MENU
# =====================================================================

show_menu() {
  while true; do
    echo ""
    echo "=========================================="
    echo " Let's Encrypt Certificate Management"
    echo "=========================================="
    echo "1) Install Certbot"
    echo "2) Obtain Certificate (Production)"
    echo "3) Obtain Certificate (Staging/Test)"
    echo "4) Setup Auto-Renewal Crontab"
    echo "5) Check Certificate Status"
    echo "6) Renew Certificate Now"
    echo "7) Revoke Certificate"
    echo "Q) Quit"
    echo "=========================================="
    read -r -p "Choice: " choice
    
    case "$choice" in
      1) install_certbot ;;
      2) obtain_certificate "PRODUCTION" ;;
      3) obtain_certificate "STAGING" ;;
      4) setup_auto_renewal ;;
      5) show_certificate_status ;;
      6) renew_certificate ;;
      7) revoke_certificate ;;
      Q|q) log INFO "Exiting."; break ;;
      *) echo "Invalid choice" ;;
    esac
    
    echo ""
    read -r -p "Press Enter to continue..."
  done
}

# =====================================================================
# MAIN
# =====================================================================

main() {
  check_root
  log INFO "=== Let's Encrypt Certificate Manager ==="
  show_menu
}

main "$@"
