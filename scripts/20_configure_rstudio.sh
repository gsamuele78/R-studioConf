#!/bin/bash
# rstudio_setup.sh - RStudio Server Configuration Script
# This script automates the setup and configuration of RStudio Server,
# including directory structures, user-specific settings, and global configurations.
# It sources common utilities and a dedicated configuration file.

# Determine the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Define paths relative to SCRIPT_DIR
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"
# Resolve SSSD/Kerberos script path (support numeric prefix like 00_...)
SSSD_KERBEROS_SCRIPT_PATH="$(ls "${SCRIPT_DIR}"/*sssd*setup.sh 2>/dev/null | head -n1 || true)"
SSSD_KERBEROS_SCRIPT_PATH="${SSSD_KERBEROS_SCRIPT_PATH:-${SCRIPT_DIR}/10_join_domain_sssd.sh}"
# Resolve Samba/Winbind script path
SAMBA_KERBEROS_SCRIPT_PATH="$(ls "${SCRIPT_DIR}"/*samba*setup.sh 2>/dev/null | head -n1 || true)"
SAMBA_KERBEROS_SCRIPT_PATH="${SAMBA_KERBEROS_SCRIPT_PATH:-${SCRIPT_DIR}/11_join_domain_samba.sh}"
# Configuration files
CONF_VARS_FILE="${SCRIPT_DIR}/../config/configure_rstudio.vars.conf"
SSSD_CONF_VARS_FILE="${SCRIPT_DIR}/../config/join_domain_sssd.vars.conf"
SAMBA_CONF_VARS_FILE="${SCRIPT_DIR}/../config/join_domain_samba.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates" # Used by _get_template_content

# Source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    printf "Error: common_utils.sh not found at %s\n" "$UTILS_SCRIPT_PATH" >&2
    exit 1
fi
# shellcheck source=common_utils.sh # Inform ShellCheck about sourcing
source "$UTILS_SCRIPT_PATH"

# Source configuration variables if file exists
if [[ -f "$CONF_VARS_FILE" ]]; then
    log "Sourcing RStudio configuration variables from $CONF_VARS_FILE"
    # shellcheck source=conf/rstudio_setup.vars.conf
    source "$CONF_VARS_FILE"
else
    log "Warning: RStudio configuration file $CONF_VARS_FILE not found. Using internal defaults."
    # Define crucial defaults here if the conf file is optional or might be missing
    R_PROJECTS_ROOT="/media/r_projects"
    USER_LOGIN_LOG_ROOT="/var/log/rstudio/users"
    GLOBAL_RSTUDIO_TMP_DIR="/media/tmp"
    RSTUDIO_PROFILE_SCRIPT_PATH="/etc/profile.d/00_rstudio_user_logins.sh"
    RSERVER_CONF_PATH="/etc/rstudio/rserver.conf"
    RSESSION_CONF_PATH="/etc/rstudio/rsession.conf"
    RSTUDIO_LOGGING_CONF_PATH="/etc/rstudio/logging.conf"
    RSTUDIO_ENV_VARS_PATH="/etc/rstudio/env-vars"
    GLOBAL_R_ENVIRON_SITE_PATH="/etc/R/Renviron.site"
    GLOBAL_R_PROFILE_SITE_PATH="/etc/R/Rprofile.site"
    RSTUDIO_SERVER_LOG_DIR="/var/log/rstudio/rstudio-server"
    RSTUDIO_FILE_LOCKING_LOG_DIR="/var/log/rstudio/rstudio-server/file-locking"
    RSERVER_WWW_ADDRESS="127.0.0.1"
    RSERVER_WWW_PORT="8787"
    DEFAULT_PYTHON_VERSION_LOGIN_SCRIPT="3.8.10"
    DEFAULT_PYTHON_PATH_LOGIN_SCRIPT="/usr/bin/python3.8"
    RSESSION_TIMEOUT_MINUTES="10080"
    RSESSION_WEBSOCKET_LOG_LEVEL="1"
    OPENBLAS_NUM_THREADS_RSTUDIO="4"
    OMP_NUM_THREADS_RSTUDIO="4"
    TARGET_SHARED_DIR_GROUP_PRIMARY="domain^users"
    TARGET_SHARED_DIR_GROUP_SECONDARY="domain users"
fi

# Source SSSD config vars if available (for home template, groups, etc.)
if [[ -f "$SSSD_CONF_VARS_FILE" ]]; then
    log "Sourcing SSSD configuration variables from $SSSD_CONF_VARS_FILE"
    source "$SSSD_CONF_VARS_FILE"
fi

# Source Samba config vars if available
if [[ -f "$SAMBA_CONF_VARS_FILE" ]]; then
    log "Sourcing Samba configuration variables from $SAMBA_CONF_VARS_FILE"
    source "$SAMBA_CONF_VARS_FILE"
fi

# --- Authentication Backend Detection ---

# Detects the active authentication backend (SSSD, Samba/Winbind, both, or none)
detect_auth_backend() {
    local sssd_active=false
    local samba_active=false
    
    # Check for SSSD
    if systemctl is-active --quiet sssd 2>/dev/null; then
        sssd_active=true
    fi
    
    # Check for Samba/Winbind
    if systemctl is-active --quiet winbind 2>/dev/null || \
       systemctl is-active --quiet smbd 2>/dev/null; then
        samba_active=true
    fi
    
    if $sssd_active && $samba_active; then
        echo "both"
    elif $sssd_active; then
        echo "sssd"
    elif $samba_active; then
        echo "samba"
    else
        echo "none"
    fi
}

# Returns the appropriate home directory template based on active backend
get_ad_homedir_template() {
    local backend
    backend=$(detect_auth_backend)
    
    case "$backend" in
        sssd)
            echo "${DEFAULT_FALLBACK_HOMEDIR_TEMPLATE:-/home/%d/%u}"
            ;;
        samba)
            echo "${DEFAULT_TEMPLATE_HOMEDIR:-/nfs/home/%U}"
            ;;
        both)
            # Prefer SSSD template if both are active
            echo "${DEFAULT_FALLBACK_HOMEDIR_TEMPLATE:-${DEFAULT_TEMPLATE_HOMEDIR:-/home/%d/%u}}"
            ;;
        *)
            # No AD backend detected, use default RStudio projects root
            echo "${R_PROJECTS_ROOT:-/media/r_projects}"
            ;;
    esac
}

# Returns a human-readable description of the active backend
get_auth_backend_description() {
    local backend
    backend=$(detect_auth_backend)
    
    case "$backend" in
        sssd)  echo "SSSD (Active Directory via SSSD)" ;;
        samba) echo "Samba/Winbind (Active Directory via Samba)" ;;
        both)  echo "Both SSSD and Samba/Winbind are active" ;;
        *)     echo "No AD integration detected (local auth only)" ;;
    esac
}

# --- RStudio Specific Functions ---

# Checks if RStudio Server is installed and its service is running.
check_rstudio_prerequisites() {
    log "Checking RStudio Server prerequisites..."
    if ! command -v rstudio-server &>/dev/null; then
        log "RStudio Server command not found. Please install RStudio Server first."
        log "Refer to Posit official documentation for installation instructions."
        return 1
    fi

    if ! systemctl is-enabled --quiet rstudio-server; then
        log "RStudio Server service is not enabled. Enabling..."
        run_command "systemctl enable rstudio-server" || return 1
    fi
    if ! systemctl is-active --quiet rstudio-server; then
        log "RStudio Server service is not running. Starting..."
        run_command "systemctl start rstudio-server" || return 1
    fi
    log "RStudio Server installed, service enabled and active."
    return 0
}

# Configures /etc/rstudio/rserver.conf based on variables.
configure_rstudio_server_conf() {
    log "Configuring RStudio Server (${RSERVER_CONF_PATH:-/etc/rstudio/rserver.conf})..."
    ensure_file_exists "${RSERVER_CONF_PATH}" || return 1

    if grep -q "^www-address=" "${RSERVER_CONF_PATH}"; then
        run_command "sed -i 's|^www-address=.*$|www-address=${RSERVER_WWW_ADDRESS}|' '${RSERVER_CONF_PATH}'"
    else add_line_if_not_present "www-address=${RSERVER_WWW_ADDRESS}" "${RSERVER_CONF_PATH}"; fi
    
    if grep -q "^www-port=" "${RSERVER_CONF_PATH}"; then
        run_command "sed -i 's|^www-port=.*$|www-port=${RSERVER_WWW_PORT}|' '${RSERVER_CONF_PATH}'"
    else add_line_if_not_present "www-port=${RSERVER_WWW_PORT}" "${RSERVER_CONF_PATH}"; fi
    
    # Configure root path if RSTUDIO_ROOT_PATH is set (e.g. /rstudio)
    if [[ -n "${RSTUDIO_ROOT_PATH}" ]]; then
        if grep -q "^www-root-path=" "${RSERVER_CONF_PATH}"; then
            run_command "sed -i 's|^www-root-path=.*$|www-root-path=${RSTUDIO_ROOT_PATH}|' '${RSERVER_CONF_PATH}'"
        else
            add_line_if_not_present "www-root-path=${RSTUDIO_ROOT_PATH}" "${RSERVER_CONF_PATH}"
        fi
    fi
    
    # Remove server-user setting if present (idempotent)
    run_command "sed -i '/^server-user=/d' '${RSERVER_CONF_PATH}'"

    log "${RSERVER_CONF_PATH} configured. Restarting RStudio Server..."
    run_command "systemctl restart rstudio-server"
}

# Sets up shared R project directories and the user login script from a template.
configure_rstudio_user_dirs_and_login_script() {
    log "Configuring RStudio user directories and login script..."
    # Determine which user directory template to use
    local user_dir_template
    if [[ -n "$RSTUDIO_USER_HOME_TEMPLATE" ]]; then
        user_dir_template="$RSTUDIO_USER_HOME_TEMPLATE"
        log "Using SSSD/Kerberos home template for user directories: $user_dir_template"
    else
        user_dir_template="$R_PROJECTS_ROOT"
        log "Using default RStudio user directory: $user_dir_template"
    fi

    # Ensure the chosen directory exists
    ensure_dir_exists "$user_dir_template" || return 1
    ensure_dir_exists "$USER_LOGIN_LOG_ROOT" || return 1

    local domain_group=""
    # Try primary group, then secondary, from config variables
    if getent group "${TARGET_SHARED_DIR_GROUP_PRIMARY:-nogroup1}" &>/dev/null; then
        domain_group="${TARGET_SHARED_DIR_GROUP_PRIMARY}"
    elif getent group "${TARGET_SHARED_DIR_GROUP_SECONDARY:-nogroup2}" &>/dev/null; then
        domain_group="${TARGET_SHARED_DIR_GROUP_SECONDARY}"
    fi

    if [[ -n "$domain_group" ]]; then
        run_command "chown -R root:\"$domain_group\" \"$user_dir_template\""
        run_command "chmod -R g+rwx \"$user_dir_template\""; run_command "chmod g+s \"$user_dir_template\""
        run_command "chown -R root:\"$domain_group\" \"${USER_LOGIN_LOG_ROOT}\""
        run_command "chmod -R g+rwx \"${USER_LOGIN_LOG_ROOT}\""; run_command "chmod g+s \"${USER_LOGIN_LOG_ROOT}\""
        log "Set ownership/permissions for $user_dir_template and ${USER_LOGIN_LOG_ROOT} for group '$domain_group'."
    else
        log "Warning: Target shared directory groups ('${TARGET_SHARED_DIR_GROUP_PRIMARY}' or '${TARGET_SHARED_DIR_GROUP_SECONDARY}') not found. Shared directory permissions not fully set."
    fi

    if ! command -v jq &>/dev/null; then
        log "jq is not installed. Attempting to install jq..."
        run_command "apt-get update -y && apt-get install -y jq" || { log "Failed to install jq. User preferences in login script might fail."; return 1; }
    fi

    local final_script_content
    if ! process_template "${TEMPLATE_DIR}/rstudio_user_login_script.sh.template" final_script_content \
        RSTUDIO_PROFILE_SCRIPT_PATH="${RSTUDIO_PROFILE_SCRIPT_PATH}" \
        R_PROJECTS_ROOT="$user_dir_template" \
        USER_LOGIN_LOG_ROOT="${USER_LOGIN_LOG_ROOT}" \
        DEFAULT_PYTHON_VERSION_LOGIN_SCRIPT="${DEFAULT_PYTHON_VERSION_LOGIN_SCRIPT}" \
        DEFAULT_PYTHON_PATH_LOGIN_SCRIPT="${DEFAULT_PYTHON_PATH_LOGIN_SCRIPT}"; then
        log "ERROR: Failed to process template for user login script"
        return 1
    fi
    if ! printf "%s" "$final_script_content" > "${RSTUDIO_PROFILE_SCRIPT_PATH}"; then
        log "ERROR: Failed to write user login script to ${RSTUDIO_PROFILE_SCRIPT_PATH}"
        return 1
    fi
    run_command "chmod +x ${RSTUDIO_PROFILE_SCRIPT_PATH}"
    log "${RSTUDIO_PROFILE_SCRIPT_PATH} configured."
}

# Configures global temporary directory settings for R and RStudio.
configure_rstudio_global_tmp() {
    log "Configuring RStudio global temporary directory settings..."
    ensure_dir_exists "${GLOBAL_RSTUDIO_TMP_DIR}" || return 1
    run_command "chmod 1777 \"${GLOBAL_RSTUDIO_TMP_DIR}\"" # Sticky bit, world-writable

    ensure_file_exists "${GLOBAL_R_ENVIRON_SITE_PATH}" || return 1
    # Declare array of settings to add
    declare -a tmp_settings=(
        "TMPDIR=\"${GLOBAL_RSTUDIO_TMP_DIR}\""
        "TMP=\"${GLOBAL_RSTUDIO_TMP_DIR}\""
        "TEMP=\"${GLOBAL_RSTUDIO_TMP_DIR}\""
    )
    for setting in "${tmp_settings[@]}"; do
        add_line_if_not_present "$setting" "${GLOBAL_R_ENVIRON_SITE_PATH}"
    done
    log "Global R temp dirs set in ${GLOBAL_R_ENVIRON_SITE_PATH}. Restarting RStudio Server..."
    run_command "systemctl restart rstudio-server"
}

# Tests RStudio PAM authentication using pamtester.
test_rstudio_pam_auth() {
    log "Performing RStudio PAM authentication test with pamtester..."
    
    # Show detected authentication backend
    local auth_backend
    auth_backend=$(detect_auth_backend)
    log "Detected authentication backend: $(get_auth_backend_description)"
    
    if ! command -v pamtester &>/dev/null; then
        log "pamtester not found. Run AD Integration setup (Option S from main menu) to install or install manually."
        return 1
    fi

    local ad_user_id
    read -r -p "Enter username for RStudio PAM test (e.g., user@domain.com or shortname): " ad_user_id
    if [[ -z "$ad_user_id" ]]; then
        log "No user entered. Skipping PAM test."
        return 0
    fi
    
    log "Testing PAM for service 'rstudio' with user '$ad_user_id'..."
    local pam_output # To capture output if needed, though run_command logs it
    # run_command will handle logging of the command and its output.
    if run_command "pamtester --verbose rstudio \"$ad_user_id\" authenticate acct_mgmt"; then
        log "RStudio PAM authentication test SUCCEEDED for $ad_user_id."
    else
        log "RStudio PAM authentication test FAILED for $ad_user_id."
        case "$auth_backend" in
            sssd)  log "Consult SSSD setup, /etc/pam.d/rstudio, and RStudio Server logs." ;;
            samba) log "Consult Samba/Winbind setup, /etc/pam.d/rstudio, and RStudio Server logs." ;;
            *)     log "No AD backend detected. Ensure SSSD or Samba is configured (Option S)." ;;
        esac
        return 1
    fi
}

# Configures RStudio session settings (rsession.conf), logging (logging.conf),
# environment variables (env-vars), and the global R profile (Rprofile.site).
configure_rstudio_session_env_settings() {
    log "Configuring RStudio session settings, logging, env-vars, and R profile..."
    ensure_file_exists "${RSESSION_CONF_PATH}" || return 1
    # logging.conf will be created from template, ensure parent dir exists
    ensure_dir_exists "$(dirname "${RSTUDIO_LOGGING_CONF_PATH}")" || return 1
    ensure_file_exists "${RSTUDIO_ENV_VARS_PATH}" || return 1
    ensure_file_exists "${GLOBAL_R_PROFILE_SITE_PATH}" || return 1
    ensure_dir_exists "${RSTUDIO_FILE_LOCKING_LOG_DIR}" || return 1 # For logging.conf
    ensure_dir_exists "${RSTUDIO_SERVER_LOG_DIR}" || return 1       # For logging.conf

    # Configure rsession.conf
    declare -A rsession_settings=(
        ["session-timeout-minutes"]="${RSESSION_TIMEOUT_MINUTES}"
        ["websocket-log-level"]="${RSESSION_WEBSOCKET_LOG_LEVEL}"
        ["session-handle-offline-enabled"]="1"
        ["session-connections-block-suspend"]="1"
        ["session-external-pointers-block-suspend"]="1"
        ["copilot-enabled"]="${RSESSION_COPLOT_ENABLED:-0}" # Default to 0 if var not set
    )
    for key in "${!rsession_settings[@]}"; do
        local line="${key}=${rsession_settings[$key]}"
        if grep -q "^${key}=" "${RSESSION_CONF_PATH}"; then
            run_command "sed -i 's|^${key}=.*|${line}|' '${RSESSION_CONF_PATH}'"
        else
            add_line_if_not_present "$line" "${RSESSION_CONF_PATH}"
        fi
    done
    log "${RSESSION_CONF_PATH} updated."

    # Configure logging.conf from template
    local final_logging_conf
    if ! process_template "${TEMPLATE_DIR}/rstudio_logging.conf.template" final_logging_conf \
        RSTUDIO_SERVER_LOG_DIR="${RSTUDIO_SERVER_LOG_DIR}" \
        RSTUDIO_FILE_LOCKING_LOG_DIR="${RSTUDIO_FILE_LOCKING_LOG_DIR}"; then
        log "ERROR: Failed to process template for logging.conf"
        return 1
    fi
    if ! printf "%s" "$final_logging_conf" > "${RSTUDIO_LOGGING_CONF_PATH}"; then
        log "ERROR: Failed to write ${RSTUDIO_LOGGING_CONF_PATH} from template"
        return 1
    fi
    log "${RSTUDIO_LOGGING_CONF_PATH} updated from template."

    # Configure env-vars
    declare -A env_vars_settings=(
        ["OPENBLAS_NUM_THREADS"]="${OPENBLAS_NUM_THREADS_RSTUDIO}"
        ["OMP_NUM_THREADS"]="${OMP_NUM_THREADS_RSTUDIO}"
    )
    # Overwrite env-vars file with new settings for a clean state
    true >"${RSTUDIO_ENV_VARS_PATH}" # Clear the file first
    for key in "${!env_vars_settings[@]}"; do
        add_line_if_not_present "${key}=${env_vars_settings[$key]}" "${RSTUDIO_ENV_VARS_PATH}"
    done
    log "${RSTUDIO_ENV_VARS_PATH} updated."
    
    # Configure Rprofile.site welcome message from template
    local r_host; r_host=$(hostname -f 2>/dev/null || hostname)
    local r_ip; r_ip=$(hostname -I | awk '{print $1}') # Gets the first IP address
    local welcome_sentinel_check="You are welcome to '${r_host}'" # Key part of message to check for existence

    # Check if the sentinel is already in the file to prevent duplicate appends
    if ! grep -qF "$welcome_sentinel_check" "${GLOBAL_R_PROFILE_SITE_PATH}"; then
        log "Adding welcome message to ${GLOBAL_R_PROFILE_SITE_PATH} from template..."
        local final_welcome_message
        if ! process_template "${TEMPLATE_DIR}/r_profile_site_welcome.R.template" final_welcome_message \
            R_HOST="$r_host" \
            R_IP="$r_ip" \
            R_PROJECTS_ROOT="${R_PROJECTS_ROOT}"; then
            log "ERROR: Failed to process template for welcome message"
            return 1
        fi
        # Append the processed template content to Rprofile.site
        if ! printf "\n%s\n" "$final_welcome_message" >> "${GLOBAL_R_PROFILE_SITE_PATH}"; then
             log "ERROR: Failed to append welcome message to ${GLOBAL_R_PROFILE_SITE_PATH}"
             return 1
        fi
        log "${GLOBAL_R_PROFILE_SITE_PATH} updated with welcome message."
    else
        log "Welcome message already present in ${GLOBAL_R_PROFILE_SITE_PATH}."
    fi

    log "RStudio session/environment settings applied. Restarting RStudio Server..."
    run_command "systemctl restart rstudio-server"
}

# Uninstalls configurations made by this script.
uninstall_rstudio_configs() {
    log "Uninstalling RStudio Server configurations..."
    backup_config # Backup current state before uninstalling

    if systemctl is-active --quiet rstudio-server; then
        run_command "systemctl stop rstudio-server"
    fi
    
    local confirm_pkg
    read -r -p "Remove RStudio Server package (apt remove --purge rstudio-server)? (y/n): " confirm_pkg
    if [[ "$confirm_pkg" == "y" || "$confirm_pkg" == "Y" ]]; then
        if dpkg -l | grep -q 'rstudio-server'; then # Check if package is installed
            run_command "apt-get remove --purge -y rstudio-server"
        else
            log "RStudio Server package not found, skipping removal."
        fi
    else
        log "Skipping RStudio Server package removal."
    fi

    log "Removing script-added configurations (e.g., login script)..."
    run_command "rm -f ${RSTUDIO_PROFILE_SCRIPT_PATH}"
    # Note: This uninstall does not revert changes to rserver.conf, rsession.conf, etc.
    # to their pre-script state. For that, restore from an earlier backup or reinstall RStudio.
    log "RStudio configurations uninstalled (primarily profile script). Package and core configs handled as per prompt."
    log "User data in ${R_PROJECTS_ROOT} and user home directories are NOT touched."
}

# Main menu function for RStudio setup operations.
main_rstudio_menu() {
    while true; do
        # Detect current home directory template for display
        local current_homedir_template
        current_homedir_template=$(get_ad_homedir_template)
        
        # Using printf for menu for better formatting and portability
        printf "\n===== RStudio Configuration Menu =====\n"
        printf "Auth Backend: %s\n" "$(get_auth_backend_description)"
        printf "======================================\n"
        printf "1. Full RStudio Setup (Prerequisites, Server Conf, User Dirs, Temp, Session Env)\n"
        printf "2. Check RStudio Prerequisites & Configure rserver.conf (%s)\n" "${RSERVER_CONF_PATH}"
        printf "3. Configure User Directories & Login Script\n"
        printf "   [A] Use default directory (%s)\n" "${R_PROJECTS_ROOT}"
        printf "   [B] Use AD home template (%s) [Auto-detected]\n" "$current_homedir_template"
        printf "4. Configure Global RStudio Temporary Directory (%s)\n" "${GLOBAL_RSTUDIO_TMP_DIR}"
        printf "5. Configure RStudio Session/Environment Settings & R Profile\n"
        printf -- "--------------------------------------\n"
        printf "S. Configure AD Integration (SSSD or Samba/Winbind)\n"
        printf "6. Test RStudio PAM Authentication (after AD setup)\n"
        printf -- "--------------------------------------\n"
        printf "7. Uninstall RStudio Configurations (profile script, optional package removal)\n"
        printf "8. Restore All Configurations from Last Backup\n"
        printf "9. Exit\n"
        printf "======================================\n"
        read -r -p "Enter choice: " choice

        case $choice in
            1)
                backup_config && \
                check_rstudio_prerequisites && \
                configure_rstudio_server_conf && \
                configure_rstudio_user_dirs_and_login_script && \
                configure_rstudio_global_tmp && \
                configure_rstudio_session_env_settings && \
                log "Full RStudio setup completed successfully." || \
                log "ERROR: Full RStudio setup failed or was interrupted. Check logs."
                log "NOTE: SSSD/Kerberos setup is a separate step (Option S)."
                ;;
            2) backup_config && check_rstudio_prerequisites && configure_rstudio_server_conf ;;
            3)
                local detected_template
                detected_template=$(get_ad_homedir_template)
                printf "\nChoose user directory and login script location:\n"
                printf "A) Use default directory (%s)\n" "${R_PROJECTS_ROOT}"
                printf "B) Use AD home template (%s) [Auto-detected based on %s]\n" "$detected_template" "$(detect_auth_backend)"
                read -r -p "Select option [A/B]: " user_dir_choice
                if [[ "$user_dir_choice" =~ ^[Bb]$ ]]; then
                    # Use auto-detected home template based on active backend
                    export RSTUDIO_USER_HOME_TEMPLATE="$detected_template"
                    log "Using AD home template for user directories: $RSTUDIO_USER_HOME_TEMPLATE"
                else
                    # Use default directory
                    unset RSTUDIO_USER_HOME_TEMPLATE
                    log "Using default RStudio user directory: $R_PROJECTS_ROOT"
                fi
                backup_config && check_rstudio_prerequisites && configure_rstudio_user_dirs_and_login_script ;;
            4) backup_config && check_rstudio_prerequisites && configure_rstudio_global_tmp ;;
            5) backup_config && check_rstudio_prerequisites && configure_rstudio_session_env_settings ;;
            S|s)
                printf "\n===== AD Integration Setup =====\n"
                printf "Select authentication backend to configure:\n"
                printf "1) SSSD/Kerberos (recommended for most AD environments)\n"
                printf "2) Samba/Winbind (for Samba domain membership)\n"
                printf "B) Back to main menu\n"
                read -r -p "Choice: " auth_choice
                case "$auth_choice" in
                    1)
                        if [[ -f "$SSSD_KERBEROS_SCRIPT_PATH" ]]; then
                            log "Launching SSSD/Kerberos Setup Script..."
                            bash "$SSSD_KERBEROS_SCRIPT_PATH"
                            log "Returned from SSSD/Kerberos Setup Script."
                        else
                            log "ERROR: SSSD script ($SSSD_KERBEROS_SCRIPT_PATH) not found."
                        fi
                        ;;
                    2)
                        if [[ -f "$SAMBA_KERBEROS_SCRIPT_PATH" ]]; then
                            log "Launching Samba/Winbind Setup Script..."
                            bash "$SAMBA_KERBEROS_SCRIPT_PATH"
                            log "Returned from Samba/Winbind Setup Script."
                        else
                            log "ERROR: Samba script ($SAMBA_KERBEROS_SCRIPT_PATH) not found."
                        fi
                        ;;
                    [Bb]*) ;;
                    *) printf "Invalid choice.\n" ;;
                esac
                ;;
            6) test_rstudio_pam_auth ;; 
            7) uninstall_rstudio_configs ;; # backup_config is called within this function
            8) restore_config ;;
            9) log "Exiting RStudio Setup."; break ;;
            *) printf "Invalid choice. Please try again.\n" ;;
        esac
        # Pause for user to read output before showing menu again, unless exiting.
        if [[ "$choice" != "9" ]]; then
            read -r -p "Press Enter to continue..."
        fi
    done
}

# --- Script Entry Point ---
log "=== RStudio Setup Script Started ==="
# SCRIPT_DIR is defined at the top, making it available for common_utils.sh backup function
setup_backup_dir # Initialize a unique backup directory for this script session
main_rstudio_menu
log "=== RStudio Setup Script Finished ==="
