#!/bin/bash
# sssd_kerberos_setup.sh - SSSD and Kerberos Configuration for AD Integration
# This script guides through setting up SSSD and Kerberos for Active Directory
# integration, including package installation, domain joining, configuration file
# generation from a template, and testing.

# Determine the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Define paths relative to SCRIPT_DIR
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/common_utils.sh"
CONF_VARS_FILE="${SCRIPT_DIR}/conf/sssd_kerberos_setup.vars.conf"
SSSD_CONF_TEMPLATE_PATH="${SCRIPT_DIR}/templates/sssd.conf.template"
# TEMPLATE_DIR is used by _get_template_content if it were here, but sssd.conf.template path is explicit.

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
    # Define crucial defaults here from sssd_kerberos_setup.vars.conf
    DEFAULT_AD_DOMAIN_LOWER="ad.example.com" # Generic fallback
    DEFAULT_AD_DOMAIN_UPPER="AD.EXAMPLE.COM"
    DEFAULT_AD_ADMIN_USER_EXAMPLE="administrator@${DEFAULT_AD_DOMAIN_UPPER}"
    DEFAULT_COMPUTER_OU_BASE="OU=LinuxSystems,DC=ad,DC=example,DC=com" # Generic fallback
    DEFAULT_COMPUTER_OU_CUSTOM_PART="OU=Servers"
    DEFAULT_OS_NAME="Linux Server"
    DEFAULT_FALLBACK_HOMEDIR_TEMPLATE="/home/%d/%u"
    DEFAULT_USE_FQNS="true"
    DEFAULT_SIMPLE_ALLOW_GROUPS="" # No default groups
    DEFAULT_AD_GPO_MAP_SERVICE=""  # No default GPO map
    NTP_PREFERRED_CLIENT="chrony"
    DEFAULT_NTP_FALLBACK_POOLS_CHRONY_NTP=("2.debian.pool.ntp.org iburst")
    DEFAULT_NTP_FALLBACK_POOLS_SYSTEMD="0.debian.pool.ntp.org 1.debian.pool.ntp.org"
fi

# --- Global Variables (will be populated by sourced conf or script logic) ---
AD_DOMAIN_LOWER=""
AD_DOMAIN_UPPER=""
AD_ADMIN_USER=""
FULL_COMPUTER_OU=""
OS_NAME=""
FALLBACK_HOMEDIR_TEMPLATE=""
USE_FQNS=""
SIMPLE_ALLOW_GROUPS=""
AD_GPO_MAP_SERVICE_CONFIG=""
GENERATED_SSSD_CONF="" # Stores the processed sssd.conf content
# --- END Global Variables ---


# --- Time Synchronization ---
ensure_time_sync() {
    log "Ensuring system time is synchronized..."
    local preferred_ntp_client="${NTP_PREFERRED_CLIENT:-chrony}" # Use sourced or default
    local -a ad_ntp_servers=() # Array to store discovered NTP servers

    # Use AD_DOMAIN_LOWER if already set (e.g., from join attempt), else default from conf
    local temp_ad_domain_lower_for_ntp="${AD_DOMAIN_LOWER:-$DEFAULT_AD_DOMAIN_LOWER}"

    # Attempt to discover AD NTP servers via DNS SRV records
    if host -t SRV "_ntp._udp.${temp_ad_domain_lower_for_ntp}" > /dev/null 2>&1; then
        log "Attempting to discover AD NTP servers for domain ${temp_ad_domain_lower_for_ntp}..."
        mapfile -t discovered_servers < <(host -t SRV "_ntp._udp.${temp_ad_domain_lower_for_ntp}" | grep "has SRV record" | awk '{print $NF}' | sed 's/\.$//')
        if [[ ${#discovered_servers[@]} -gt 0 ]]; then
            log "Discovered AD NTP servers: ${discovered_servers[*]}"
            ad_ntp_servers=("${discovered_servers[@]}")
        else
            log "Could not automatically discover AD NTP servers via DNS SRV for ${temp_ad_domain_lower_for_ntp}."
        fi
    else
        log "No DNS SRV records for _ntp._udp.${temp_ad_domain_lower_for_ntp} found, or host command failed."
    fi

    local ntp_client_to_use=""
    # Determine which NTP client to use/install
    if command -v chronyc &>/dev/null && [[ "$preferred_ntp_client" == "chrony" || -z "$ntp_client_to_use" ]]; then ntp_client_to_use="chrony"
    elif command -v timedatectl &>/dev/null && systemctl status systemd-timesyncd &>/dev/null && [[ "$preferred_ntp_client" == "systemd-timesyncd" || -z "$ntp_client_to_use" ]]; then ntp_client_to_use="systemd-timesyncd"
    elif command -v ntpq &>/dev/null && [[ "$preferred_ntp_client" == "ntp" || -z "$ntp_client_to_use" ]]; then ntp_client_to_use="ntp"
    fi
    
    if [[ -z "$ntp_client_to_use" ]]; then # If no existing preferred client found, try to install preferred
        log "$preferred_ntp_client (preferred) not found. Attempting to install..."
        if run_command "apt-get update -y && apt-get install -y $preferred_ntp_client"; then
            ntp_client_to_use="$preferred_ntp_client"
        else # Fallback installation
            local fallback_install_client="ntp" # A common, simple fallback
            if [[ "$preferred_ntp_client" == "ntp" ]]; then fallback_install_client="chrony"; fi # Avoid re-trying same
            log "Failed to install $preferred_ntp_client. Trying to install $fallback_install_client..."
            if run_command "apt-get update -y && apt-get install -y $fallback_install_client"; then
                ntp_client_to_use="$fallback_install_client"
            else
                log "ERROR: Failed to install any NTP client. Time synchronization is critical."
                return 1
            fi
        fi
    fi
    log "Using NTP client: $ntp_client_to_use"

    # Stop other NTP services if a specific one is chosen
    if [[ "$ntp_client_to_use" == "chrony" ]]; then run_command "systemctl stop systemd-timesyncd ntp" &>/dev/null; run_command "systemctl disable systemd-timesyncd ntp" &>/dev/null
    elif [[ "$ntp_client_to_use" == "systemd-timesyncd" ]]; then run_command "systemctl stop chrony ntp" &>/dev/null; run_command "systemctl disable chrony ntp" &>/dev/null
    elif [[ "$ntp_client_to_use" == "ntp" ]]; then run_command "systemctl stop chrony systemd-timesyncd" &>/dev/null; run_command "systemctl disable chrony systemd-timesyncd" &>/dev/null; fi

    # Configure the chosen client
    if [[ "$ntp_client_to_use" == "chrony" ]]; then
        log "Configuring chrony..."; local chrony_conf="/etc/chrony/chrony.conf"; ensure_file_exists "$chrony_conf"
        { printf "# Generated by sssd_kerberos_setup.sh\ndriftfile /var/lib/chrony/chrony.drift\nmakestep 1.0 3\nrtcsync\nlogdir /var/log/chrony\n"; } > "$chrony_conf"
        if [[ ${#ad_ntp_servers[@]} -gt 0 ]]; then
            log "Using discovered AD NTP servers for chrony (preferred)."
            for server in "${ad_ntp_servers[@]}"; do printf "server %s iburst prefer\n" "$server" >> "$chrony_conf"; done
            # Add fallback pools from config
            for pool_server in "${DEFAULT_NTP_FALLBACK_POOLS_CHRONY_NTP[@]}"; do printf "%s\n" "$pool_server" >> "$chrony_conf"; done
        else
            log "Using configured fallback NTP pools for chrony."
            for pool_server in "${DEFAULT_NTP_FALLBACK_POOLS_CHRONY_NTP[@]}"; do printf "%s prefer\n" "$pool_server" >> "$chrony_conf"; done # Add prefer to first fallback
        fi
        run_command "systemctl restart chrony" && run_command "systemctl enable chrony"; sleep 5 # Allow time for sync
        run_command "chronyc sources"; run_command "chronyc tracking"
    elif [[ "$ntp_client_to_use" == "systemd-timesyncd" ]]; then
        log "Configuring systemd-timesyncd..."; local timesyncd_conf="/etc/systemd/timesyncd.conf"; ensure_file_exists "$timesyncd_conf"
        # Clear existing NTP servers and set new ones from AD discovery or defaults
        sed -i -E '/^#?NTP=/d' "$timesyncd_conf"; sed -i -E '/^#?FallbackNTP=/d' "$timesyncd_conf"
        if [[ ${#ad_ntp_servers[@]} -gt 0 ]]; then
            log "Using discovered AD NTP servers for systemd-timesyncd."
            printf "NTP=%s\n" "${ad_ntp_servers[*]}" >> "$timesyncd_conf" # Space separated
            printf "FallbackNTP=%s\n" "${DEFAULT_NTP_FALLBACK_POOLS_SYSTEMD}" >> "$timesyncd_conf"
        else
            log "Using configured fallback NTP pools for systemd-timesyncd."
            printf "NTP=%s\n" "${DEFAULT_NTP_FALLBACK_POOLS_SYSTEMD}" >> "$timesyncd_conf"
        fi
        run_command "systemctl restart systemd-timesyncd" && run_command "systemctl enable systemd-timesyncd"; sleep 2
        run_command "timedatectl status"; run_command "timedatectl timesync-status --all || timedatectl show-timesync --all || true" # Command varies slightly
    elif [[ "$ntp_client_to_use" == "ntp" ]]; then # ntpd
        log "Configuring ntp (ntpd)..."; local ntp_conf="/etc/ntp.conf"; ensure_file_exists "$ntp_conf"
        { printf "driftfile /var/lib/ntp/ntp.drift\nleapfile /usr/share/zoneinfo/leap-seconds.list\nstatistics loopstats peerstats clockstats\nfilegen loopstats file loopstats type day enable\nfilegen peerstats file peerstats type day enable\nfilegen clockstats file clockstats type day enable\nrestrict -4 default kod notrap nomodify nopeer noquery limited\nrestrict -6 default kod notrap nomodify nopeer noquery limited\nrestrict 127.0.0.1\nrestrict ::1\n"; } > "$ntp_conf"
        if [[ ${#ad_ntp_servers[@]} -gt 0 ]]; then
            log "Using discovered AD NTP servers for ntpd (preferred)."
            for server in "${ad_ntp_servers[@]}"; do printf "server %s iburst prefer\n" "$server" >> "$ntp_conf"; done
            for pool_server in "${DEFAULT_NTP_FALLBACK_POOLS_CHRONY_NTP[@]}"; do printf "%s\n" "$pool_server" >> "$ntp_conf"; done # Using CHRONY_NTP var for format
        else
            log "Using configured fallback NTP pools for ntpd."
            for pool_server in "${DEFAULT_NTP_FALLBACK_POOLS_CHRONY_NTP[@]}"; do printf "%s prefer\n" "$pool_server" >> "$ntp_conf"; done
        fi
        run_command "systemctl restart ntp" && run_command "systemctl enable ntp"; sleep 5
        run_command "ntpq -p"
    fi

    # Final check for time synchronization
    if timedatectl status | grep -i -q "System clock synchronized: yes"; then
        log "System time appears to be synchronized."
        return 0
    else
        log "Warning: System time may not be synchronized. Output of 'timedatectl status':"
        timedatectl status | tee -a "$LOG_FILE" # Log the status for debugging
        log "Kerberos and Active Directory integration are highly sensitive to time differences."
        local confirm_time
        read -r -p "Continue with setup despite potential time sync issues? (y/n): " confirm_time
        if [[ "$confirm_time" != "y" && "$confirm_time" != "Y" ]]; then
            log "Aborting setup due to time sync concerns."
            return 1
        fi
        return 0 # User chose to proceed
    fi
}

# Installs SSSD, Kerberos, and related utility packages.
install_sssd_krb_packages() {
    log "Installing SSSD, Kerberos, and related packages..."
    # NTP client installation is handled by ensure_time_sync
    local -a packages_to_install_list=(
        sssd sssd-tools sssd-ad sssd-krb5 libsss-sudo # Core SSSD for AD
        krb5-user        # Kerberos client utilities (kinit, klist)
        libpam-sss       # PAM module for SSSD authentication
        libnss-sss       # NSS module for SSSD user/group lookups
        realmd           # For easy domain joining
        packagekit       # realmd dependency on some systems
        pamtester        # Utility for testing PAM configurations
    )
    local -a pkgs_actually_needed=() # Array to hold packages not yet installed
    for pkg in "${packages_to_install_list[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then # Check if package is already installed
            pkgs_actually_needed+=("$pkg")
        fi
    done

    if [[ ${#pkgs_actually_needed[@]} -gt 0 ]]; then
        run_command "apt-get update -y" || return 1
        # DEBIAN_FRONTEND=noninteractive to prevent prompts during install
        run_command "DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs_actually_needed[*]}" || return 1
        log "Required SSSD/Kerberos packages installed/verified: ${pkgs_actually_needed[*]}"
    else
        log "All required SSSD/Kerberos packages are already installed."
    fi
    return 0
}

# Joins the machine to an Active Directory domain using 'realm join'.
# Prompts for necessary credentials and parameters, using defaults from config.
join_ad_domain_realm() {
    log "Attempting to join Active Directory domain using 'realm join'..."
    
    local ad_domain_lower_input ad_admin_user_input computer_ou_custom_part_input os_name_input
    read -r -p "Enter AD Domain (lowercase) [default: ${DEFAULT_AD_DOMAIN_LOWER}]: " ad_domain_lower_input
    AD_DOMAIN_LOWER=${ad_domain_lower_input:-$DEFAULT_AD_DOMAIN_LOWER} # Set global for this session
    AD_DOMAIN_UPPER=$(echo "$AD_DOMAIN_LOWER" | tr '[:lower:]' '[:upper:]') # Set global for this session

    read -r -p "Enter AD admin UPN for domain join (e.g., ${DEFAULT_AD_ADMIN_USER_EXAMPLE}): " ad_admin_user_input
    AD_ADMIN_USER=${ad_admin_user_input} # Set global
    if [[ -z "$AD_ADMIN_USER" ]]; then log "ERROR: AD Admin User UPN cannot be empty."; return 1; fi

    read -r -p "Enter customizable part of Computer OU (e.g., ServerFarm_Navile) [default: ${DEFAULT_COMPUTER_OU_CUSTOM_PART}]: " computer_ou_custom_part_input
    local computer_ou_custom_part=${computer_ou_custom_part_input:-$DEFAULT_COMPUTER_OU_CUSTOM_PART}
    # Construct the full OU path, customizable part first
    FULL_COMPUTER_OU="${computer_ou_custom_part},${DEFAULT_COMPUTER_OU_BASE}" # Set global

    read -r -p "Enter OS Name for AD object [default: ${DEFAULT_OS_NAME}]: " os_name_input
    OS_NAME=${os_name_input:-$DEFAULT_OS_NAME} # Set global

    log "Attempting domain join with parameters:"
    log "  Domain: $AD_DOMAIN_LOWER"
    log "  Admin UPN: $AD_ADMIN_USER"
    log "  Target Computer OU: $FULL_COMPUTER_OU"
    log "  OS Name attribute: $OS_NAME"

    log "Discovering domain $AD_DOMAIN_LOWER..."
    if ! run_command "realm discover \"$AD_DOMAIN_LOWER\""; then
        log "ERROR: Domain $AD_DOMAIN_LOWER not discoverable. Check DNS, network connectivity, and domain name spelling."
        return 1
    fi

    log "Joining domain $AD_DOMAIN_LOWER (this may prompt for password for $AD_ADMIN_USER)..."
    # Construct the realm join command
    local realm_join_cmd="realm join --verbose -U \"$AD_ADMIN_USER@$AD_DOMAIN_UPPER\" --computer-ou=\"$FULL_COMPUTER_OU\" --os-name=\"$OS_NAME\" \"$AD_DOMAIN_LOWER\""
    
    if run_command "$realm_join_cmd"; then
        log "Successfully joined domain $AD_DOMAIN_LOWER using 'realm join'."
        # realm join should configure sssd.conf, krb5.conf, and PAM.
    else
        log "ERROR: 'realm join' failed. Command executed: $realm_join_cmd"
        log "Please check /var/log/auth.log, journalctl -u realmd -u sssd, and SSSD/realmd specific logs."
        log "Common issues: incorrect admin credentials, insufficient permissions in AD for the admin user to join computers to the specified OU, DNS resolution problems, time synchronization issues with AD domain controllers, or incorrect OU path format."
        return 1
    fi
    return 0
}

# Generates the content for sssd.conf by processing the template file.
# Prompts for user-specific values, using defaults from config.
generate_sssd_conf_from_template() {
    log "Gathering information for sssd.conf from template..."
    if [[ ! -f "$SSSD_CONF_TEMPLATE_PATH" ]]; then
        log "ERROR: SSSD template file not found at $SSSD_CONF_TEMPLATE_PATH"
	GENERATED_SSSD_CONF="" # Ensure it's empty on error
        return 1
    fi

    # Ensure AD_DOMAIN_LOWER/UPPER are set (prompt if not, using defaults from sourced vars)
    # These might have been set by join_ad_domain_realm if run prior.
    if [[ -z "${AD_DOMAIN_LOWER}" ]] || [[ -z "${AD_DOMAIN_UPPER}" ]]; then
        local ad_domain_lower_conf_input
        read -r -p "Enter AD Domain (lowercase) for sssd.conf [default: ${DEFAULT_AD_DOMAIN_LOWER}]: " ad_domain_lower_conf_input
        AD_DOMAIN_LOWER=${ad_domain_lower_conf_input:-$DEFAULT_AD_DOMAIN_LOWER} # Update global
        AD_DOMAIN_UPPER=$(echo "$AD_DOMAIN_LOWER" | tr '[:lower:]' '[:upper:]') # Update global
    fi
    
    # Use global vars if set, otherwise prompt using defaults from .vars.conf
    local fallback_homedir_template_input use_fqns_input simple_allow_groups_input ad_gpo_map_service_input
    read -r -p "Enter fallback_homedir template [default: ${DEFAULT_FALLBACK_HOMEDIR_TEMPLATE}]: " fallback_homedir_template_input
    FALLBACK_HOMEDIR_TEMPLATE="${fallback_homedir_template_input:-$DEFAULT_FALLBACK_HOMEDIR_TEMPLATE}" # Update global
    read -r -p "Use fully qualified names for login (e.g. user@domain)? (true/false) [default: ${DEFAULT_USE_FQNS}]: " use_fqns_input
    USE_FQNS="${use_fqns_input:-$DEFAULT_USE_FQNS}" # Update global
    read -r -p "Enter comma-separated AD groups to allow login (blank for no restriction by this setting) [default: '${DEFAULT_SIMPLE_ALLOW_GROUPS}']: " simple_allow_groups_input
    SIMPLE_ALLOW_GROUPS="${simple_allow_groups_input:-$DEFAULT_SIMPLE_ALLOW_GROUPS}" # Update global
    read -r -p "Enter GPO service mapping for RStudio (e.g., +rstudio, or blank to disable) [default: '${DEFAULT_AD_GPO_MAP_SERVICE}']: " ad_gpo_map_service_input
    AD_GPO_MAP_SERVICE_CONFIG="${ad_gpo_map_service_input:-$DEFAULT_AD_GPO_MAP_SERVICE}" # Update global
    
    local client_hostname; client_hostname=$(hostname -f 2>/dev/null || hostname)

    log "--- SSSD Configuration Summary (from template + inputs) ---"
    log "Template File Used: $SSSD_CONF_TEMPLATE_PATH"
    log "AD Domain (lower): $AD_DOMAIN_LOWER"
    log "Kerberos Realm (UPPER): $AD_DOMAIN_UPPER"
    log "Fallback Home Directory Template: $FALLBACK_HOMEDIR_TEMPLATE"
    log "Use Fully Qualified Names: $USE_FQNS"
    log "Allowed AD Groups (simple_allow_groups): ${SIMPLE_ALLOW_GROUPS:-All users (if no other restrictions by this setting)}"
    log "Client Hostname (for ad_hostname): $client_hostname"
    log "GPO Map Service for RStudio: ${AD_GPO_MAP_SERVICE_CONFIG:-Not set}"
    log "---"
    
    local simple_allow_groups_line_val="#simple_allow_groups = " # Default to commented out
    if [[ -n "$SIMPLE_ALLOW_GROUPS" ]]; then
        simple_allow_groups_line_val="simple_allow_groups = $SIMPLE_ALLOW_GROUPS"
    fi

    local ad_gpo_map_service_line_val="#ad_gpo_map_service = " # Default to commented out
    if [[ -n "$AD_GPO_MAP_SERVICE_CONFIG" ]]; then
        ad_gpo_map_service_line_val="ad_gpo_map_service = $AD_GPO_MAP_SERVICE_CONFIG"
    fi

    # Call the corrected process_template function from common_utils.sh
    # The output variable is GENERATED_SSSD_CONF (global in this script)
    if ! process_template "$SSSD_CONF_TEMPLATE_PATH" "GENERATED_SSSD_CONF" \
        "AD_DOMAIN_LOWER=$AD_DOMAIN_LOWER" \
        "AD_DOMAIN_UPPER=$AD_DOMAIN_UPPER" \
        "FALLBACK_HOMEDIR_TEMPLATE=$FALLBACK_HOMEDIR_TEMPLATE" \
        "USE_FQNS=$USE_FQNS" \
        "CLIENT_HOSTNAME=$client_hostname" \
        "SIMPLE_ALLOW_GROUPS_LINE=$simple_allow_groups_line_val" \
        "AD_GPO_MAP_SERVICE_LINE=$ad_gpo_map_service_line_val"; then
        log "ERROR: Failed to process SSSD template file '$SSSD_CONF_TEMPLATE_PATH'."
        GENERATED_SSSD_CONF="" # Ensure it's empty on error
        return 1
    fi
    
    if [[ -z "$GENERATED_SSSD_CONF" ]]; then
        log "ERROR: Processed SSSD configuration is empty."
        return 1
    fi

    return 0
}



   
# Writes the generated SSSD configuration to /etc/sssd/sssd.conf.
configure_sssd_conf() {
    log "Configuring /etc/sssd/sssd.conf from template..."
    # generate_sssd_conf_from_template now populates the global GENERATED_SSSD_CONF
    if ! generate_sssd_conf_from_template; then
        log "ERROR: Failed to generate sssd.conf content from template. Aborting sssd.conf configuration."
        return 1
    fi

	
    local sssd_conf_target="/etc/sssd/sssd.conf"
    ensure_dir_exists "$(dirname "$sssd_conf_target")" # Ensure /etc/sssd exists

    log "Writing generated configuration to $sssd_conf_target"
    # Backup existing sssd.conf before overwriting
    if [[ -f "$sssd_conf_target" ]]; then
        run_command "cp \"$sssd_conf_target\" \"${sssd_conf_target}.bak_pre_script_$(date +%Y%m%d_%H%M%S)\""
    fi
    
    # Write the content. Using printf is safer for complex strings.
    if ! printf "%s\n" "$GENERATED_SSSD_CONF" > "$sssd_conf_target"; then
        log "ERROR: Failed to write generated SSSD configuration to $sssd_conf_target"
        return 1
    fi

    # Set correct permissions for sssd.conf
    if ! run_command "chmod 0600 $sssd_conf_target"; then
        # SSSD might refuse to start if permissions are too open.
        log "Warning: Failed to set permissions (0600) on $sssd_conf_target. SSSD might not start."
    fi
    log "$sssd_conf_target configured successfully from template. Content:"
    run_command "cat $sssd_conf_target" # Log the final content for review
    return 0
}

# Configures basic /etc/krb5.conf settings.
# Relies on 'realm join' or SSSD for detailed KDC/admin server discovery via DNS.
configure_krb5_conf() {
    log "Ensuring basic Kerberos configuration in /etc/krb5.conf..."
    local krb5_conf_target="/etc/krb5.conf"
    ensure_file_exists "$krb5_conf_target" || return 1 # Creates if not exists

    # Ensure AD_DOMAIN_UPPER is set (it should be if join or sssd_conf generation ran)
    if [[ -z "$AD_DOMAIN_UPPER" ]]; then
        local ad_domain_upper_krb_input
        read -r -p "Enter AD Kerberos Realm (UPPERCASE) for krb5.conf [default: ${DEFAULT_AD_DOMAIN_UPPER}]: " ad_domain_upper_krb_input
        AD_DOMAIN_UPPER=${ad_domain_upper_krb_input:-$DEFAULT_AD_DOMAIN_UPPER} # Update global
    fi
    
    # Ensure [libdefaults] section exists
    if ! grep -q "\[libdefaults\]" "$krb5_conf_target"; then
        printf "\n[libdefaults]\n" >> "$krb5_conf_target"
    fi
    
    # Set default_realm under [libdefaults]
    if ! grep -q "default_realm[[:space:]]*=" "$krb5_conf_target"; then
        # Add default_realm line
        run_command "sed -i '/\\[libdefaults\\]/a \ \ default_realm = ${AD_DOMAIN_UPPER}' '${krb5_conf_target}'"
    else
        # Update existing default_realm line
        run_command "sed -i 's/^[[:space:]]*default_realm[[:space:]]*=.*$/  default_realm = ${AD_DOMAIN_UPPER}/' '${krb5_conf_target}'"
    fi
    
    # Ensure default_ccache_name is set for user sessions
    local default_ccache_line="default_ccache_name = FILE:/tmp/krb5cc_%{uid}"
    if ! grep -q "default_ccache_name[[:space:]]*=" "$krb5_conf_target"; then
        run_command "sed -i '/\\[libdefaults\\]/a \ \ ${default_ccache_line}' '${krb5_conf_target}'"
    else
        # Optional: update if different, but usually this line is standard
        run_command "sed -i 's|^[[:space:]]*default_ccache_name[[:space:]]*=.*$|  ${default_ccache_line}|' '${krb5_conf_target}'"
    fi

    log "${krb5_conf_target} updated. Relying on 'realm join' or SSSD for KDC/admin server discovery. Content:"
    run_command "cat ${krb5_conf_target}"
    return 0
}

# Configures /etc/nsswitch.conf to use SSSD for user/group lookups.
configure_nsswitch() {
    log "Checking and configuring /etc/nsswitch.conf for SSSD..."
    local nss_conf_target="/etc/nsswitch.conf"
    ensure_file_exists "$nss_conf_target" || return 1

    local -a nss_databases=("passwd" "group" "shadow" "sudoers") # sudoers if using sssd-sudo
    local entry_modified_overall=0 # Flag to see if any changes were made

    for entry in "${nss_databases[@]}"; do
        local current_line current_entry_config
        current_line=$(grep "^${entry}:" "$nss_conf_target")

        if [[ -z "$current_line" ]]; then # Entry does not exist
            log "Entry '${entry}:' not found in $nss_conf_target. Adding '${entry}: files sss'."
            add_line_if_not_present "${entry}: files sss" "$nss_conf_target"
            entry_modified_overall=1
        else # Entry exists
            if [[ "$current_line" != *sss* ]]; then # 'sss' not present in the line
                log "Entry '${entry}:' found but 'sss' is missing. Attempting to add 'sss'."
                # Try to insert 'sss' after 'files', otherwise append 'sss'
                # Using awk for more robust modification
                local temp_nss_conf; temp_nss_conf=$(mktemp) || { log "ERROR: mktemp failed for nsswitch edit."; return 1; }
                awk -v entry_to_modify="$entry" '
                $1 == entry_to_modify":" {
                    if (index($0, " sss") == 0 && $0 !~ /sss$/) { # sss not found
                        if (sub(/files/, "files sss")) {
                            # successfully inserted "sss" after "files"
                        } else {
                            # "files" not found on the line, or other format, append " sss"
                            $0 = $0 " sss"
                        }
                    }
                }
                { print }
                ' "$nss_conf_target" > "$temp_nss_conf"
                
                if [[ -s "$temp_nss_conf" ]]; then
                    run_command "cp \"$temp_nss_conf\" \"$nss_conf_target\""
                    entry_modified_overall=1
                else
                    log "ERROR: awk processing for $nss_conf_target failed for entry '$entry'."
                fi
                rm -f "$temp_nss_conf"
            else
                log "'sss' already configured for '${entry}:' in $nss_conf_target."
            fi
        fi
    done

    if [[ "$entry_modified_overall" -eq 1 ]]; then
        log "$nss_conf_target modified. Final content:"
        run_command "cat $nss_conf_target"
    else
        log "$nss_conf_target already correctly configured for SSSD, or no changes made."
    fi
    return 0
}

# Configures PAM to use SSSD, typically via pam-auth-update.
configure_pam() {
    log "Checking and configuring PAM for SSSD authentication and session management..."
    # 'realm join' often handles basic PAM setup. This ensures SSSD modules are active.
    if command -v pam-auth-update &>/dev/null; then
        log "Running pam-auth-update to ensure SSS (authentication, account, password, session) and mkhomedir (session) modules are enabled..."
        # --enable tries to add if not present, --force can be used but is more intrusive.
        # This command is idempotent.
        if ! run_command "DEBIAN_FRONTEND=noninteractive pam-auth-update --enable sss --enable mkhomedir"; then
            log "Warning: pam-auth-update command failed or had issues. Manual PAM review might be needed in /etc/pam.d/common-* files."
        else
            log "pam-auth-update completed. SSS and mkhomedir modules should be enabled in system PAM profiles."
        fi
    else
        log "Warning: pam-auth-update command not found. Manual PAM configuration is required if 'realm join' didn't suffice."
        log "Ensure 'pam_sss.so' is included in /etc/pam.d/common-auth, common-account, common-password, common-session."
        log "Ensure 'pam_mkhomedir.so' is included in /etc/pam.d/common-session for automatic home directory creation on first login."
    fi

    # Check RStudio specific PAM file, if it exists.
    local rstudio_pam_file="/etc/pam.d/rstudio"
    if [[ -f "$rstudio_pam_file" ]]; then
        log "RStudio PAM file ($rstudio_pam_file) exists. Content:"
        run_command "cat $rstudio_pam_file"
        # Check if it includes common PAM stacks or pam_sss.so directly
        if ! grep -q -e "pam_sss.so" -e "common-auth" -e "common-account" -e "system-auth" "$rstudio_pam_file"; then
             log "Warning: $rstudio_pam_file does not seem to include pam_sss.so or a common PAM stack that would use SSSD. RStudio authentication might fail for domain users."
             log "Consider ensuring it includes lines like '@include common-auth', '@include common-account', etc."
        fi
    else
        log "RStudio PAM file ($rstudio_pam_file) not found. RStudio will likely use the system's default PAM stack (e.g., from /etc/pam.d/other or common-*)."
        log "This is often sufficient if SSSD is correctly integrated into common-* PAM files."
    fi
    return 0
}

# Restarts SSSD service and verifies it's active. Clears SSSD cache.
restart_and_verify_sssd() {
    log "Restarting SSSD service..."
    run_command "systemctl daemon-reload" # In case SSSD unit files were changed by package updates
    if ! run_command "systemctl restart sssd"; then
        log "ERROR: Failed to restart SSSD. Check 'journalctl -u sssd' and SSSD logs in /var/log/sssd/ for errors."
        return 1
    fi
    if ! run_command "systemctl is-active --quiet sssd"; then
        log "ERROR: SSSD service is not active after restart. Check 'journalctl -u sssd'."
        return 1
    fi
    run_command "systemctl enable sssd" # Ensure it's enabled to start on boot
    log "SSSD service restarted and is active."
    
    log "Clearing SSSD cache to ensure fresh lookups after configuration changes..."
    # sss_cache can sometimes be slow or hang if SSSD is struggling.
    # Adding a timeout might be useful for automation, but for interactive script, this is okay.
    if ! run_command "sss_cache -E"; then
        log "Warning: 'sss_cache -E' failed. SSSD cache might not be fully cleared. This can happen if SSSD is still initializing or having issues."
    fi
    return 0
}

# Tests Kerberos ticket acquisition for a given user.
test_kerberos_ticket() {
    log "Testing Kerberos ticket acquisition (kinit)..."
    # Use AD_DOMAIN_UPPER if set (e.g. after join/config), else default from config
    local test_user_kinit_default_example="user@${AD_DOMAIN_UPPER:-$DEFAULT_AD_DOMAIN_UPPER}"
    local test_user
    read -r -p "Enter an AD User Principal Name (UPN) to test kinit [e.g., ${test_user_kinit_default_example}]: " test_user
    if [[ -z "$test_user" ]]; then
        log "No user UPN entered. Skipping kinit test."
        return 0
    fi

    log "Attempting kinit for $test_user. You will be prompted for the user's AD password."
    # kinit will prompt for password interactively.
    if run_command "kinit \"$test_user\""; then
        log "kinit successful for $test_user."
        run_command "klist"    # Display the obtained ticket
        run_command "kdestroy" # Clean up by destroying the ticket from cache
    else
        log "ERROR: kinit failed for $test_user."
        log "Check /etc/krb5.conf, DNS resolution of KDCs, time synchronization with AD, and the provided credentials."
        return 1
    fi
    return 0
}

# Tests SSSD's ability to look up user information.
test_user_lookup() {
    log "Testing user information lookup via SSSD (getent, id)..."
    # Determine example username based on use_fully_qualified_names setting
    local use_fqn_effective="${USE_FQNS:-$DEFAULT_USE_FQNS}" # Get the FQN setting that was likely used for sssd.conf
    local test_user_lookup_example="ad_username" # Generic shortname
    if [[ "$use_fqn_effective" == "true" ]]; then
        test_user_lookup_example="ad_username@${AD_DOMAIN_LOWER:-$DEFAULT_AD_DOMAIN_LOWER}"
    fi

    local test_user
    read -r -p "Enter an AD username to test (format depends on use_fully_qualified_names) [e.g., ${test_user_lookup_example}]: " test_user
    if [[ -z "$test_user" ]]; then
        log "No username entered. Skipping user lookup test."
        return 0
    fi

    log "Testing 'getent passwd $test_user'..."
    if ! run_command "getent passwd \"$test_user\""; then
        log "ERROR: 'getent passwd $test_user' failed. SSSD or /etc/nsswitch.conf might be misconfigured."
        log "Check SSSD logs and ensure SSSD is running and connected to AD."
        return 1
    fi
    log "'getent passwd $test_user' successful."

    log "Testing 'id $test_user'..."
    if ! run_command "id \"$test_user\""; then
        log "ERROR: 'id $test_user' failed. This usually indicates issues similar to getent."
        return 1
    fi
    log "'id $test_user' successful. User and group information retrieved via SSSD."
    return 0
}

# Tests RStudio's PAM stack integration with SSSD for a given user.
test_rstudio_pam_integration() {
    log "Testing RStudio PAM integration with SSSD using pamtester..."
    if ! command -v pamtester &>/dev/null; then
        log "pamtester utility not found. Please install it (often in 'libpam-чки' or 'pamtester' package) or run package installation from menu."
        return 1
    fi

    local use_fqn_effective="${USE_FQNS:-$DEFAULT_USE_FQNS}"
    local test_user_pam_example="ad_username"
     if [[ "$use_fqn_effective" == "true" ]]; then
        test_user_pam_example="ad_username@${AD_DOMAIN_LOWER:-$DEFAULT_AD_DOMAIN_LOWER}"
    fi

    local test_user_pam
    read -r -p "Enter AD username for RStudio PAM test [e.g., ${test_user_pam_example}]: " test_user_pam
    if [[ -z "$test_user_pam" ]]; then
        log "No username entered. Skipping RStudio PAM test."
        return 0
    fi

    log "Testing PAM for RStudio service (pam service name 'rstudio') with user '$test_user_pam'."
    log "You will be prompted for the user's AD password."
    # pamtester arguments: <PAM service name> <username> <PAM primitive to test>
    if run_command "pamtester --verbose rstudio \"$test_user_pam\" authenticate acct_mgmt"; then
        log "RStudio PAM test SUCCEEDED for $test_user_pam."
        log "This indicates that authentication (authenticate) and account validity (acct_mgmt) checks passed for the 'rstudio' PAM service name."
    else
        log "RStudio PAM test FAILED for $test_user_pam."
        log "Check /etc/pam.d/rstudio (if it exists), /etc/pam.d/common-*, SSSD logs, and RStudio Server logs if login issues persist."
        return 1
    fi
    return 0
}

# Attempts to uninstall SSSD/Kerberos configuration and packages.
uninstall_sssd_kerberos() {
    log "Starting SSSD/Kerberos Uninstallation Process..."
    # Backup current state before attempting to uninstall. The backup will be of the SSSD-configured state.
    backup_config 

    local confirm_uninstall
    read -r -p "This will attempt to leave the domain, remove packages, and clean configurations. This can be disruptive. Are you sure? (y/n): " confirm_uninstall
    if [[ "$confirm_uninstall" != "y" && "$confirm_uninstall" != "Y" ]]; then
        log "Uninstallation cancelled by user."
        return 0
    fi

    # 1. Attempt to leave the domain using 'realm leave'
    # Try to determine the current domain if AD_DOMAIN_LOWER is not set from a previous operation
    local current_domain_to_leave="${AD_DOMAIN_LOWER}"
    if [[ -z "$current_domain_to_leave" ]]; then
        if command -v realm &>/dev/null && realm list --name-only --configured=yes &>/dev/null; then
            # Get the first configured realm. Multiple realms are not handled robustly here.
            current_domain_to_leave=$(realm list --name-only --configured=yes | head -n 1)
        elif [[ -f "/etc/sssd/sssd.conf" ]] && grep -q "^domains[[:space:]]*=" /etc/sssd/sssd.conf; then
            # Fallback to sssd.conf if realm command fails or shows nothing
            current_domain_to_leave=$(grep "^domains[[:space:]]*=" /etc/sssd/sssd.conf | awk -F'=' '{print $2}' | awk '{$1=$1;print}') # Trim spaces
        fi
    fi

    if [[ -n "$current_domain_to_leave" ]]; then
        log "Attempting to leave domain: $current_domain_to_leave"
        local leave_user_upn
        read -r -p "Enter AD admin UPN for domain leave (e.g., ${DEFAULT_AD_ADMIN_USER_EXAMPLE}, or leave blank for unauthenticated leave attempt): " leave_user_upn
        
        local leave_cmd="realm leave \"$current_domain_to_leave\""
        if [[ -n "$leave_user_upn" ]]; then
            leave_cmd="realm leave -U \"$leave_user_upn\" \"$current_domain_to_leave\""
            log "Will prompt for password for $leave_user_upn."
        fi
        
        if run_command "$leave_cmd"; then
            log "Successfully left domain $current_domain_to_leave (or was not joined)."
        else
            log "Warning: Failed to leave domain $current_domain_to_leave. It might not have been joined, or credentials were required/incorrect, or computer object was already removed from AD."
            log "Command attempted: $leave_cmd"
        fi
    else
        log "Could not automatically determine current domain to leave. Skipping 'realm leave' step."
        log "If joined to a domain, you might need to leave it manually or remove the computer object from AD."
    fi

    # 2. Stop related services
    log "Stopping SSSD and potentially related NTP services..."
    run_command "systemctl stop sssd chrony ntp systemd-timesyncd" &>/dev/null # Best effort, ignore errors if services not installed
    run_command "systemctl disable sssd chrony ntp systemd-timesyncd" &>/dev/null

    # 3. Remove packages
    log "Removing SSSD, Kerberos, and related packages..."
    local -a packages_to_remove=(
        sssd sssd-tools sssd-ad sssd-krb5 # Core SSSD
        krb5-user libpam-sss libnss-sss   # Kerberos client, PAM/NSS modules
        realmd packagekit                 # Domain joining tools (packagekit is a common dep)
        chrony ntp                        # NTP clients this script might have installed
        pamtester                         # Testing utility
    )
    local -a actually_installed_for_removal=()
    for pkg in "${packages_to_remove[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then # Check if package is actually installed
            actually_installed_for_removal+=("$pkg")
        fi
    done
    if [[ ${#actually_installed_for_removal[@]} -gt 0 ]]; then
        # Use --purge to remove configuration files associated with packages
        run_command "apt-get remove --purge -y ${actually_installed_for_removal[*]}"
        run_command "apt-get autoremove -y" # Remove automatically installed dependencies no longer needed
        log "Packages removed (with --purge): ${actually_installed_for_removal[*]}"
    else
        log "No SSSD/Kerberos specific packages (from the list) found to remove."
    fi

    # 4. Clean/Revert configuration files manually (those not handled by package purge)
    log "Cleaning up remaining configuration files..."
    # sssd.conf should be removed by "apt-get purge sssd", but to be sure:
    run_command "rm -f /etc/sssd/sssd.conf"
    run_command "rm -rf /etc/sssd/conf.d/" # Remove sssd conf.d directory
    run_command "rm -f /etc/sssd/sssd.conf.bak_pre_script_*" # Clean our own backups for this file
    # krb5.conf should also be removed by "apt-get purge krb5-user"
    run_command "rm -f /etc/krb5.conf"
    run_command "rm -f /etc/krb5.conf.bak_pre_script_*" # If we made one

    # Revert nsswitch.conf (best effort: remove 'sss' entries)
    local nss_conf_target="/etc/nsswitch.conf"
    if [[ -f "$nss_conf_target" ]]; then
        log "Attempting to remove 'sss' entries from $nss_conf_target..."
        run_command "cp \"$nss_conf_target\" \"${nss_conf_target}.bak_pre_sss_removal_$(date +%Y%m%d_%H%M%S)\""
        # This sed command tries to remove 'sss' and any preceding/succeeding space.
        # It handles 'files sss', 'sss files', or just 'sss' on a line by itself for the service.
        run_command "sed -i -E -e 's/[[:space:]]+sss\b//g' -e 's/\bsss[[:space:]]+//g' -e 's/^\bsss\b//g' \"$nss_conf_target\""
        log "$nss_conf_target after attempting to remove 'sss':"
        run_command "cat $nss_conf_target"
    fi

    # Revert PAM (best effort: use pam-auth-update to disable sss modules)
    if command -v pam-auth-update &>/dev/null; then
        log "Attempting to disable SSS and mkhomedir modules via pam-auth-update..."
        if ! run_command "DEBIAN_FRONTEND=noninteractive pam-auth-update --remove sss --remove mkhomedir"; then
             log "Warning: pam-auth-update --remove had issues. PAM config in /etc/pam.d/common-* might need manual review."
        else
             log "pam-auth-update --remove completed successfully."
        fi
        # RStudio specific PAM file (/etc/pam.d/rstudio)
        # If this file was created SOLELY for SSSD, it could be removed.
        # However, it might contain other custom PAM settings.
        # It's safer to leave it and advise manual review.
        if [[ -f "/etc/pam.d/rstudio" ]]; then
            log "Note: /etc/pam.d/rstudio was NOT automatically removed. Please review if it's still needed or should revert to a default."
        fi
    else
        log "pam-auth-update command not found. Manual PAM cleanup in /etc/pam.d/common-* files is needed if SSSD was configured."
    fi
    
    # Clear SSSD cache files and logs (package purge should handle most of /var/lib/sss)
    run_command "rm -rf /var/lib/sss/*" # Cache, pipes, db
    run_command "rm -rf /var/log/sssd/*" # SSSD's own log files

    log "SSSD/Kerberos uninstallation attempt completed."
    log "A backup of the configuration *before* this uninstall was made in $CURRENT_BACKUP_DIR (if script was run in same session)."
    log "Review system logs and test local logins. A system reboot might be advisable to ensure all changes take effect."
}

# Executes the full SSSD/Kerberos setup sequence.
full_sssd_kerberos_setup() {
    backup_config # Backup before starting
    # Chain commands with && to stop on first failure
    ensure_time_sync && \
    install_sssd_krb_packages && \
    join_ad_domain_realm && \
    configure_sssd_conf && \ # This will call generate_sssd_conf_from_template
    configure_krb5_conf && \
    configure_nsswitch && \
    configure_pam && \
    restart_and_verify_sssd && \
    log "Core SSSD/Kerberos setup process completed successfully. Proceed to testing options." || {
        log "ERROR: Core SSSD/Kerberos setup process failed at one of the steps. Please review logs."
        return 1 # Indicate failure
    }
}

# Main menu for SSSD/Kerberos setup operations.
main_sssd_kerberos_menu() {
    # Ensure backup directory is initialized for this script session,
    # especially if this menu is entered directly or script is re-run.
    setup_backup_dir 

    while true; do
        printf "\n===== SSSD/Kerberos (AD Integration) Setup Menu =====\n"
        printf "1. Full SSSD/Kerberos Setup (Time Sync, Pkgs, Join, Config, Test)\n"
        printf -- "---------------------- Individual Steps ---------------------\n"
        printf "T. Ensure Time Synchronization (Chrony/NTP)\n"
        printf "2. Install SSSD/Kerberos Packages\n"
        printf "3. Join AD Domain (interactive 'realm join')\n"
        printf "4. Generate and Configure sssd.conf (from template '%s')\n" "$SSSD_CONF_TEMPLATE_PATH"
        printf "5. Configure krb5.conf (basics, relies on realm join for KDCs)\n"
        printf "6. Configure nsswitch.conf for SSSD\n"
        printf "7. Configure PAM for SSSD (using pam-auth-update)\n"
        printf "8. Restart and Verify SSSD Service (includes cache clear)\n"
        printf -- "------------------------- Tests -------------------------\n"
        printf "9. Test Kerberos Ticket Acquisition (kinit)\n"
        printf "10. Test User Information Lookup (getent, id)\n"
        printf "11. Test RStudio PAM Integration (pamtester for 'rstudio' service)\n"
        printf -- "----------------------- Maintenance ---------------------\n"
        printf "U. Uninstall SSSD/Kerberos Configuration (Leave Domain, Remove Pkgs, Clean Files)\n"
        printf "V. View current generated sssd.conf (based on current inputs/template, without applying)\n"
        printf "R. Restore All Configurations from Last Backup\n"
        printf "E. Exit SSSD/Kerberos Setup\n"
        printf "=======================================================\n"
        read -r -p "Enter choice: " choice

        case $choice in
            1) full_sssd_kerberos_setup ;;
            T|t) backup_config && ensure_time_sync ;; # Backup before time sync changes too
            2) backup_config && install_sssd_krb_packages ;;
            3) # Joining domain implies prior steps should be good, or done first
                backup_config && ensure_time_sync && install_sssd_krb_packages && \
                join_ad_domain_realm && configure_krb5_conf && restart_and_verify_sssd ;;
            4) backup_config && configure_sssd_conf && restart_and_verify_sssd ;; # configure_sssd_conf calls generate
            5) backup_config && configure_krb5_conf && restart_and_verify_sssd ;;
            6) backup_config && configure_nsswitch && restart_and_verify_sssd ;;
            7) backup_config && configure_pam && restart_and_verify_sssd ;; # SSSD restart often good after PAM changes
            8) restart_and_verify_sssd ;; # No backup needed for just restart/verify
            9) test_kerberos_ticket ;;    # Tests don't change config, no backup
            10) test_user_lookup ;;
            11) test_rstudio_pam_integration ;;
            U|u) uninstall_sssd_kerberos ;; # backup_config is called within uninstall
            V|v)
                # Generate (or re-generate) the sssd.conf content without applying it
                if generate_sssd_conf_from_template; then
                    if [[ -n "$GENERATED_SSSD_CONF" ]]; then
                        printf -- "\n--- Generated sssd.conf Template Preview (not yet applied) ---\n"
                        printf "%s\n" "$GENERATED_SSSD_CONF"
                        printf -- "---------------------------------------------------------------\n"
                    else
                        log "SSSD configuration content is empty after template generation attempt."
                    fi
                else
                    log "ERROR: Failed to generate sssd.conf preview from template."
                fi
                ;;
            R|r) restore_config ;;
            E|e) log "Exiting SSSD/Kerberos Setup."; break ;;
            *) printf "Invalid choice. Please try again.\n" ;;
        esac
        # Pause for user unless exiting
        if [[ "$choice" != "e" && "$choice" != "E" ]]; then
            read -r -p "Press Enter to continue..."
        fi
    done
}

# --- Script Entry Point ---
log "=== SSSD/Kerberos Setup Script Started ==="
# SCRIPT_DIR is defined at the top, available for common_utils.sh backup function
main_sssd_kerberos_menu # This calls setup_backup_dir internally now.
log "=== SSSD/Kerberos Setup Script Finished ==="
