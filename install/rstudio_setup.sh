#!/bin/bash
# rstudio_setup.sh - RStudio Server Configuration Script
# This script automates the setup and configuration of RStudio Server,
# including directory structures, user-specific settings, and global configurations.
# It sources common utilities and a dedicated configuration file.

# Determine the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Define paths relative to SCRIPT_DIR
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/common_utils.sh"
SSSD_KERBEROS_SCRIPT_PATH="${SCRIPT_DIR}/sssd_kerberos_setup.sh" # Path to SSSD script
CONF_VARS_FILE="${SCRIPT_DIR}/conf/rstudio_setup.vars.conf"
TEMPLATE_DIR="${SCRIPT_DIR}/templates" # Used by _get_template_content

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
    
    # Remove server-user setting if present (idempotent)
    run_command "sed -i '/^server-user=/d' '${RSERVER_CONF_PATH}'"

    log "${RSERVER_CONF_PATH} configured. Restarting RStudio Server..."
    run_command "systemctl restart rstudio-server"
}

# Sets up shared R project directories and the user login script from a template.
configure_rstudio_user_dirs_and_login_script() {
    log "Configuring RStudio user directories and login script..."
    ensure_dir_exists "${R_PROJECTS_ROOT}" || return 1
    ensure_dir_exists "${USER_LOGIN_LOG_ROOT}" || return 1

    local domain_group=""
    # Try primary group, then secondary, from config variables
    if getent group "${TARGET_SHARED_DIR_GROUP_PRIMARY:-nogroup1}" &>/dev/null; then # nogroup1 to ensure it fails if var empty
        domain_group="${TARGET_SHARED_DIR_GROUP_PRIMARY}"
    elif getent group "${TARGET_SHARED_DIR_GROUP_SECONDARY:-nogroup2}" &>/dev/null; then
        domain_group="${TARGET_SHARED_DIR_GROUP_SECONDARY}"
    fi

    if [[ -n "$domain_group" ]]; then
        run_command "chown -R root:\"$domain_group\" \"${R_PROJECTS_ROOT}\""
        run_command "chmod -R g+rwx \"${R_PROJECTS_ROOT}\""; run_command "chmod g+s \"${R_PROJECTS_ROOT}\""
        run_command "chown -R root:\"$domain_group\" \"${USER_LOGIN_LOG_ROOT}\""
        run_command "chmod -R g+rwx \"${USER_LOGIN_LOG_ROOT}\""; run_command "chmod g+s \"${USER_LOGIN_LOG_ROOT}\""
        log "Set ownership/permissions for ${R_PROJECTS_ROOT} and ${USER_LOGIN_LOG_ROOT} for group '$domain_group'."
    else
        log "Warning: Target shared directory groups ('${TARGET_SHARED_DIR_GROUP_PRIMARY}' or '${TARGET_SHARED_DIR_GROUP_SECONDARY}') not found. Shared directory permissions not fully set."
    fi

    if ! command -v jq &>/dev/null; then
        log "jq is not installed. Attempting to install jq..."
        run_command "apt-get update -y && apt-get install -y jq" || { log "Failed to install jq. User preferences in login script might fail."; return 1; }
    fi

    local login_script_template_content
    login_script_template_content=$(_get_template_content "rstudio_user_login_script.sh.template") || return 1
    
    log "Creating/Updating user login script ${RSTUDIO_PROFILE_SCRIPT_PATH} from template..."
    local final_script_content
    final_script_content=$(apply_replacements "$login_script_template_content" \
        "%%RSTUDIO_PROFILE_SCRIPT_PATH%%" "${RSTUDIO_PROFILE_SCRIPT_PATH}" \
        "%%R_PROJECTS_ROOT%%" "${R_PROJECTS_ROOT}" \
        "%%USER_LOGIN_LOG_ROOT%%" "${USER_LOGIN_LOG_ROOT}" \
        "%%DEFAULT_PYTHON_VERSION_LOGIN_SCRIPT%%" "${DEFAULT_PYTHON_VERSION_LOGIN_SCRIPT}" \
        "%%DEFAULT_PYTHON_PATH_LOGIN_SCRIPT%%" "${DEFAULT_PYTHON_PATH_LOGIN_SCRIPT}" \
    )
    
    # Write the processed content to the target script path
    # Using printf for potentially complex content is safer than echo.
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
    if ! command -v pamtester &>/dev/null; then
        log "pamtester not found. Run SSSD/Kerberos setup (Option S from main menu) to install or install manually."
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
        log "Consult SSSD/Kerberos setup, /etc/pam.d/rstudio, and RStudio Server logs."
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
    local logging_template_content
    logging_template_content=$(_get_template_content "rstudio_logging.conf.template") || return 1
    local final_logging_conf
    final_logging_conf=$(apply_replacements "$logging_template_content" \
        "%%RSTUDIO_SERVER_LOG_DIR%%" "${RSTUDIO_SERVER_LOG_DIR}" \
        "%%RSTUDIO_FILE_LOCKING_LOG_DIR%%" "${RSTUDIO_FILE_LOCKING_LOG_DIR}" \
    )
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
    >"${RSTUDIO_ENV_VARS_PATH}" # Clear the file first
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
        local welcome_template_content
        welcome_template_content=$(_get_template_content "r_profile_site_welcome.R.template") || return 1
        local final_welcome_message
        final_welcome_message=$(apply_replacements "$welcome_template_content" \
            "%%R_HOST%%" "$r_host" \
            "%%R_IP%%" "$r_ip" \
            "%%R_PROJECTS_ROOT%%" "${R_PROJECTS_ROOT}" \
        )
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
        # Using printf for menu for better formatting and portability
        printf "\n===== RStudio Configuration Menu =====\n"
        printf "1. Full RStudio Setup (Prerequisites, Server Conf, User Dirs, Temp, Session Env)\n"
        printf "2. Check RStudio Prerequisites & Configure rserver.conf (%s)\n" "${RSERVER_CONF_PATH}"
        printf "3. Configure User Directories & Login Script (%s)\n" "${RSTUDIO_PROFILE_SCRIPT_PATH}"
        printf "4. Configure Global RStudio Temporary Directory (%s)\n" "${GLOBAL_RSTUDIO_TMP_DIR}"
        printf "5. Configure RStudio Session/Environment Settings & R Profile\n"
        printf -- "--------------------------------------\n" # Using -- to indicate end of options for printf
        printf "S. Configure SSSD/Kerberos for AD Integration (Launches separate script)\n"
        printf "6. Test RStudio PAM Authentication (after SSSD/Kerberos setup)\n"
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
            3) backup_config && check_rstudio_prerequisites && configure_rstudio_user_dirs_and_login_script ;;
            4) backup_config && check_rstudio_prerequisites && configure_rstudio_global_tmp ;;
            5) backup_config && check_rstudio_prerequisites && configure_rstudio_session_env_settings ;;
            S|s)
                if [[ -f "$SSSD_KERBEROS_SCRIPT_PATH" ]]; then
                    log "Launching SSSD/Kerberos Setup Script..."
                    # Execute in current shell to allow it to modify environment if needed,
                    # or use bash explicitly if it's designed to be standalone.
                    # Assuming it's designed to be run as a separate process:
                    bash "$SSSD_KERBEROS_SCRIPT_PATH"
                    log "Returned from SSSD/Kerberos Setup Script."
                else
                    log "ERROR: SSSD/Kerberos script ($SSSD_KERBEROS_SCRIPT_PATH) not found."
                fi
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
