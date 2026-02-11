#!/bin/bash
# scripts/12_lib_kerberos_setup.sh
# Centralized Kerberos Setup Script
#
# This script handles:
# 1. Installation of Kerberos client packages
# 2. Dynamic generation of /etc/krb5.conf based on configuration variables

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"

TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# Source common utils
if [[ -f "$UTILS_SCRIPT_PATH" ]]; then
    source "$UTILS_SCRIPT_PATH"
else
    echo "Error: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
    exit 1
fi

# Docker Deploy: Source .env instead of legacy config
if [ -f "${SCRIPT_DIR}/../.env" ]; then
    log "INFO" "Sourcing configuration from .env..."
    set -a
    source "${SCRIPT_DIR}/../.env"
    set +a
else
    log "WARN" ".env file not found at ${SCRIPT_DIR}/../.env"
fi

# Compatibility Mappings (Ensure variables expected by other scripts are set)
AD_DOMAIN_LOWER="${AD_DOMAIN_LOWER:-$DEFAULT_AD_DOMAIN_LOWER}"
AD_DOMAIN_UPPER="${AD_DOMAIN_UPPER:-$DEFAULT_AD_DOMAIN_UPPER}"

# Handle DEFAULT_DOMAIN_REALM_MAPPINGS (string in .env, array in script)
# Legacy config defined it as an array. Docker .env defines it as space-separated string.
if [[ -n "$DEFAULT_DOMAIN_REALM_MAPPINGS" ]]; then
    # Check if it looks like an array definition (starting with '(') - handle legacy sourcing if mixed
    if [[ "$DEFAULT_DOMAIN_REALM_MAPPINGS" == \(* ]]; then
        # It's explicitly an array string (unlikely in .env but possible if sourced legacy)
        eval "DEFAULT_DOMAIN_REALM_MAPPINGS_ARRAY=$DEFAULT_DOMAIN_REALM_MAPPINGS"
    else
        # It's a space-separated string
        IFS=' ' read -r -a DEFAULT_DOMAIN_REALM_MAPPINGS_ARRAY <<< "$DEFAULT_DOMAIN_REALM_MAPPINGS"
    fi
else
    # Default fallback if missing from .env
    DEFAULT_DOMAIN_REALM_MAPPINGS_ARRAY=(
        ".dir.unibo.it=DIR.UNIBO.IT"
        "dir.unibo.it=DIR.UNIBO.IT"
        ".personale.dir.unibo.it=PERSONALE.DIR.UNIBO.IT"
        "personale.dir.unibo.it=PERSONALE.DIR.UNIBO.IT"
        ".studenti.dir.unibo.it=STUDENTI.DIR.UNIBO.IT"
        "studenti.dir.unibo.it=STUDENTI.DIR.UNIBO.IT"
    )
fi

install_kerberos_packages() {
    log "Installing Kerberos client packages..."
    # 'auth-client-config' is obsolete/missing on newer Ubuntu releases (noble+).
    # Exclude it to avoid apt errors; keep essential Kerberos client packages.
    local -a pkgs=(krb5-user libpam-krb5 libpam-ccreds)
    
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
    for mapping in "${DEFAULT_DOMAIN_REALM_MAPPINGS_ARRAY[@]}"; do
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
