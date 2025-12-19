#!/bin/bash
# samba_kerberos_setup.sh - Samba + Kerberos join and configuration helper
# Uses common utilities (`process_template`, `run_command`, logging helpers)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
CONF_VARS_FILE="${SCRIPT_DIR}/../config/join_domain_samba.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
SMB_CONF_PATH_DEFAULT="/etc/samba/smb.conf"

KERBEROS_SETUP_SCRIPT="${SCRIPT_DIR}/12_lib_kerberos_setup.sh"

if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    printf "Error: common_utils.sh not found at %s\n" "$UTILS_SCRIPT_PATH" >&2
    exit 1
fi
source "$UTILS_SCRIPT_PATH"

# Source shared Kerberos setup script functions
if [[ -f "$KERBEROS_SETUP_SCRIPT" ]]; then
    source "$KERBEROS_SETUP_SCRIPT"
else
    log "ERROR: Kerberos setup script not found at $KERBEROS_SETUP_SCRIPT"
    exit 1
fi

# === SET EMBEDDED DEFAULTS FIRST ===
# These defaults are always set; config file can override them
AD_DOMAIN_LOWER="${AD_DOMAIN_LOWER:-personale.dir.unibo.it}"
AD_DOMAIN_UPPER="${AD_DOMAIN_UPPER:-PERSONALE.DIR.UNIBO.IT}"
COMPUTER_OU_BASE="${COMPUTER_OU_BASE:-OU=Servizi_Informatici,OU=Dip-BIGEA,OU=Dsa.Auto}"
COMPUTER_OU_CUSTOM_PART="${COMPUTER_OU_CUSTOM_PART:-OU=ServerFarm_Navile}"
OS_NAME="${OS_NAME:-Linux}"
SMB_CONF_PATH="${SMB_CONF_PATH:-$SMB_CONF_PATH_DEFAULT}"
IDMAP_PERSONALE_RANGE_LOW="${IDMAP_PERSONALE_RANGE_LOW:-163600000}"
IDMAP_PERSONALE_RANGE_HIGH="${IDMAP_PERSONALE_RANGE_HIGH:-263600000}"
IDMAP_STAR_RANGE_LOW="${IDMAP_STAR_RANGE_LOW:-10000}"
IDMAP_STAR_RANGE_HIGH="${IDMAP_STAR_RANGE_HIGH:-999999}"
TEMPLATE_HOMEDIR="${TEMPLATE_HOMEDIR:-/nfs/home/%U}"
REALM="${REALM:-PERSONALE.DIR.UNIBO.IT}"
WORKGROUP="${WORKGROUP:-PERSONALE}"
SIMPLE_ALLOW_GROUPS="${SIMPLE_ALLOW_GROUPS:-}"
DEFAULT_OS_NAME="${DEFAULT_OS_NAME:-Linux}"
DEFAULT_MEMBERSHIP_SOFTWARE="${DEFAULT_MEMBERSHIP_SOFTWARE:-samba}"
DEFAULT_CLIENT_SOFTWARE="${DEFAULT_CLIENT_SOFTWARE:-winbind}"
DEFAULT_AD_ADMIN_USER_EXAMPLE="${DEFAULT_AD_ADMIN_USER_EXAMPLE:-gianfranco.samuele2@PERSONALE.DIR.UNIBO.IT}"
DEFAULT_SAMBA_LOG_LEVEL="${DEFAULT_SAMBA_LOG_LEVEL:-1}"
DEFAULT_SAMBA_MAX_LOG_SIZE="${DEFAULT_SAMBA_MAX_LOG_SIZE:-50}"
DEFAULT_SAMBA_SMB_CONF_PATH="${DEFAULT_SAMBA_SMB_CONF_PATH:-/etc/samba/smb.conf}"
# If true, prefer Samba/winbind for membership (pre-install samba & winbind)
USE_WINBIND="${USE_WINBIND:-false}"

# === SOURCE CONFIG FILE (overlays defaults) ===
if [[ -f "$CONF_VARS_FILE" ]]; then
    log "Sourcing Samba Kerberos configuration variables from $CONF_VARS_FILE"
    # shellcheck source=../config/samba_kerberos_setup.vars.conf
    source "$CONF_VARS_FILE"
else
    log "Warning: Samba Kerberos vars file not found; using embedded defaults."
fi

# Map DEFAULT_ config variables (from config file) into runtime IDMAP_ variables
# This allows config files to set DEFAULT_IDMAP_* while the script uses IDMAP_* names
if [[ -n "${DEFAULT_IDMAP_PERSONALE_RANGE_LOW:-}" ]]; then
    IDMAP_PERSONALE_RANGE_LOW="${IDMAP_PERSONALE_RANGE_LOW:-${DEFAULT_IDMAP_PERSONALE_RANGE_LOW}}"
fi
if [[ -n "${DEFAULT_IDMAP_PERSONALE_RANGE_HIGH:-}" ]]; then
    IDMAP_PERSONALE_RANGE_HIGH="${IDMAP_PERSONALE_RANGE_HIGH:-${DEFAULT_IDMAP_PERSONALE_RANGE_HIGH}}"
fi
if [[ -n "${DEFAULT_IDMAP_STAR_RANGE_LOW:-}" ]]; then
    IDMAP_STAR_RANGE_LOW="${IDMAP_STAR_RANGE_LOW:-${DEFAULT_IDMAP_STAR_RANGE_LOW}}"
fi
if [[ -n "${DEFAULT_IDMAP_STAR_RANGE_HIGH:-}" ]]; then
    IDMAP_STAR_RANGE_HIGH="${IDMAP_STAR_RANGE_HIGH:-${DEFAULT_IDMAP_STAR_RANGE_HIGH}}"
fi
if [[ -n "${DEFAULT_IDMAP_BACKEND_DOMAIN:-}" ]]; then
    DEFAULT_IDMAP_BACKEND_DOMAIN="${DEFAULT_IDMAP_BACKEND_DOMAIN}"
fi

# === VERIFY ALL CRITICAL VARIABLES ARE SET ===
# If config file didn't set them or they're empty, use defaults (second pass)
COMPUTER_OU_BASE="${COMPUTER_OU_BASE:-OU=Servizi_Informatici,OU=Dip-BIGEA,OU=Dsa.Auto}"
COMPUTER_OU_CUSTOM_PART="${COMPUTER_OU_CUSTOM_PART:-OU=ServerFarm_Navile}"
AD_DOMAIN_LOWER="${AD_DOMAIN_LOWER:-personale.dir.unibo.it}"
AD_DOMAIN_UPPER="${AD_DOMAIN_UPPER:-PERSONALE.DIR.UNIBO.IT}"
REALM="${REALM:-PERSONALE.DIR.UNIBO.IT}"
WORKGROUP="${WORKGROUP:-PERSONALE}"

log "DEBUG" "Loaded configuration: AD_DOMAIN_LOWER=$AD_DOMAIN_LOWER, COMPUTER_OU_BASE=$COMPUTER_OU_BASE, COMPUTER_OU_CUSTOM_PART=$COMPUTER_OU_CUSTOM_PART"



install_prereqs() {
    log "Ensuring required packages are installed"
    local pkgs=()
    # If configured to prefer winbind, install samba/winbind stacks; otherwise install SSSD stack
    if [[ "${USE_WINBIND,,}" == "true" ]]; then
        log "DEBUG" "USE_WINBIND=true: preferring Samba/winbind packages"
        pkgs=(samba samba-common-bin winbind libnss-winbind libpam-winbind adcli krb5-user realmd ldb-tools)
    else
        log "DEBUG" "USE_WINBIND=false: preferring SSSD/adcli packages"
        pkgs=(realmd sssd-ad adcli samba-common-bin libnss-sss libpam-sss)
    fi

    # Install common Kerberos packages via shared script
    install_kerberos_packages

    # Update package cache once at the start
    if ! run_command "Update package cache" "apt-get update"; then
        log "Warning: apt-get update failed, but continuing with install attempts"
    fi

    # Purge conflicting SSSD packages to prevent conflicts. Detect installed packages first
    log "INFO" "Purging SSSD packages to prevent conflicts..."
    local sssd_pkgs
    # Look for installed packages with 'sss' in the package name (sssd, libnss-sss, libpam-sss, etc.)
    sssd_pkgs=($(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /sss/ {print $2}')) || sssd_pkgs=()
    if [[ ${#sssd_pkgs[@]} -gt 0 ]]; then
        log "DEBUG" "Detected SSSD-related packages to purge: ${sssd_pkgs[*]}"
        if ! run_command "apt-get purge -y ${sssd_pkgs[*]}"; then
            log "WARN" "Failed to purge SSSD packages ${sssd_pkgs[*]}. Continuing.";
        fi
    else
        log "DEBUG" "No SSSD-related packages found; skipping purge"
    fi

    # Install all required packages in a single apt-get call to avoid partial/ordering issues
    local to_install=()
    for p in "${pkgs[@]}"; do
        if ! dpkg -s "$p" &>/dev/null; then
            to_install+=("$p")
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        log "INFO" "Installing packages: ${to_install[*]}"
        if ! run_command "Install packages" "apt-get install -y ${to_install[*]}"; then
            log "ERROR" "Failed to install required packages: ${to_install[*]}"
            return 1
        fi
    else
        log "DEBUG" "All required packages already installed: ${pkgs[*]}"
    fi

    # If using winbind, ensure services exist and are enabled so systemctl can manage them
    if [[ "${USE_WINBIND,,}" == "true" ]]; then
        # Reload systemd to pick up new units
        run_command "systemctl daemon-reload" || true
        run_command "systemctl enable --now winbind" || true
        # smbd and nmbd may be managed by samba.service on some distros; try enabling common units
        run_command "systemctl enable --now smbd nmbd" || true
    fi

    return 0
}

prejoin_checks() {
    log "INFO" "Running pre-join checks: time sync and DNS discovery"

    # Ensure time sync using the unified NTP/chrony setup script if present
    local ntp_script_path="${SCRIPT_DIR}/08_ntp_chrony_setup.sh"
    if [[ -x "$ntp_script_path" ]]; then
        log "DEBUG" "Invoking NTP/chrony setup script: $ntp_script_path"
        "$ntp_script_path"
    else
        log "DEBUG" "NTP/chrony setup script not found or not executable: $ntp_script_path"
    fi

    # If chrony is installed, wait briefly for it to reach sync; otherwise try to force a step
    if command -v chronyc &>/dev/null; then
        log "DEBUG" "chronyc found: waiting up to 15s for chrony to synchronize"
        if chronyc waitsync 15 2>/dev/null; then
            log "DEBUG" "chrony reports synchronized"
        else
            log "WARN" "chrony did not synchronize within timeout; attempting immediate step (makestep)"
            if chronyc -a makestep 2>/dev/null; then
                log "DEBUG" "chrony makestep applied"
            else
                log "WARN" "chrony makestep failed or is not permitted"
            fi
            # short pause to let system adjust
            sleep 2
        fi
    else
        log "DEBUG" "chronyc not available; skipping chrony wait/makestep"
    fi

    # Verify timedatectl reports synchronized clock
    local sync_status
    sync_status=$(timedatectl status 2>/dev/null | grep -i "System clock synchronized:" | awk '{print $NF}') || sync_status="no"
    if [[ "$sync_status" != "yes" ]]; then
        log "WARN" "System time may not be synchronized. timedatectl status:"
        timedatectl status | tee -a "$LOG_FILE"
        local cont
        read -r -p "Continue despite potential time sync issues? (y/n): " cont
        if [[ "$cont" != "y" && "$cont" != "Y" ]]; then
            log "ERROR" "Aborting due to time synchronization concerns."
            return 1
        fi
    else
        log "DEBUG" "System clock synchronized: yes"
    fi

    # Check that the domain is discoverable via realmd (DNS/SRV checks)
    if ! run_command "realm discover \"${AD_DOMAIN_LOWER}\""; then
        log "WARN" "Domain ${AD_DOMAIN_LOWER} not discoverable via DNS/SRV (realm discover failed)."

        # Provide diagnostics for time sync (chrony) to help debugging
        if command -v chronyc &>/dev/null; then
            log "INFO" "Collecting chrony status (chronyc sources -v) for debugging..."
            run_command "chronyc sources -v" || true
        else
            log "DEBUG" "chronyc not installed; skipping chrony diagnostics"
        fi

        # Provide recent chrony logs to help root-cause discovery
        log "INFO" "Collecting recent chrony journal logs (journalctl -u chrony -n 50)"
        run_command "journalctl -u chrony -n 50 --no-pager" || true

        # DNS SRV diagnostics for LDAP and Kerberos
        log "INFO" "Collecting DNS SRV records for LDAP and Kerberos to help discovery issues"
        if command -v dig &>/dev/null; then
            run_command "dig +short SRV _ldap._tcp.${AD_DOMAIN_LOWER}" || true
            run_command "dig +short SRV _kerberos._tcp.${AD_DOMAIN_LOWER}" || true
        elif command -v host &>/dev/null; then
            run_command "host -t SRV _ldap._tcp.${AD_DOMAIN_LOWER}" || true
            run_command "host -t SRV _kerberos._tcp.${AD_DOMAIN_LOWER}" || true
        else
            log "DEBUG" "Neither 'dig' nor 'host' available for DNS SRV checks"
        fi

        # Resolver and hosts diagnostics
        log "INFO" "Resolver configuration (/etc/resolv.conf) and host lookup for domain"
        run_command "cat /etc/resolv.conf" || true
        run_command "getent hosts ${AD_DOMAIN_LOWER} || true" || true

        local cont2
        read -r -p "Continue despite realm discovery failure? (y/n): " cont2
        if [[ "$cont2" != "y" && "$cont2" != "Y" ]]; then
            log "ERROR" "Aborting due to failed domain discovery."
            return 1
        fi
    fi

    log "INFO" "Pre-join checks completed"
    return 0
}

generate_smb_conf() {
    local out_var="$1"; shift
    # Build helper lines from SIMPLE_ALLOW_GROUPS
    local simple_allow_groups_line=""
    local valid_users_line=""
    local invalid_users_line=""
    if [[ -n "${SIMPLE_ALLOW_GROUPS:-}" ]]; then
        # Convert comma-separated to Samba valid users lines (+DOMAIN\"Group") etc.
        IFS=','; read -ra groups <<< "${SIMPLE_ALLOW_GROUPS}"; unset IFS
        local gline_list=()
        for g in "${groups[@]}"; do
            g_trimmed="$(echo "$g" | xargs)"
            gline_list+=("+${AD_DOMAIN_UPPER}\\\"${g_trimmed}")
        done
        valid_users_line="$(IFS=' ' ; echo "${gline_list[*]}")"
        simple_allow_groups_line="# Access control groups set by provisioning: ${SIMPLE_ALLOW_GROUPS}"
        invalid_users_line="+${AD_DOMAIN_UPPER}\\\"Domain Users"
    else
        valid_users_line=""
        invalid_users_line=""
    fi

    # Use process_template to create the file content
    if ! process_template "${TEMPLATE_DIR}/smb.conf.template" "${out_var}" \
        AD_DOMAIN_UPPER="${AD_DOMAIN_UPPER}" \
        WORKGROUP="${WORKGROUP}" \
        IDMAP_PERSONALE_RANGE_LOW="${IDMAP_PERSONALE_RANGE_LOW}" \
        IDMAP_PERSONALE_RANGE_HIGH="${IDMAP_PERSONALE_RANGE_HIGH}" \
        IDMAP_STAR_RANGE_LOW="${IDMAP_STAR_RANGE_LOW}" \
        IDMAP_STAR_RANGE_HIGH="${IDMAP_STAR_RANGE_HIGH}" \
        TEMPLATE_HOMEDIR="${TEMPLATE_HOMEDIR}" \
        SAMBA_LOG_LEVEL="${DEFAULT_SAMBA_LOG_LEVEL:-1}" \
        SAMBA_MAX_LOG_SIZE="${DEFAULT_SAMBA_MAX_LOG_SIZE:-50}" \
        SIMPLE_ALLOW_GROUPS_LINE="${simple_allow_groups_line}" \
        VALID_USERS_LINE="${valid_users_line}" \
        INVALID_USERS_LINE="${invalid_users_line}" \
        IDMAP_BACKEND_DOMAIN="${DEFAULT_IDMAP_BACKEND_DOMAIN:-PERSONALE}" \
        VALID_USERS_PATTERN="${DEFAULT_VALID_USERS_PATTERN:-%S}"; then
        log "ERROR: process_template failed for smb.conf"
        return 1
    fi
    return 0
}

perform_realm_join() {
    local admin_user="${1:-}"
    local ou_full="${2:-}"
    if [[ -z "$admin_user" ]]; then
        read -r -p "Enter AD admin username for realm join (example: ${DEFAULT_AD_ADMIN_USER_EXAMPLE}): " admin_user
        if [[ -z "$admin_user" ]]; then log "No admin username provided, aborting."; return 1; fi
    fi
    if [[ -z "$ou_full" ]]; then
        ou_full="${COMPUTER_OU_CUSTOM_PART},${COMPUTER_OU_BASE}"
    fi
    
    # === AUTOMATIC REALM LEAVE & CLEANUP BEFORE JOIN ===
    # Force leave any existing realm and clean up corrupted realm configurations
    log "DEBUG" "Checking for and cleaning up any existing realm configurations..."

    # Clear realmd cache so it re-probes fresh (avoids stale SSSD vs Winbind mismatch)
    if [[ -d "/var/lib/realmd" ]]; then
        log "DEBUG" "Clearing realmd cache to force fresh realm discovery..."
        rm -rf /var/lib/realmd 2>&1 || log "WARN" "Could not clear /var/lib/realmd cache"
    fi
    
    # First, try direct realm leave (handles normally joined realms)
    log "DEBUG" "Attempting 'realm leave' (errors tolerated)"
    local leave_attempt_output
    set +e
    leave_attempt_output=$(realm leave 2>&1)
    local leave_exit_code=$?
    set -e
    if [[ $leave_exit_code -eq 0 ]]; then
        log "INFO" "Successfully left existing realm"
    else
        log "DEBUG" "realm leave exit code: $leave_exit_code; output: $leave_attempt_output"
    fi
    
    # Second, check for corrupted/empty realm configurations and clean them up
    # These show up in 'realm list' with empty realm-name and domain-name but configured status
    log "DEBUG" "Scanning for corrupted realm configurations... (realm list errors tolerated)"
    local realm_list_output
    set +e
    realm_list_output=$(realm list 2>&1)
    local realm_list_exit=$?
    set -e
    log "DEBUG" "realm list exit code: ${realm_list_exit}"
    
    # Check if there's a corrupted realm (configured: kerberos-member with empty names)
    if echo "$realm_list_output" | grep -q "configured: kerberos-member" && \
       echo "$realm_list_output" | grep -q "realm-name:" && \
       ! echo "$realm_list_output" | grep "realm-name:" | grep -qE "[a-zA-Z0-9]"; then
        log "WARN" "Detected corrupted realm configuration with empty realm-name/domain-name"
        log "INFO" "Cleaning up corrupted realm configuration..."
        
        # Remove the corrupted realm-related configuration files
        # These are typically stored in /var/lib/realmd/ and /etc/realmd/
        if [[ -d "/var/lib/realmd" ]]; then
            log "DEBUG" "Removing /var/lib/realmd directory..."
            rm -rf /var/lib/realmd 2>&1 || log "WARN" "Could not remove /var/lib/realmd"
        fi
        
        # Also check and clean /etc/realmd/ if it exists
        if [[ -d "/etc/realmd" ]]; then
            log "DEBUG" "Backing up and removing /etc/realmd..."
            mkdir -p "$BACKUP_DIR/realmd_backup" 2>/dev/null
            cp -r /etc/realmd/* "$BACKUP_DIR/realmd_backup/" 2>/dev/null || true
            rm -rf /etc/realmd/* 2>&1 || log "WARN" "Could not clean /etc/realmd"
        fi
        
        # Restart realmd daemon to clear the corrupted configuration from memory
        log "INFO" "Restarting realmd daemon to clear corrupted configuration..."
        systemctl restart realmd 2>&1 || log "WARN" "Could not restart realmd service"
        
        # Wait for realmd to restart
        sleep 2
        
        log "INFO" "Corrupted realm configuration cleaned up"
    fi
    
    # Final verification - realm list should be empty or show nothing configured now
    log "DEBUG" "Final realm status check after cleanup... (errors tolerated)"
    set +e
    local final_realm_status
    final_realm_status=$(realm list 2>&1)
    local final_realm_exit=$?
    set -e
    log "DEBUG" "final realm list exit: ${final_realm_exit}"
    if [[ -z "$final_realm_status" ]] || ! echo "$final_realm_status" | grep -q "configured"; then
        log "INFO" "System ready for clean realm join (no active realm configurations)"
    else
        log "WARN" "Some realm configuration still present, but proceeding with join attempt"
    fi

    # Run pre-join checks (time sync and DNS discovery)
    log "DEBUG" "Invoking prejoin_checks()"
    if ! prejoin_checks; then
        log "ERROR" "Pre-join checks failed or were aborted by user. Aborting realm join."
        return 1
    fi

    # Initialize LDBs as per manual steps
    initialize_samba_dbs

    log "Joining realm ${AD_DOMAIN_LOWER} with admin ${admin_user} and OU '${ou_full}'"
    
    # Read password securely (hidden input)
    local admin_password
    read -r -s -p "Enter password for ${admin_user}: " admin_password
    echo  # New line after password prompt
    
    # === CREDENTIAL VALIDATION WITH KINIT ===
    # Test credentials early using kinit to avoid wasting time on realm join if creds are bad
    log "DEBUG" "Validating credentials via kinit before realm join..."
    local kinit_output
    kinit_output=$(printf "%s\n" "$admin_password" | kinit "${admin_user}" 2>&1)
    local kinit_exit=$?
    
    if [[ $kinit_exit -eq 0 ]]; then
        log "INFO" "Credential validation successful (kinit succeeded)"
        # Clear the ticket for this test
        kdestroy 2>/dev/null || true
    else
        log "WARN" "Credential validation FAILED (kinit exit code: $kinit_exit)"
        log "WARN" "kinit output: $kinit_output"
        log "WARN" "This usually means: invalid username format, wrong password, or AD account locked"
        local cont_cred
        read -r -p "Continue anyway? (y/n): " cont_cred
        if [[ "$cont_cred" != "y" && "$cont_cred" != "Y" ]]; then
            log "ERROR" "Aborting realm join due to credential validation failure."
            return 1
        fi
    fi
    
    # Build realmd command (same format as 00_sssd_kerberos_setup.sh for consistency)
    local realm_join_cmd="realm join --verbose -U \"${admin_user}\" --computer-ou=\"${ou_full}\" --os-name=\"${DEFAULT_OS_NAME:-Linux}\" ${AD_DOMAIN_LOWER} --membership-software=${DEFAULT_MEMBERSHIP_SOFTWARE:-samba} --client-software=${DEFAULT_CLIENT_SOFTWARE:-winbind}"
    
    # === PRE-JOIN SAMBA CONFIG ===
    # For AD join it's safer to use the distro-provided default smb.conf as a starting point.
    # Copy the initial file to /etc/samba/ before attempting realm join (user will reconfigure post-join).
    log "INFO" "Pre-deploying initial Samba configuration for realm join..."
    local default_smb_src="/usr/share/samba/smb.conf"
    local dest_smb_path="${SMB_CONF_PATH:-/etc/samba/smb.conf}"
    if [[ -f "${default_smb_src}" ]]; then
        if run_command "cp ${default_smb_src} ${dest_smb_path}"; then
            run_command "chown root:root ${dest_smb_path}" || true
            run_command "chmod 644 ${dest_smb_path}" || true
            log "INFO" "Copied distro default smb.conf to ${dest_smb_path}"
        else
            log "WARN" "Failed to copy default smb.conf; will attempt to continue"
        fi
    else
        log "DEBUG" "Distro default smb.conf not present at ${default_smb_src}; attempting template generation instead"
        local smb_conf_var
        if generate_smb_conf smb_conf_var; then
            deploy_smb_conf smb_conf_var
            log "INFO" "Samba configuration pre-deployed from template"
        else
            log "WARN" "Failed to generate/deploy smb.conf pre-join, but continuing (realmd may handle config)"
        fi
    fi
    
    # Run with password passed via stdin (using single-argument format like 00_sssd_kerberos_setup.sh)
    if printf "%s\n" "$admin_password" | run_command "$realm_join_cmd"; then
        log "Successfully joined realm ${AD_DOMAIN_LOWER}"
        
        # Post-join: Redeploy smb.conf (to ensure template integrity vs realm changes), deploy krb5.conf, and optimize
        log "INFO" "Applying post-join configurations..."
        # If we have generated smb content earlier (`smb_conf_var`), deploy it; otherwise generate now and deploy.
        if [[ -n "${smb_conf_var:-}" ]]; then
            deploy_smb_conf smb_conf_var
        else
            log "DEBUG" "No pre-generated smb_conf_var found; generating smb.conf from template for post-join deployment"
            if generate_smb_conf smb_conf_var; then
                deploy_smb_conf smb_conf_var
            else
                log "WARN" "Failed to generate smb.conf post-join; leaving distro-provided smb.conf in place"
            fi
        fi
        generate_krb5_conf
        post_join_opt
        
        return 0
    else
        log "ERROR: realm join failed. Command: $realm_join_cmd"
        
        # Collect detailed diagnostics when join fails
        log "INFO" "Collecting diagnostics for failed realm join..."
        
        # Check realmd service status and recent logs
        log "INFO" "Realmd service status:"
        run_command "systemctl status realmd --no-pager" || true
        
        # Show recent realmd journal
        log "INFO" "Recent realmd journal (last 50 lines):"
        run_command "journalctl -u realmd -n 50 --no-pager" || true
        
        # Check for keytab file (should not exist if join failed)
        if [[ -f "/etc/krb5.keytab" ]]; then
            log "INFO" "Keytab file exists (join may have partially succeeded):"
            run_command "klist -kte" || true
        else
            log "INFO" "Keytab file does not exist (join failed before keytab creation)"
        fi
        
        # Show net ads join command for manual debugging
        log "INFO" "For manual debugging with verbose output, try:"
        log "INFO" "  kinit ${admin_user}"
        log "INFO" "  net ads join -U ${admin_user} -c /var/cache/realmd/realmd-smb-conf.XXXXX createcomputer=Dsa.Auto/Dip-BIGEA/Servizi_Informatici/ServerFarm_Navile osName=Linux -d3"
        
        # Check if net command exists and try to run it directly with debug output
        if command -v net &>/dev/null; then
            log "INFO" "Attempting direct 'net ads info' to debug RPC connectivity:"
            if printf "%s\n" "$admin_password" | net ads info -U "${admin_user}" 2>&1; then
                log "INFO" "net ads info succeeded (domain is reachable via RPC)"
            else
                log "WARN" "net ads info failed (RPC connectivity issue):"
                run_command "net ads -d3 info -U \"${admin_user}\" 2>&1 | head -100" || true
            fi
        fi
        
        # Additional Kerberos and LDAP diagnostics
        log "INFO" "Kerberos configuration (/etc/krb5.conf):"
        if [[ -f "/etc/krb5.conf" ]]; then
            run_command "cat /etc/krb5.conf" || true
        else
            log "INFO" "/etc/krb5.conf does not exist (will be created by join)"
        fi
        
        # Check LDAP connectivity using ldapsearch
        log "INFO" "Testing LDAP connectivity to domain:"
        if command -v ldapsearch &>/dev/null; then
            run_command "ldapsearch -x -h ${AD_DOMAIN_LOWER} -b '' -s base '(objectclass=*)' 2>&1 | head -20" || log "WARN" "ldapsearch failed or timed out"
        else
            log "DEBUG" "ldapsearch not installed; skipping LDAP connectivity test"
        fi
        
        # Check samba/winbind configuration
        log "INFO" "Checking samba/winbind service status:"
        run_command "systemctl status smbd nmbd winbind --no-pager" || true
        
        # Check for smb.conf
        log "INFO" "Samba configuration status:"
        if [[ -f "/etc/samba/smb.conf" ]]; then
            log "INFO" "smb.conf exists (first 50 lines):"
            run_command "head -50 /etc/samba/smb.conf" || true
        else
            log "INFO" "/etc/samba/smb.conf does not exist (should be deployed after join)"
        fi
        
        return 1
    fi
}

deploy_smb_conf() {
    local content_var_name="$1"
    local dest_path="${SMB_CONF_PATH:-$DEFAULT_SAMBA_SMB_CONF_PATH}"
    log "Deploying Samba config to ${dest_path} (backup existing if present)"
    if [[ -f "$dest_path" ]]; then
        # Backup the current smb.conf into the session backup directory
        _backup_item "$dest_path" "$CURRENT_BACKUP_DIR/etc/samba" || log "Warning: failed to backup existing smb.conf"
    fi
    # Use a safe write (use empty default if indirect var unset)
    if ! printf "%s" "${!content_var_name:-}" > "${dest_path}"; then
        log "ERROR: Failed to write ${dest_path}"
        return 1
    fi
    run_command "chown root:root ${dest_path}" || true
    run_command "chmod 644 ${dest_path}" || true

    # Ensure global section contains ADS-specific settings required for net ads / winbind
    # Remove any existing conflicting lines first to avoid duplicates
    run_command "sed -i -r '/^[[:space:]]*(security|realm|workgroup|kerberos method)[[:space:]]*=/Id' ${dest_path}" || true

    # Normalize idmap domain header for FQDN entries to use WORKGROUP short name instead of FQDN
    # Replace occurrences of the FQDN realms only (do not touch '*' entries)
    if grep -qi "^idmap config .*${AD_DOMAIN_UPPER} *:" "${dest_path}" 2>/dev/null || grep -qi "^idmap config .*${AD_DOMAIN_LOWER} *:" "${dest_path}" 2>/dev/null; then
        run_command "sed -i -r 's/^idmap config[[:space:]]+(${AD_DOMAIN_UPPER}|${AD_DOMAIN_LOWER})[[:space:]]*:/idmap config ${WORKGROUP} :/I' ${dest_path}" || true
    fi

    # Insert required global options immediately after [global] if not present
    # Insert required global options immediately after [global] if not present
    # FIX: Using direct sed/printf instead of complex awk in run_command to avoid quoting hell
    if ! grep -q "security = ads" "${dest_path}"; then
         local tmp_smb
         tmp_smb=$(mktemp)
         # Find line number of [global]
         local global_line
         global_line=$(grep -n "^\[global\]" "${dest_path}" | head -1 | cut -d: -f1)
         
         if [[ -n "$global_line" ]]; then
             # Print file up to [global]
             sed -n "1,${global_line}p" "${dest_path}" > "${tmp_smb}"
             # Inject lines
             printf "   security = ads\n" >> "${tmp_smb}"
             printf "   realm = %s\n" "${REALM}" >> "${tmp_smb}"
             printf "   workgroup = %s\n" "${WORKGROUP}" >> "${tmp_smb}"
             printf "   kerberos method = secrets and keytab\n" >> "${tmp_smb}"
             # Print rest of file
             sed -n "$((global_line + 1)),\$p" "${dest_path}" >> "${tmp_smb}"
             
             cat "${tmp_smb}" > "${dest_path}"
             rm -f "${tmp_smb}"
             log "INFO" "Injected ADS security settings into smb.conf"
         else
             log "WARN" "Could not find [global] section in smb.conf - skipping injection"
         fi
    fi

    # Ensure idmap backend/range for the workgroup exists (append if missing)
    # Ensure correct idmap backend/range for the workgroup (overwrite or append)
    if grep -q -i "^idmap config ${WORKGROUP} :" "${dest_path}"; then
        # Replace backend line
        run_command "sed -i -r 's|^idmap config ${WORKGROUP} : [[:space:]]*backend = .*|idmap config ${WORKGROUP} : backend = rid|I' ${dest_path}" || true
        # Replace range line or append if missing
        if grep -q -i "^idmap config ${WORKGROUP} :.*range" "${dest_path}"; then
            run_command "sed -i -r 's|^idmap config ${WORKGROUP} : [[:space:]]*range = .*|idmap config ${WORKGROUP} : range = ${IDMAP_PERSONALE_RANGE_LOW}-${IDMAP_PERSONALE_RANGE_HIGH}|I' ${dest_path}" || true
        else
            printf "\n# ID mapping for AD domain ${WORKGROUP}\n" >> "${dest_path}"
            printf "idmap config ${WORKGROUP} : backend = rid\n" >> "${dest_path}"
            printf "idmap config ${WORKGROUP} : range = ${IDMAP_PERSONALE_RANGE_LOW}-${IDMAP_PERSONALE_RANGE_HIGH}\n" >> "${dest_path}"
        fi
    else
        printf "\n# ID mapping for AD domain ${WORKGROUP}\n" >> "${dest_path}"
        printf "idmap config ${WORKGROUP} : backend = rid\n" >> "${dest_path}"
        printf "idmap config ${WORKGROUP} : range = ${IDMAP_PERSONALE_RANGE_LOW}-${IDMAP_PERSONALE_RANGE_HIGH}\n" >> "${dest_path}"
    fi

    # Ensure winbind nss info for RFC2307 attribute support and allow shortname/UPN logins
    #if ! grep -q -i "^winbind nss info" "${dest_path}" 2>/dev/null; then
    #    printf "\n# Enable RFC2307 attribute support for winbind\nwinbind nss info = rfc2307\n" >> "${dest_path}"
    #fi

    # Validate smb.conf with testparm to catch syntax errors before attempting join
    if ! command -v testparm &>/dev/null || ! testparm -s "${dest_path}" &>/dev/null; then
        log "WARN" "smb.conf validation failed or 'testparm' not available. Showing config for debugging:"
        run_command "sed -n '1,200p' ${dest_path}" || true
    else
        log "DEBUG" "smb.conf validated with testparm"
    fi

log "Samba config deployed. Restarting related services and flushing cache..."

# Stop services first to ensure cache flush and clean state
run_command "systemctl stop winbind smbd nmbd" || true

    # Flush Samba in-memory cache if 'net' is available
    if command -v net &>/dev/null; then
        run_command "net cache flush" || log "WARN" "net cache flush failed"
    else
        log "DEBUG" "'net' command not found; skipping cache flush"
    fi

# Reload systemd units and start services
run_command "systemctl daemon-reload" || true
run_command "systemctl start smbd nmbd winbind" || log "Warning: start may have failed; check service status"
# Ask Samba to reload configuration for running daemons
run_command "smbcontrol all reload-config" || true

# Ensure idmapd (NFSv4 id mapping) is configured to use the AD domain and nsswitch
# Only configure idmapd if winbind is used and NFS idmap service or package appears present
if [[ "${USE_WINBIND,,}" == "true" ]] && ( command -v rpc.idmapd &>/dev/null || dpkg -s nfs-common &>/dev/null ); then
    log "INFO" "Configuring /etc/idmapd.conf for domain mapping (required for NFS idmap compatibility)"
    local idmapd_path="/etc/idmapd.conf"
        # Backup existing
        if [[ -f "${idmapd_path}" ]]; then
            run_command "cp ${idmapd_path} ${idmapd_path}.bak_$(date +%s)" || true
        fi
        cat > "${idmapd_path}" <<-IDMAPD
[General]
Verbosity = 1
Domain = ${AD_DOMAIN_LOWER}

[Mapping]
Nobody-User = nobody
Nobody-Group = nogroup

[Translation]
Method = nsswitch
IDMAPD
        run_command "chown root:root ${idmapd_path}" || true
        run_command "chmod 644 ${idmapd_path}" || true

        # Ensure nsswitch.conf uses winbind for passwd and group lookups (add winbind if missing)
        local nss_conf_target="/etc/nsswitch.conf"
        if [[ -f "${nss_conf_target}" ]]; then
            run_command "cp '${nss_conf_target}' '${nss_conf_target}.bak_pre_winbind_$(date +%s)'" || true

            # Add winbind to passwd line if not present
            if ! grep -qE '^passwd:.*\bwinbind\b' "${nss_conf_target}"; then
                run_command "sed -i -E 's/^(passwd:[[:space:]]*)(.*)/\1\2 winbind/' '${nss_conf_target}'" || true
            fi

            # Add winbind to group line if not present
            if ! grep -qE '^group:.*\bwinbind\b' "${nss_conf_target}"; then
                run_command "sed -i -E 's/^(group:[[:space:]]*)(.*)/\1\2 winbind/' '${nss_conf_target}'" || true
            fi

            log "INFO" "/etc/nsswitch.conf updated to include winbind for passwd/group (if absent)"
        else
            log "WARN" "/etc/nsswitch.conf not found; cannot configure winbind entries"
        fi
    fi
}

# deploy_krb5_conf removed - replaced by generate_krb5_conf from 11_kerberos_setup.sh

initialize_samba_dbs() {
    log "INFO" "Initializing Samba LDB databases..."
    # These commands are required by manual steps before join
    # Using </dev/null to avoid hanging on any prompts (though ldbadd usually doesn't prompt)
    if run_command "sudo ldbadd -H /var/lib/samba/private/secrets.ldb < /dev/null" && \
       run_command "sudo ldbadd -H /var/lib/samba/private/sam.ldb < /dev/null"; then
        log "INFO" "Samba LDBs initialized."
    else
        log "WARN" "Samba LDB initialization returned error (this might be normal if entries exist or file is new)"
    fi
}

post_join_opt() {
    log "INFO" "Running post-join optimization and cleanup..."
    # Post-join fixup: flush cache and reload services
    run_command "systemctl stop winbind" || true
    run_command "net cache flush" || true
    run_command "systemctl start winbind" || true
    run_command "smbcontrol all reload-config" || true
}

uninstall_samba_kerberos() {
    log "Starting Samba/Winbind Uninstallation..."
    backup_config
    local confirm_uninstall
    read -r -p "This will attempt to leave the domain, remove samba/winbind packages and clean configs. Continue? (y/n): " confirm_uninstall
    if [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]]; then
        log "Uninstallation cancelled."
        return 0
    fi

    local current_domain_to_leave="${AD_DOMAIN_LOWER}"
    if [[ -z "$current_domain_to_leave" ]]; then
        if command -v realm &>/dev/null && realm list --name-only --configured=yes &>/dev/null; then
            current_domain_to_leave=$(realm list --name-only --configured=yes | head -n 1)
        fi
    fi

    if [[ -n "$current_domain_to_leave" ]]; then
        local leave_user_upn
        log "Attempting to leave domain: $current_domain_to_leave"
        read -r -p "Enter AD admin UPN for domain leave (blank for unauthenticated leave): " leave_user_upn
        if [[ -n "$leave_user_upn" ]]; then
            # Prompt for password securely and pipe it to realm so the leave is authenticated
            local leave_password
            read -r -s -p "Enter password for ${leave_user_upn}: " leave_password
            echo
            if printf "%s\n" "$leave_password" | run_command "realm leave -U \"${leave_user_upn}\" \"${current_domain_to_leave}\""; then
                log "Successfully left domain ${current_domain_to_leave} using provided credentials."
            else
                log "Warning: Authenticated realm leave failed for ${leave_user_upn}. Attempting unauthenticated leave as fallback."
                if run_command "realm leave \"${current_domain_to_leave}\""; then
                    log "Successfully left domain ${current_domain_to_leave} (unauthenticated fallback)."
                else
                    log "Warning: Unauthenticated realm leave also failed. Manual cleanup may be required."
                fi
            fi
        else
            # No UPN provided - attempt unauthenticated leave and tolerate failures
            if run_command "realm leave \"${current_domain_to_leave}\""; then
                log "Successfully left domain ${current_domain_to_leave} (unauthenticated)."
            else
                log "Warning: Unauthenticated realm leave failed. Manual cleanup may be required."
            fi
        fi
    else
        log "Could not determine domain to leave. Skipping 'realm leave'."
    fi

    log "Stopping Samba/Winbind services..."
    run_command "systemctl stop smbd nmbd winbind" &>/dev/null || true
    run_command "systemctl disable smbd nmbd winbind" &>/dev/null || true
    if command -v net &>/dev/null; then
        run_command "net cache flush" &>/dev/null || true
    else
        log "DEBUG" "'net' command not present; skipping 'net cache flush' during uninstall"
    fi

    log "Removing packages..."
    local -a packages_to_remove=( samba winbind krb5-user realmd adcli samba-common-bin )
    local -a actually_installed_for_removal=()
    for pkg in "${packages_to_remove[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            actually_installed_for_removal+=("$pkg")
        fi
    done
    if [[ ${#actually_installed_for_removal[@]} -gt 0 ]]; then
        run_command "DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y ${actually_installed_for_removal[*]}" && \
        run_command "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y"
        log "Packages removed: ${actually_installed_for_removal[*]}"
    fi

    log "Cleaning Samba and Kerberos configs (backups kept in session backup dir)..."
    # Remove configs and data directories normally created by realm join / samba
    run_command "rm -rf /etc/samba /var/lib/samba /var/cache/samba" || true
    # Optionally remove /etc/krb5.conf (may be used by other services) - we back it up first
    if [[ -f "/etc/krb5.conf" ]]; then
        run_command "rm -f /etc/krb5.conf" || true
    fi

    # Tidy nsswitch.conf: remove 'winbind' entries if present (backup first)
    local nss_conf_target="/etc/nsswitch.conf"
    if [[ -f "$nss_conf_target" ]]; then
        run_command "cp \"$nss_conf_target\" \"${nss_conf_target}.bak_pre_samba_removal_$(date +%Y%m%d_%H%M%S)\""
        run_command "sed -i -E 's/[[:space:]]+winbind\\b//g; s/\\bwinbind[[:space:]]+//g' \"$nss_conf_target\""
    fi

    log "Uninstall attempt complete. Review logs and backups in $CURRENT_BACKUP_DIR to restore if needed."
}
# --- Verification and Testing Functions ---
test_samba_installation() {
    log "Testing Samba installation..."
    if ! command -v smbd &>/dev/null; then
        log "ERROR: smbd not found. Samba may not be installed."
        return 1
    fi
    if ! command -v winbindd &>/dev/null; then
        log "ERROR: winbindd not found. Winbind may not be installed."
        return 1
    fi
    log "Samba and Winbind binaries found."
    run_command "smbd --version"
    run_command "winbindd --version"
    log "Checking if services are running..."
    systemctl is-active --quiet smbd && log "smbd is active." || log "smbd is NOT active."
    systemctl is-active --quiet winbind && log "winbind is active." || log "winbind is NOT active."
    log "Samba installation test complete."
    return 0
}

check_samba_services_status() {
    log "Checking detailed Samba/Winbind service status..."
    run_command "systemctl status -l --no-pager smbd.service"
    run_command "systemctl status -l --no-pager winbind.service"
    run_command "systemctl status -l --no-pager nmbd.service"
    return 0
}

test_machine_keytab() {
    log "Testing Machine Kerberos Keytab (/etc/krb5.keytab)..."
    local keytab_file="/etc/krb5.keytab"
    if [[ ! -f "$keytab_file" ]]; then
        log "ERROR: Keytab file '$keytab_file' not found. 'realm join' likely failed."
        return 1
    fi
    log "Keytab file found. Listing principals:"
    run_command "klist -kte"
    log "Keytab test passed."
    return 0
}

test_user_lookup() {
    log "Testing user information lookup (getent, id)..."
    local test_user
    read -r -p "Enter a username to test (e.g., domainuser): " test_user
    if [[ -z "$test_user" ]]; then
        log "Skipping test."
        return 0
    fi
    if ! run_command "getent passwd \"$test_user\""; then
        log "ERROR: 'getent passwd' failed."
        return 1
    fi
    log "INFO: 'getent passwd' successful. Verify group memberships in 'id' output below."
    if ! run_command "id \"$test_user\""; then
        log "ERROR: 'id' failed."
        return 1
    fi
    log "User lookup successful."
    return 0
}

test_kerberos_ticket() {
    log "Testing Kerberos ticket acquisition (kinit)..."
    local test_user
    read -r -p "Enter an AD UPN to test kinit (e.g., user@REALM): " test_user
    if [[ -z "$test_user" ]]; then
        log "Skipping test."
        return 0
    fi
    log "Attempting kinit for $test_user (password prompt will follow)."
    if run_command "kinit \"$test_user\""; then
        log "kinit successful."
        run_command "klist"
        run_command "kdestroy"
    else
        log "ERROR: kinit failed."
        return 1
    fi
    return 0
}

view_samba_logs() {
    log "Displaying last 50 lines of Samba log (/var/log/samba/log.smbd)... Use Ctrl+C to stop."
    run_command "tail -n 50 -f /var/log/samba/log.smbd"
    log "Displaying last 50 lines of Winbind log (/var/log/samba/log.winbindd)..."
    run_command "tail -n 50 /var/log/samba/log.winbindd"
}



main_menu() {
    setup_backup_dir
    printf "\n=== Samba + Kerberos Setup Menu ===\n"
    printf "1) Install prereqs and join realm (interactive)\n"
    printf "2) Generate and deploy smb.conf (from template)\n"
    printf "3) Full: install, join, generate & deploy smb.conf\n"
    printf "T) Test Samba/Kerberos installation and configuration\n"
    printf "S) Service status checks\n"
    printf "K) Keytab verification\n"
    printf "U) Uninstall Samba/Winbind & leave domain\n"
    printf "R) Restore configurations from most recent backup\n"
    printf "L) View Samba/Winbind logs\n"
    printf "4) Exit\n"
    read -r -p "Choice: " choice
    local final_smb=""
    case "$choice" in
        1)
            read -r -p "Enter AD admin username (default: $DEFAULT_AD_ADMIN_USER_EXAMPLE): " admin_user
            admin_user="${admin_user:-$DEFAULT_AD_ADMIN_USER_EXAMPLE}"
            backup_config && install_prereqs && \
            perform_realm_join "$admin_user"
            ;;
        2)
            generate_smb_conf final_smb || exit 1
            deploy_smb_conf final_smb
            ;;
        3)
            read -r -p "Enter AD admin username (default: $DEFAULT_AD_ADMIN_USER_EXAMPLE): " admin_user
            admin_user="${admin_user:-$DEFAULT_AD_ADMIN_USER_EXAMPLE}"
            backup_config && install_prereqs && \
            perform_realm_join "$admin_user"
            ;;
        T|t)
            test_samba_installation && test_user_lookup && test_kerberos_ticket
            ;;
        S|s)
            check_samba_services_status
            ;;
        K|k)
            test_machine_keytab
            ;;
        L|l)
            view_samba_logs
            ;;
        U|u)
            uninstall_samba_kerberos
            ;;
        R|r)
            restore_config
            ;;
        *)
            log "Exiting Samba Kerberos Setup."; return 0 ;;
    esac


}

# Script entry
log "=== Samba Kerberos Setup Script Started ==="
main_menu
log "=== Samba Kerberos Setup Script Finished ==="
