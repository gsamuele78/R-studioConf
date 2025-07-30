#!/bin/bash
# sssd_kerberos_setup.sh - SSSD and Kerberos Configuration for AD Integration
# This script guides through setting up SSSD and Kerberos for Active Directory
# integration, including package installation, domain joining, configuration file
# generation from a template, and a comprehensive suite of tests.

# Determine the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Define paths relative to SCRIPT_DIR
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/common_utils.sh"
CONF_VARS_FILE="${SCRIPT_DIR}/conf/sssd_kerberos_setup.vars.conf"
SSSD_CONF_TEMPLATE_PATH="${SCRIPT_DIR}/templates/sssd.conf.template"

# Source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    printf "Error: common_utils.sh not found at %s\n" "$UTILS_SCRIPT_PATH" >&2
    exit 1
fi
# shellcheck source=common_utils.sh
source "$UTILS_SCRIPT_PATH"

# Source configuration variables if file exists
if [[ -f "$CONF_VARS_FILE" ]]; then
    log "Sourcing SSSD/Kerberos configuration variables from $CONF_VARS_FILE"
    # shellcheck source=conf/sssd_kerberos_setup.vars.conf
    source "$CONF_VARS_FILE"
else
    log "Warning: SSSD/Kerberos configuration file $CONF_VARS_FILE not found. Using script internal defaults."
    # Define crucial defaults here if the .conf file is missing
    DEFAULT_AD_DOMAIN_LOWER="ad.example.com"
    DEFAULT_AD_DOMAIN_UPPER="AD.EXAMPLE.COM"
    DEFAULT_AD_ADMIN_USER_EXAMPLE="administrator@${DEFAULT_AD_DOMAIN_UPPER}"
    DEFAULT_COMPUTER_OU_BASE="OU=LinuxSystems,DC=ad,DC=example,DC=com"
    DEFAULT_COMPUTER_OU_CUSTOM_PART="OU=Servers"
    DEFAULT_OS_NAME="Linux Server"
    DEFAULT_FALLBACK_HOMEDIR_TEMPLATE="/home/%d/%u"
    DEFAULT_USE_FQNS="true"
    DEFAULT_SIMPLE_ALLOW_GROUPS=""
    DEFAULT_AD_GPO_MAP_SERVICE=""
    NTP_PREFERRED_CLIENT="chrony"
    DEFAULT_NTP_FALLBACK_POOLS_CHRONY_NTP=("pool 2.debian.pool.ntp.org iburst")
    DEFAULT_NTP_FALLBACK_POOLS_SYSTEMD="0.debian.pool.ntp.org 1.debian.pool.ntp.org"
fi

# --- Global Variables ---
AD_DOMAIN_LOWER=""
AD_DOMAIN_UPPER=""
GENERATED_SSSD_CONF=""
# --- END Global Variables ---


ensure_time_sync() {
    log "Ensuring system time is synchronized..."
    local preferred_ntp_client="${NTP_PREFERRED_CLIENT:-chrony}"
    local ntp_client_to_use=""
    local -a final_ntp_servers=()

    if command -v chronyc &>/dev/null; then ntp_client_to_use="chrony";
    elif command -v ntpq &>/dev/null; then ntp_client_to_use="ntp";
    elif command -v timedatectl &>/dev/null; then ntp_client_to_use="systemd-timesyncd";
    else
        log "$preferred_ntp_client (preferred) not found. Attempting to install..."
        run_command "apt-get update -y && apt-get install -y $preferred_ntp_client" || {
            log "ERROR: Failed to install NTP client. Time sync must be resolved manually."; return 1;
        }
        ntp_client_to_use="$preferred_ntp_client"
    fi
    log "Using NTP client: $ntp_client_to_use"
    
    if [[ "$ntp_client_to_use" == "chrony" ]]; then run_command "systemctl stop systemd-timesyncd ntp" &>/dev/null; run_command "systemctl disable systemd-timesyncd ntp" &>/dev/null
    elif [[ "$ntp_client_to_use" == "ntp" ]]; then run_command "systemctl stop chrony systemd-timesyncd" &>/dev/null; run_command "systemctl disable chrony systemd-timesyncd" &>/dev/null;
    elif [[ "$ntp_client_to_use" == "systemd-timesyncd" ]]; then run_command "systemctl stop chrony ntp" &>/dev/null; run_command "systemctl disable chrony ntp" &>/dev/null; fi

    if [[ "$ntp_client_to_use" == "chrony" ]]; then
        local -a discovered_servers=()
        local temp_ad_domain_lower_for_ntp="${AD_DOMAIN_LOWER:-$DEFAULT_AD_DOMAIN_LOWER}"
        if host -t SRV "_ntp._udp.${temp_ad_domain_lower_for_ntp}" > /dev/null 2>&1; then
            log "Discovering AD NTP servers for domain ${temp_ad_domain_lower_for_ntp}..."
            mapfile -t discovered_servers < <(host -t SRV "_ntp._udp.${temp_ad_domain_lower_for_ntp}" | grep "has SRV record" | awk '{print $NF}' | sed 's/\.$//')
        fi
        
        local user_ntp_servers
        if [[ ${#discovered_servers[@]} -gt 0 ]]; then
            log "Discovered AD NTP servers: ${discovered_servers[*]}"
            read -r -p "Press ENTER to use these, or provide a comma-separated list to override: " user_ntp_servers
            if [[ -z "$user_ntp_servers" ]]; then final_ntp_servers=("${discovered_servers[@]}");
            else IFS=',' read -r -a final_ntp_servers <<< "$user_ntp_servers"; fi
        else
            log "Could not automatically discover NTP servers from AD."
            read -r -p "Please provide a comma-separated list of NTP servers (e.g., dc1.example.com,dc2.example.com): " user_ntp_servers
            if [[ -n "$user_ntp_servers" ]]; then IFS=',' read -r -a final_ntp_servers <<< "$user_ntp_servers";
            else log "No servers provided. Chrony will only use public fallbacks."; final_ntp_servers=(); fi
        fi

        log "Configuring chrony with servers: ${final_ntp_servers[*]}"
        local chrony_conf="/etc/chrony/chrony.conf"; ensure_file_exists "$chrony_conf"
        { printf "# chrony.conf generated by sssd_kerberos_setup.sh\n\ndriftfile /var/lib/chrony/chrony.drift\nmakestep 1.0 3\nrtcsync\nlogdir /var/log/chrony\n\n"; } > "$chrony_conf"
        if [[ ${#final_ntp_servers[@]} -gt 0 ]]; then
            printf "# Use specified AD or user-defined servers as primary time source.\n" >> "$chrony_conf"
            for server in "${final_ntp_servers[@]}"; do printf "server %s iburst\n" "$server" >> "$chrony_conf"; done
        fi
        printf "\n# Use public servers as a fallback.\n" >> "$chrony_conf"
        for pool_server in "${DEFAULT_NTP_FALLBACK_POOLS_CHRONY_NTP[@]}"; do printf "%s\n" "$pool_server" >> "$chrony_conf"; done

        run_command "systemctl restart chrony" && run_command "systemctl enable chrony"; sleep 5
        run_command "chronyc sources"; run_command "chronyc tracking"
        if chronyc sources | grep -q '^\?'; then
            log "WARNING: One or more Chrony sources are 'unreachable' ('?'). Check firewall rules and network connectivity."
        fi
    else
        log "NTP client is not chrony. Relying on default configuration for '$ntp_client_to_use'. Manual review is recommended."
        run_command "systemctl restart $ntp_client_to_use"
    fi

    if timedatectl status | grep -i -q "System clock synchronized: yes"; then log "System time appears synchronized."; return 0;
    else
        log "Warning: System time may not be synchronized."; timedatectl status | tee -a "$LOG_FILE"
        local confirm_time; read -r -p "Continue despite potential time sync issues? (y/n): " confirm_time
        if [[ "$confirm_time" != "y" && "$confirm_time" != "Y" ]]; then log "Aborting due to time sync concerns."; return 1; fi
    fi
    return 0
}

install_sssd_krb_packages() { log "Installing SSSD, Kerberos, and related packages..."; local -a packages_to_install_list=( sssd sssd-tools sssd-ad sssd-krb5 libsss-sudo krb5-user libpam-sss libnss-sss realmd packagekit pamtester ); local -a pkgs_actually_needed=(); for pkg in "${packages_to_install_list[@]}"; do if ! dpkg -s "$pkg" &>/dev/null; then pkgs_actually_needed+=("$pkg"); fi; done; if [[ ${#pkgs_actually_needed[@]} -gt 0 ]]; then run_command "apt-get update -y" || return 1; run_command "DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs_actually_needed[*]}" || return 1; log "Packages installed/verified: ${pkgs_actually_needed[*]}"; else log "All required SSSD/Kerberos packages are already installed."; fi; return 0; }
join_ad_domain_realm() { log "Attempting to join Active Directory domain..."; local ad_domain_lower_input ad_admin_user_input computer_ou_custom_part_input os_name_input; read -r -p "Enter AD Domain (lowercase) [default: ${DEFAULT_AD_DOMAIN_LOWER}]: " ad_domain_lower_input; AD_DOMAIN_LOWER=${ad_domain_lower_input:-$DEFAULT_AD_DOMAIN_LOWER}; AD_DOMAIN_UPPER=$(echo "$AD_DOMAIN_LOWER" | tr '[:lower:]' '[:upper:]'); read -r -p "Enter AD admin UPN for domain join (e.g., ${DEFAULT_AD_ADMIN_USER_EXAMPLE}): " ad_admin_user_input; AD_ADMIN_USER=${ad_admin_user_input}; if [[ -z "$AD_ADMIN_USER" ]]; then log "ERROR: AD Admin User UPN cannot be empty."; return 1; fi; read -r -p "Enter customizable part of Computer OU [default: ${DEFAULT_COMPUTER_OU_CUSTOM_PART}]: " computer_ou_custom_part_input; local computer_ou_custom_part=${computer_ou_custom_part_input:-$DEFAULT_COMPUTER_OU_CUSTOM_PART}; FULL_COMPUTER_OU="${computer_ou_custom_part},${DEFAULT_COMPUTER_OU_BASE}"; read -r -p "Enter OS Name for AD object [default: ${DEFAULT_OS_NAME}]: " os_name_input; OS_NAME=${os_name_input:-$DEFAULT_OS_NAME}; log "Will join with: Domain: $AD_DOMAIN_LOWER, Admin: $AD_ADMIN_USER, OU: $FULL_COMPUTER_OU, OS: $OS_NAME"; if ! run_command "realm discover \"$AD_DOMAIN_LOWER\""; then log "ERROR: Domain $AD_DOMAIN_LOWER not discoverable."; return 1; fi; log "Joining domain (will prompt for password for $AD_ADMIN_USER)..."; local realm_join_cmd="realm join --verbose -U \"$AD_ADMIN_USER\" --computer-ou=\"$FULL_COMPUTER_OU\" --os-name=\"$OS_NAME\" \"$AD_DOMAIN_LOWER\""; if run_command "$realm_join_cmd"; then log "Successfully joined domain $AD_DOMAIN_LOWER."; else log "ERROR: 'realm join' failed. Command: $realm_join_cmd"; return 1; fi; return 0; }
generate_sssd_conf_from_template() { log "Gathering information for sssd.conf from template..."; if [[ ! -f "$SSSD_CONF_TEMPLATE_PATH" ]]; then log "ERROR: SSSD template file not found at $SSSD_CONF_TEMPLATE_PATH"; GENERATED_SSSD_CONF=""; return 1; fi; if [[ -z "${AD_DOMAIN_LOWER}" ]] || [[ -z "${AD_DOMAIN_UPPER}" ]]; then local ad_domain_lower_conf_input; read -r -p "Enter AD Domain (lowercase) for sssd.conf [default: ${DEFAULT_AD_DOMAIN_LOWER}]: " ad_domain_lower_conf_input; AD_DOMAIN_LOWER=${ad_domain_lower_conf_input:-$DEFAULT_AD_DOMAIN_LOWER}; AD_DOMAIN_UPPER=$(echo "$AD_DOMAIN_LOWER" | tr '[:lower:]' '[:upper:]'); fi; local fallback_homedir_template_input use_fqns_input simple_allow_groups_input ad_gpo_map_service_input; read -r -p "Enter fallback_homedir template [default: ${DEFAULT_FALLBACK_HOMEDIR_TEMPLATE}]: " fallback_homedir_template_input; FALLBACK_HOMEDIR_TEMPLATE="${fallback_homedir_template_input:-$DEFAULT_FALLBACK_HOMEDIR_TEMPLATE}"; read -r -p "Use fully qualified names for login? (true/false) [default: ${DEFAULT_USE_FQNS}]: " use_fqns_input; USE_FQNS="${use_fqns_input:-$DEFAULT_USE_FQNS}"; read -r -p "Enter comma-separated AD groups to allow login (blank for none) [default: '${DEFAULT_SIMPLE_ALLOW_GROUPS}']: " simple_allow_groups_input; SIMPLE_ALLOW_GROUPS="${simple_allow_groups_input:-$DEFAULT_SIMPLE_ALLOW_GROUPS}"; read -r -p "Enter GPO service mapping for RStudio (e.g., +rstudio) [default: '${DEFAULT_AD_GPO_MAP_SERVICE}']: " ad_gpo_map_service_input; AD_GPO_MAP_SERVICE_CONFIG="${ad_gpo_map_service_input:-$DEFAULT_AD_GPO_MAP_SERVICE}"; local client_hostname; client_hostname=$(hostname -f 2>/dev/null || hostname); log "--- SSSD Configuration Summary ---"; log "Template: $SSSD_CONF_TEMPLATE_PATH"; log "Domain: $AD_DOMAIN_LOWER | Realm: $AD_DOMAIN_UPPER | HomeDir: $FALLBACK_HOMEDIR_TEMPLATE"; log "FQNs: $USE_FQNS | Groups: ${SIMPLE_ALLOW_GROUPS:-Any} | GPO RStudio: ${AD_GPO_MAP_SERVICE_CONFIG:-None}"; log "Client Hostname: $client_hostname"; log "---"; local simple_allow_groups_line_val="#simple_allow_groups = "; if [[ -n "$SIMPLE_ALLOW_GROUPS" ]]; then simple_allow_groups_line_val="simple_allow_groups = $SIMPLE_ALLOW_GROUPS"; fi; local ad_gpo_map_service_line_val="#ad_gpo_map_service = "; if [[ -n "$AD_GPO_MAP_SERVICE_CONFIG" ]]; then ad_gpo_map_service_line_val="ad_gpo_map_service = $AD_GPO_MAP_SERVICE_CONFIG"; fi; if ! process_template "$SSSD_CONF_TEMPLATE_PATH" "GENERATED_SSSD_CONF" "AD_DOMAIN_LOWER=$AD_DOMAIN_LOWER" "AD_DOMAIN_UPPER=$AD_DOMAIN_UPPER" "FALLBACK_HOMEDIR_TEMPLATE=$FALLBACK_HOMEDIR_TEMPLATE" "USE_FQNS=$USE_FQNS" "CLIENT_HOSTNAME=$client_hostname" "SIMPLE_ALLOW_GROUPS_LINE=$simple_allow_groups_line_val" "AD_GPO_MAP_SERVICE_LINE=$ad_gpo_map_service_line_val"; then log "ERROR: Failed to process SSSD template file '$SSSD_CONF_TEMPLATE_PATH'."; GENERATED_SSSD_CONF=""; return 1; fi; if [[ -z "$GENERATED_SSSD_CONF" ]]; then log "ERROR: Processed SSSD configuration is empty."; return 1; fi; return 0; }
configure_sssd_conf() { log "Configuring /etc/sssd/sssd.conf from template..."; if ! generate_sssd_conf_from_template; then log "ERROR: Failed to generate sssd.conf content. Aborting configuration."; return 1; fi; local sssd_conf_target="/etc/sssd/sssd.conf"; ensure_dir_exists "$(dirname "$sssd_conf_target")"; log "Writing generated configuration to $sssd_conf_target"; if [[ -f "$sssd_conf_target" ]]; then run_command "cp \"$sssd_conf_target\" \"${sssd_conf_target}.bak_pre_script_$(date +%Y%m%d_%H%M%S)\""; fi; if ! printf "%s\n" "$GENERATED_SSSD_CONF" > "$sssd_conf_target"; then log "ERROR: Failed to write to $sssd_conf_target"; return 1; fi; run_command "chmod 0600 $sssd_conf_target" || log "Warning: Failed to set permissions on $sssd_conf_target."; log "$sssd_conf_target configured successfully. Content:"; run_command "cat $sssd_conf_target"; return 0; }
configure_krb5_conf() { log "Ensuring basic Kerberos configuration in /etc/krb5.conf..."; local krb5_conf_target="/etc/krb5.conf"; ensure_file_exists "$krb5_conf_target" || return 1; if [[ -z "$AD_DOMAIN_UPPER" ]]; then local ad_domain_upper_krb_input; read -r -p "Enter AD Kerberos Realm (UPPERCASE) for krb5.conf [default: ${DEFAULT_AD_DOMAIN_UPPER}]: " ad_domain_upper_krb_input; AD_DOMAIN_UPPER=${ad_domain_upper_krb_input:-$DEFAULT_AD_DOMAIN_UPPER}; fi; if ! grep -q "\[libdefaults\]" "$krb5_conf_target"; then printf "\n[libdefaults]\n" >> "$krb5_conf_target"; fi; if ! grep -q "default_realm" "$krb5_conf_target"; then run_command "sed -i '/\\[libdefaults\\]/a \ \ default_realm = ${AD_DOMAIN_UPPER}' '${krb5_conf_target}'"; else run_command "sed -i 's/^[[:space:]]*default_realm[[:space:]]*=.*$/  default_realm = ${AD_DOMAIN_UPPER}/' '${krb5_conf_target}'"; fi; local default_ccache_line="default_ccache_name = FILE:/tmp/krb5cc_%{uid}"; if ! grep -q "default_ccache_name" "$krb5_conf_target"; then run_command "sed -i '/\\[libdefaults\\]/a \ \ ${default_ccache_line}' '${krb5_conf_target}'"; fi; log "${krb5_conf_target} updated. Content:"; run_command "cat ${krb5_conf_target}"; return 0; }
configure_nsswitch() { log "Checking and configuring /etc/nsswitch.conf for SSSD..."; local nss_conf_target="/etc/nsswitch.conf"; ensure_file_exists "$nss_conf_target" || return 1; local -a nss_databases=("passwd" "group" "shadow" "sudoers"); local entry_modified_overall=0; for entry in "${nss_databases[@]}"; do local current_line; current_line=$(grep "^${entry}:" "$nss_conf_target"); if [[ -z "$current_line" ]]; then add_line_if_not_present "${entry}: files sss" "$nss_conf_target"; entry_modified_overall=1; elif [[ "$current_line" != *sss* ]]; then log "Adding 'sss' to '$entry' in $nss_conf_target..."; run_command "sed -i -E 's/^((${entry}):.*)(files)(.*)/\1 sss\4/' '${nss_conf_target}'"; if ! grep -q "^${entry}:.* sss\b" "$nss_conf_target"; then run_command "sed -i -E 's/^((${entry}):.*)/\1 sss/' '${nss_conf_target}'"; fi; entry_modified_overall=1; else log "'sss' already configured for '${entry}:'."; fi; done; if [[ "$entry_modified_overall" -eq 1 ]]; then log "$nss_conf_target modified. Content:"; run_command "cat $nss_conf_target"; fi; return 0; }
configure_pam() { log "Checking and configuring PAM for SSSD..."; if command -v pam-auth-update &>/dev/null; then log "Running pam-auth-update to ensure SSS and mkhomedir modules are enabled..."; if ! run_command "DEBIAN_FRONTEND=noninteractive pam-auth-update --enable sss --enable mkhomedir"; then log "Warning: pam-auth-update failed."; fi; else log "Warning: pam-auth-update not found. Manual PAM configuration required."; fi; local rstudio_pam_file="/etc/pam.d/rstudio"; if [[ -f "$rstudio_pam_file" ]]; then log "RStudio PAM file content:"; run_command "cat $rstudio_pam_file"; else log "$rstudio_pam_file not found. RStudio will likely use system default PAM stack."; fi; return 0; }
restart_and_verify_sssd() { log "Restarting SSSD service..."; run_command "systemctl daemon-reload"; if ! run_command "systemctl restart sssd"; then log "ERROR: Failed to restart SSSD."; return 1; fi; if ! run_command "systemctl is-active -q sssd"; then log "ERROR: SSSD not active post-restart."; return 1; fi; run_command "systemctl enable sssd"; log "SSSD restarted and is active."; log "Clearing SSSD cache..."; run_command "sss_cache -E"; return 0; }
uninstall_sssd_kerberos() { log "Starting SSSD/Kerberos Uninstallation..."; backup_config; local confirm_uninstall; read -r -p "This will leave the domain, remove packages, and clean configs. Sure? (y/n): " confirm_uninstall; if [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]]; then log "Uninstallation cancelled."; return 0; fi; local current_domain_to_leave="${AD_DOMAIN_LOWER}"; if [[ -z "$current_domain_to_leave" ]]; then if command -v realm &>/dev/null && realm list --name-only --configured=yes &>/dev/null; then current_domain_to_leave=$(realm list --name-only --configured=yes | head -n 1); elif [[ -f "/etc/sssd/sssd.conf" ]] && grep -q "^domains[[:space:]]*=" /etc/sssd/sssd.conf; then current_domain_to_leave=$(grep "^domains[[:space:]]*=" /etc/sssd/sssd.conf | awk -F'=' '{print $2}' | awk '{$1=$1;print}'); fi; fi; if [[ -n "$current_domain_to_leave" ]]; then local leave_user_upn; log "Attempting to leave domain: $current_domain_to_leave"; read -r -p "Enter AD admin UPN for domain leave (blank for unauth leave): " leave_user_upn; local leave_cmd="realm leave \"$current_domain_to_leave\""; if [[ -n "$leave_user_upn" ]]; then leave_cmd="realm leave -U \"$leave_user_upn\" \"$current_domain_to_leave\""; fi; if run_command "$leave_cmd"; then log "Successfully left domain $current_domain_to_leave."; else log "Warning: Failed to leave domain. CMD: $leave_cmd"; fi; else log "Could not determine domain to leave. Skipping 'realm leave'."; fi; log "Stopping services..."; run_command "systemctl stop sssd chrony ntp systemd-timesyncd" &>/dev/null; run_command "systemctl disable sssd chrony ntp systemd-timesyncd" &>/dev/null; log "Removing packages..."; local -a packages_to_remove=( sssd sssd-tools sssd-ad sssd-krb5 krb5-user libpam-sss libnss-sss realmd chrony ntp pamtester ); local -a actually_installed_for_removal=(); for pkg in "${packages_to_remove[@]}"; do if dpkg -s "$pkg" &>/dev/null; then actually_installed_for_removal+=("$pkg"); fi; done; if [[ ${#actually_installed_for_removal[@]} -gt 0 ]]; then run_command "apt-get remove --purge -y ${actually_installed_for_removal[*]}"; run_command "apt-get autoremove -y"; log "Packages removed: ${actually_installed_for_removal[*]}"; fi; log "Cleaning configs..."; run_command "rm -rf /etc/sssd /etc/krb5.conf"; local nss_conf_target="/etc/nsswitch.conf"; if [[ -f "$nss_conf_target" ]]; then run_command "cp \"$nss_conf_target\" \"${nss_conf_target}.bak_pre_sss_removal_$(date +%Y%m%d_%H%M%S)\""; run_command "sed -i -E 's/[[:space:]]+sss\b//g; s/\bsss[[:space:]]+//g' \"$nss_conf_target\""; fi; if command -v pam-auth-update &>/dev/null; then if ! run_command "DEBIAN_FRONTEND=noninteractive pam-auth-update --remove sss --remove mkhomedir"; then log "Warning: pam-auth-update --remove failed."; fi; fi; run_command "rm -rf /var/lib/sss/* /var/log/sssd/*"; log "Uninstall attempt complete."; }
full_sssd_kerberos_setup() { backup_config; ensure_time_sync && install_sssd_krb_packages && join_ad_domain_realm && configure_sssd_conf && configure_krb5_conf && configure_nsswitch && configure_pam && restart_and_verify_sssd && log "Core SSSD/Kerberos setup process completed." || { log "ERROR: Core SSSD/Kerberos setup process failed."; return 1; }; }
test_machine_keytab() { log "Testing Machine Kerberos Keytab (/etc/krb5.keytab)..."; local keytab_file="/etc/krb5.keytab"; if [[ ! -f "$keytab_file" ]]; then log "ERROR: Keytab file '$keytab_file' not found. 'realm join' likely failed."; return 1; fi; log "Keytab file found. Listing principals:"; if ! run_command "klist -kte"; then log "ERROR: 'klist -kte' failed or keytab is empty."; return 1; fi; log "Keytab test passed."; return 0; }
test_sssd_service_status() { log "Checking detailed SSSD service status..."; if ! run_command "systemctl status -l --no-pager sssd.service"; then log "Warning: 'systemctl status' indicates SSSD is not in a healthy 'active (running)' state."; fi; if ! systemctl is-active -q sssd; then log "ERROR: SSSD service is NOT active."; return 1; fi; log "SSSD service status check passed (service is running)."; return 0; }
test_sssd_access_control() { log "Testing SSSD access control (simple_allow_groups)..."; if ! command -v pamtester &>/dev/null; then log "pamtester not found."; return 1; fi; local allowed_groups="${SIMPLE_ALLOW_GROUPS:-${DEFAULT_SIMPLE_ALLOW_GROUPS}}"; if [[ -z "$allowed_groups" ]]; then log "INFO: 'simple_allow_groups' is not set. Test is not applicable."; return 0; fi; log "Access is restricted to: $allowed_groups"; local use_fqn_effective="${USE_FQNS:-$DEFAULT_USE_FQNS}"; local user_format_example="ad_user"; if [[ "$use_fqn_effective" == "true" ]]; then user_format_example="user@${AD_DOMAIN_LOWER:-$DEFAULT_AD_DOMAIN_LOWER}"; fi; local allowed_user; read -r -p "Enter a username who IS IN an allowed group [e.g., $user_format_example]: " allowed_user; if [[ -n "$allowed_user" ]]; then log "Testing ALLOWED user '$allowed_user' (should succeed)..."; if run_command "pamtester --verbose rstudio \"$allowed_user\" authenticate"; then log "SUCCESS: Allowed user '$allowed_user' authenticated as expected."; else log "FAILURE: Allowed user '$allowed_user' FAILED authentication unexpectedly."; fi; fi; local disallowed_user; read -r -p "Enter a username who IS NOT in an allowed group [e.g., $user_format_example]: " disallowed_user; if [[ -n "$disallowed_user" ]]; then log "Testing DISALLOWED user '$disallowed_user' (should fail)..."; if ! run_command "pamtester --verbose rstudio \"$disallowed_user\" authenticate"; then log "SUCCESS: Disallowed user '$disallowed_user' was correctly denied access."; else log "FAILURE: Disallowed user '$disallowed_user' authenticated unexpectedly."; fi; fi; return 0; }
view_sssd_logs() { log "Displaying last 50 lines of SSSD log (/var/log/sssd/sssd.log)... Use Ctrl+C to stop."; run_command "tail -n 50 -f /var/log/sssd/sssd.log"; }
test_kerberos_ticket() { log "Testing Kerberos ticket acquisition (kinit)..."; local test_user; local test_user_kinit_default_example="user@${AD_DOMAIN_UPPER:-$DEFAULT_AD_DOMAIN_UPPER}"; read -r -p "Enter an AD UPN to test kinit [e.g., ${test_user_kinit_default_example}]: " test_user; if [[ -z "$test_user" ]]; then log "Skipping test."; return 0; fi; log "Attempting kinit for $test_user (password prompt will follow)."; if run_command "kinit \"$test_user\""; then log "kinit successful."; run_command "klist"; run_command "kdestroy"; else log "ERROR: kinit failed."; return 1; fi; return 0; }
test_user_lookup() { log "Testing user information lookup (getent, id)..."; local test_user; local use_fqn_effective="${USE_FQNS:-$DEFAULT_USE_FQNS}"; local test_user_lookup_example="ad_username"; if [[ "$use_fqn_effective" == "true" ]]; then test_user_lookup_example="ad_username@${AD_DOMAIN_LOWER:-$DEFAULT_AD_DOMAIN_LOWER}"; fi; read -r -p "Enter an AD username to test [e.g., ${test_user_lookup_example}]: " test_user; if [[ -z "$test_user" ]]; then log "Skipping test."; return 0; fi; if ! run_command "getent passwd \"$test_user\""; then log "ERROR: 'getent passwd' failed."; return 1; fi; log "INFO: 'getent passwd' successful. Verify group memberships in 'id' output below."; if ! run_command "id \"$test_user\""; then log "ERROR: 'id' failed."; return 1; fi; log "User lookup successful."; return 0; }
test_rstudio_pam_integration() { log "Testing RStudio PAM integration (pamtester)..."; if ! command -v pamtester &>/dev/null; then log "pamtester not found."; return 1; fi; local test_user_pam; local use_fqn_effective="${USE_FQNS:-$DEFAULT_USE_FQNS}"; local test_user_pam_example="ad_username"; if [[ "$use_fqn_effective" == "true" ]]; then test_user_pam_example="ad_username@${AD_DOMAIN_LOWER:-$DEFAULT_AD_DOMAIN_LOWER}"; fi; read -r -p "Enter AD username for RStudio PAM test [e.g., ${test_user_pam_example}]: " test_user_pam; if [[ -z "$test_user_pam" ]]; then log "Skipping test."; return 0; fi; log "Testing PAM for RStudio service with user '$test_user_pam' (password prompt will follow)."; if run_command "pamtester --verbose rstudio \"$test_user_pam\" authenticate acct_mgmt"; then log "RStudio PAM test SUCCEEDED."; log "INFO: Check if home directory was created at path defined by 'fallback_homedir'."; else log "RStudio PAM test FAILED."; return 1; fi; return 0; }

main_sssd_kerberos_menu() {
    setup_backup_dir
    while true; do
        printf "\n===== SSSD/Kerberos (AD Integration) Setup & Test Menu =====\n"
        printf "1. Full SSSD/Kerberos Setup (Time, Pkgs, Join, Config)\n"
        printf -- "---------------------- Individual Steps ---------------------\n"
        printf "T. Ensure Time Synchronization (Chrony/NTP)\n"
        printf "2. Install SSSD/Kerberos Packages\n"
        printf "3. Join AD Domain (interactive 'realm join')\n"
        printf "4. Generate and Configure sssd.conf (from template)\n"
        printf "5. Configure krb5.conf (basics, for client tools)\n"
        printf "6. Configure nsswitch.conf for SSSD\n"
        printf "7. Configure PAM for SSSD (using pam-auth-update)\n"
        printf "8. Restart and Verify SSSD Service (includes cache clear)\n"
        printf -- "--------------------- Verification & Tests --------------------\n"
        printf "V1. Check SSSD Service Detailed Status\n"
        printf "V2. Check Machine's Kerberos Keytab (klist -kte)\n"
        printf "V3. Test Kerberos User Ticket (kinit)\n"
        printf "V4. Test User/Group Lookup (getent, id)\n"
        printf "V5. Test SSSD Access Control (simple_allow_groups)\n"
        printf "V6. Test RStudio PAM Integration (pamtester)\n"
        printf "V7. View SSSD Logs (tail -f)\n"
        printf -- "----------------------- Maintenance ---------------------\n"
        printf "U. Uninstall SSSD/Kerberos Configuration\n"
        printf "R. Restore All Configurations from Last Backup\n"
        printf "E. Exit SSSD/Kerberos Setup\n"
        printf "=======================================================\n"
        read -r -p "Enter choice: " choice
        case $choice in
            1) full_sssd_kerberos_setup ;;
            T|t) backup_config && ensure_time_sync ;;
            2) backup_config && install_sssd_krb_packages ;;
            3) backup_config && ensure_time_sync && install_sssd_krb_packages && join_ad_domain_realm && configure_krb5_conf && restart_and_verify_sssd ;;
            4) backup_config && configure_sssd_conf && restart_and_verify_sssd ;;
            5) backup_config && configure_krb5_conf ;;
            6) backup_config && configure_nsswitch && restart_and_verify_sssd ;;
            7) backup_config && configure_pam && restart_and_verify_sssd ;;
            8) restart_and_verify_sssd ;;
            V1|v1) test_sssd_service_status ;; V2|v2) test_machine_keytab ;;
            V3|v3) test_kerberos_ticket ;; V4|v4) test_user_lookup ;;
            V5|v5) test_sssd_access_control ;; V6|v6) test_rstudio_pam_integration ;;
            V7|v7) view_sssd_logs ;;
            U|u) uninstall_sssd_kerberos ;;
            R|r) restore_config ;;
            E|e) log "Exiting SSSD/Kerberos Setup."; break ;;
            *) printf "Invalid choice. Please try again.\n" ;;
        esac
        if [[ "$choice" != "e" && "$choice" != "E" && "$choice" != "V7" && "$choice" != "v7" ]]; then
            read -r -p "Press Enter to continue..."
        fi
    done
}

# --- Script Entry Point ---
log "=== SSSD/Kerberos Setup Script Started ==="
main_sssd_kerberos_menu
log "=== SSSD/Kerberos Setup Script Finished ==="
