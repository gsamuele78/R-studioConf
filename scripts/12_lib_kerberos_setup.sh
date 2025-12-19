#!/bin/bash
# scripts/11_kerberos_setup.sh
# Centralized Kerberos Setup Script
#
# This script handles:
# 1. Installation of Kerberos client packages
# 2. Dynamic generation of /etc/krb5.conf based on configuration variables

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
KERBEROS_VARS_FILE="${SCRIPT_DIR}/../config/lib_kerberos_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# Source common utils
if [[ -f "$UTILS_SCRIPT_PATH" ]]; then
    source "$UTILS_SCRIPT_PATH"
else
    echo "Error: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
    exit 1
fi

# Source common Kerberos variables
if [[ -f "$KERBEROS_VARS_FILE" ]]; then
    source "$KERBEROS_VARS_FILE"
else
    log "WARN" "Kerberos configuration file not found at $KERBEROS_VARS_FILE. Using internal defaults if available, or failing."
fi

install_kerberos_packages() {
    log "Installing Kerberos client packages..."
    local -a pkgs=(krb5-user libpam-krb5 libpam-ccreds auth-client-config)
    
    # Check if packages are already installed to avoid unnecessary apt calls
    local missing_pkgs=()
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        run_command "Update apt cache" "apt-get update"
        run_command "Install Kerberos packages" "apt-get install -y ${missing_pkgs[*]}"
    else
        log "Kerberos packages already installed."
    fi
}

generate_krb5_conf() {
    log "Generating /etc/krb5.conf from template..."
    
    local template_path="${TEMPLATE_DIR}/krb5.conf.template"
    local dest_path="/etc/krb5.conf"

    if [[ ! -f "$template_path" ]]; then
        log "ERROR" "Template not found: $template_path"
        return 1
    fi

    # 1. Build REALMS Block
    # We explicitly construct it from the known variables in kerberos_setup.vars.conf
    # This ensures it matches the manual 'step-by-step' requirements exactly.
    local realms_block=""
    
    # DIR.UNIBO.IT
    realms_block+="    ${DEFAULT_DIR_UNIBO_REALM} = {\n"
    realms_block+="        kdc = ${DEFAULT_DIR_UNIBO_KDC}\n"
    realms_block+="        admin_server = ${DEFAULT_DIR_UNIBO_ADMIN_SERVER}\n"
    realms_block+="    }\n"

    # PERSONALE.DIR.UNIBO.IT
    realms_block+="    ${DEFAULT_PERSONALE_UNIBO_REALM} = {\n"
    realms_block+="        kdc = ${DEFAULT_PERSONALE_UNIBO_KDC}\n"
    realms_block+="        admin_server = ${DEFAULT_PERSONALE_UNIBO_ADMIN_SERVER}\n"
    realms_block+="    }\n"

    # STUDENTI.DIR.UNIBO.IT
    realms_block+="    ${DEFAULT_STUDENTI_UNIBO_REALM} = {\n"
    realms_block+="        kdc = ${DEFAULT_STUDENTI_UNIBO_KDC}\n"
    realms_block+="        admin_server = ${DEFAULT_STUDENTI_UNIBO_ADMIN_SERVER}\n"
    realms_block+="    }\n"

    # 2. Build DOMAIN_REALM Block
    local domain_realm_block=""
    for mapping in "${DEFAULT_DOMAIN_REALM_MAPPINGS[@]}"; do
        # Mapping format: domain=REALM
        local d="${mapping%%=*}"
        local r="${mapping##*=}"
        domain_realm_block+="    ${d} = ${r}\n"
    done

    # 3. Determine Default Realm (usually derived from the upper-case domain being joined, 
    # but strictly speaking, the user might want to parameterize this. 
    # For now, we use a variable passed in OR perform a best guess/dependency check.)
    # The calling script typically sets AD_DOMAIN_UPPER.
    local default_realm="${AD_DOMAIN_UPPER:-${DEFAULT_PERSONALE_UNIBO_REALM}}"

    # 4. Generate Content
    local krb5_content=""
    process_template "$template_path" "krb5_content" \
        KRB5_DEFAULT_REALM="$default_realm" \
        KRB5_REALMS_BLOCK="$realms_block" \
        KRB5_DOMAIN_REALM_BLOCK="$domain_realm_block"

    if [[ -z "$krb5_content" ]]; then
        log "ERROR" "Failed to generate krb5.conf content."
        return 1
    fi

    # 5. Backup and Write
    if [[ -f "$dest_path" ]]; then
        _backup_item "$dest_path" "$CURRENT_BACKUP_DIR/etc" || log "WARN" "Failed to backup $dest_path"
    fi

    printf "%b" "$krb5_content" > "$dest_path"
    run_command "chmod 644 $dest_path" || true
    
    log "INFO" "Generated $dest_path successfully."
    log "DEBUG" "Preview of krb5.conf:\n$(head -n 20 $dest_path)"
}

configure_kerberos() {
    # Main entry point function
    setup_backup_dir
    install_kerberos_packages
    generate_krb5_conf
}

# If executed directly, run the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # We need to ensure backup dir is setup if running standalone
    setup_backup_dir
    configure_kerberos
fi
