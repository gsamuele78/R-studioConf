#!/bin/bash
# samba_kerberos_setup.sh - Samba + Kerberos join and configuration helper
# Uses common utilities (`process_template`, `run_command`, logging helpers)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
CONF_VARS_FILE="${SCRIPT_DIR}/../config/samba_kerberos_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
SMB_CONF_PATH_DEFAULT="/etc/samba/smb.conf"

if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    printf "Error: common_utils.sh not found at %s\n" "$UTILS_SCRIPT_PATH" >&2
    exit 1
fi
source "$UTILS_SCRIPT_PATH"

# Load variables
if [[ -f "$CONF_VARS_FILE" ]]; then
    log "Sourcing Samba Kerberos configuration variables from $CONF_VARS_FILE"
    # shellcheck source=../config/samba_kerberos_setup.vars.conf
    source "$CONF_VARS_FILE"
else
    log "Warning: Samba Kerberos vars file not found; using embedded defaults."
    # reasonable defaults (will be overridden by vars file when present)
    AD_DOMAIN_LOWER="personale.dir.unibo.it"
    AD_DOMAIN_UPPER="PERSONALE.DIR.UNIBO.IT"
    COMPUTER_OU_BASE="OU=Servizi_Informatici,OU=Dip-BIGEA,OU=Dsa.Auto"
    COMPUTER_OU_CUSTOM_PART="OU=ServerFarm_Navile"
    OS_NAME="Linux"
    SMB_CONF_PATH="${SMB_CONF_PATH_DEFAULT}"
    IDMAP_PERSONALE_RANGE_LOW=163600000
    IDMAP_PERSONALE_RANGE_HIGH=263600000
    IDMAP_STAR_RANGE_LOW=10000
    IDMAP_STAR_RANGE_HIGH=999999
    TEMPLATE_HOMEDIR="/nfs/home/%U"
    REALM="PERSONALE.DIR.UNIBO.IT"
    WORKGROUP="PERSONALE"
    SIMPLE_ALLOW_GROUPS=""
fi

ensure_executable() { command -v "$1" &>/dev/null || return 1; }

install_prereqs() {
    log "Ensuring required packages are installed: samba, winbind, krb5-user, realmd"
    local pkgs=(samba winbind krb5-user realmd sssd-ad adcli samba-common-bin)
    for p in "${pkgs[@]}"; do
        if ! command -v "$p" &>/dev/null && ! dpkg -s "$p" &>/dev/null; then
            log "Package $p not present. Installing..."
            run_command "apt-get update -y && apt-get install -y $p" || { log "Failed to install $p"; return 1; }
        fi
    done
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
        INVALID_USERS_LINE="${invalid_users_line}"; then
        log "ERROR: process_template failed for smb.conf"
        return 1
    fi
    return 0
}

perform_realm_join() {
    local admin_user="$1"
    local ou_full="$2"
    if [[ -z "$admin_user" ]]; then
        read -r -p "Enter AD admin username for realm join (example: ${DEFAULT_AD_ADMIN_USER_EXAMPLE}): " admin_user
        if [[ -z "$admin_user" ]]; then log "No admin username provided, aborting."; return 1; fi
    fi
    if [[ -z "$ou_full" ]]; then
        ou_full="${COMPUTER_OU_CUSTOM_PART},${COMPUTER_OU_BASE}"
    fi
    log "Joining realm ${AD_DOMAIN_LOWER} with admin ${admin_user} and OU '${ou_full}'"
    # Build realmd command
    local cmd="realm join --verbose -U '${admin_user}' --computer-ou='${ou_full}' --os-name='${DEFAULT_OS_NAME:-Linux}' ${AD_DOMAIN_LOWER} --membership-software=${DEFAULT_MEMBERSHIP_SOFTWARE:-samba} --client-software=${DEFAULT_CLIENT_SOFTWARE:-winbind}"
    # Run interactively with run_command wrapper so logs capture output
    run_command "$cmd" || { log "realm join failed"; return 1; }
    return 0
}

deploy_smb_conf() {
    local content_var_name="$1"
    local dest_path="${SMB_CONF_PATH:-$DEFAULT_SAMBA_SMB_CONF_PATH}"
    log "Deploying Samba config to ${dest_path} (backup existing if present)"
    if [[ -f "$dest_path" ]]; then
        # Backup the current smb.conf into the session backup directory
        _backup_item "$dest_path" "$CURRENT_BACKUP_DIR/etc/samba" || log "Warning: failed to backup existing smb.conf"
    fi
    # Use a safe write
    if ! printf "%s" "${!content_var_name}" > "${dest_path}"; then
        log "ERROR: Failed to write ${dest_path}"
        return 1
    fi
    run_command "chown root:root ${dest_path}" || true
    run_command "chmod 644 ${dest_path}" || true
    log "Samba config deployed. Restarting related services..."
    run_command "systemctl restart smbd nmbd winbind" || log "Warning: restart may have failed; check service status"
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
        local leave_cmd="realm leave \"$current_domain_to_leave\""
        if [[ -n "$leave_user_upn" ]]; then
            leave_cmd="realm leave -U \"$leave_user_upn\" \"$current_domain_to_leave\""
        fi
        if run_command "$leave_cmd"; then
            log "Successfully left domain $current_domain_to_leave."
        else
            log "Warning: Failed to leave domain. CMD: $leave_cmd"
        fi
    else
        log "Could not determine domain to leave. Skipping 'realm leave'."
    fi

    log "Stopping Samba/Winbind services..."
    run_command "systemctl stop smbd nmbd winbind" &>/dev/null || true
    run_command "systemctl disable smbd nmbd winbind" &>/dev/null || true

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
            backup_config && install_prereqs && perform_realm_join
            ;;
        2)
            generate_smb_conf final_smb || exit 1
            deploy_smb_conf final_smb
            ;;
        3)
            backup_config && install_prereqs && perform_realm_join && \
            generate_smb_conf final_smb && deploy_smb_conf final_smb
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
}

# Script entry
log "=== Samba Kerberos Setup Script Started ==="
main_menu
log "=== Samba Kerberos Setup Script Finished ==="
