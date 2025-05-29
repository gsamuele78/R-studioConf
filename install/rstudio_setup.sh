#!/bin/bash
# rstudio_setup.sh - RStudio Server Configuration Script

# Source common utilities
UTILS_SCRIPT_PATH="$(dirname "$0")/common_utils.sh"
SSSD_KERBEROS_SCRIPT_PATH="$(dirname "$0")/sssd_kerberos_setup.sh"
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    echo "Error: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
    exit 1
fi
# shellcheck source=common_utils.sh
source "$UTILS_SCRIPT_PATH"

# --- CONFIGURATION VARIABLES ---
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
RSTUDIO_FILE_LOCKING_LOG_DIR="/var/log/rstudio/rstudio-server/file-locking"
RSTUDIO_SERVER_LOG_DIR="/var/log/rstudio/rstudio-server"
RSERVER_WWW_ADDRESS="127.0.0.1"
RSERVER_WWW_PORT="8787"
DEFAULT_PYTHON_VERSION_LOGIN_SCRIPT="3.8.10"
DEFAULT_PYTHON_PATH_LOGIN_SCRIPT="/usr/bin/python3.8"
RSESSION_TIMEOUT_MINUTES="10080"
RSESSION_WEBSOCKET_LOG_LEVEL="1"
OPENBLAS_NUM_THREADS_RSTUDIO="4"
OMP_NUM_THREADS_RSTUDIO="4"
# --- END CONFIGURATION VARIABLES ---

check_rstudio_prerequisites() {
    log "Checking RStudio Server prerequisites..."
    if ! command -v rstudio-server &>/dev/null; then
        log "RStudio Server command not found. Please install RStudio Server first."
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

configure_rstudio_server_conf() {
    log "Configuring RStudio Server ($RSERVER_CONF_PATH)..."
    ensure_file_exists "$RSERVER_CONF_PATH" || return 1

    if grep -q "^www-address=" "$RSERVER_CONF_PATH"; then
        run_command "sed -i 's|^www-address=.*$|www-address=$RSERVER_WWW_ADDRESS|' '$RSERVER_CONF_PATH'"
    else add_line_if_not_present "www-address=$RSERVER_WWW_ADDRESS" "$RSERVER_CONF_PATH"; fi
    if grep -q "^www-port=" "$RSERVER_CONF_PATH"; then
        run_command "sed -i 's|^www-port=.*$|www-port=$RSERVER_WWW_PORT|' '$RSERVER_CONF_PATH'"
    else add_line_if_not_present "www-port=$RSERVER_WWW_PORT" "$RSERVER_CONF_PATH"; fi
    run_command "sed -i '/^server-user=/d' '$RSERVER_CONF_PATH'"

    log "$RSERVER_CONF_PATH configured. Restarting RStudio Server..."
    run_command "systemctl restart rstudio-server"
}

configure_rstudio_user_dirs_and_login_script() {
    log "Configuring RStudio user directories and login script..."
    ensure_dir_exists "$R_PROJECTS_ROOT" || return 1
    ensure_dir_exists "$USER_LOGIN_LOG_ROOT" || return 1

    local domain_group=""
    if getent group "domain^users" &>/dev/null; then domain_group="domain^users";
    elif getent group "domain users" &>/dev/null; then domain_group="domain users"; fi

    if [[ -n "$domain_group" ]]; then
        run_command "chown -R root:\"$domain_group\" \"$R_PROJECTS_ROOT\""
        run_command "chmod -R g+rwx \"$R_PROJECTS_ROOT\""; run_command "chmod g+s \"$R_PROJECTS_ROOT\""
        run_command "chown -R root:\"$domain_group\" \"$USER_LOGIN_LOG_ROOT\""
        run_command "chmod -R g+rwx \"$USER_LOGIN_LOG_ROOT\""; run_command "chmod g+s \"$USER_LOGIN_LOG_ROOT\""
        log "Set ownership/perms for $R_PROJECTS_ROOT and $USER_LOGIN_LOG_ROOT for group '$domain_group'."
    else log "Warning: Group 'domain^users' or 'domain users' not found. Shared dir perms not fully set."; fi

    if ! command -v jq &>/dev/null; then
        log "jq is not installed. Attempting to install jq..."
        run_command "apt-get update -y && apt-get install -y jq" || { log "Failed to install jq."; return 1; }
    fi

    log "Creating/Updating user login script $RSTUDIO_PROFILE_SCRIPT_PATH"
    cat <<EOF_USER_LOGIN_SCRIPT > "$RSTUDIO_PROFILE_SCRIPT_PATH"
#!/bin/bash
# shellcheck disable=SC2034,SC2155 # Unused (template vars) and dynamic var assignments
# $RSTUDIO_PROFILE_SCRIPT_PATH
set -u 
USER_PROJECTS_BASE_DIR="$R_PROJECTS_ROOT"
USER_LOGIN_LOG_DIR_BASE="$USER_LOGIN_LOG_ROOT"
PYTHON_VERSION_FOR_PREFS="$DEFAULT_PYTHON_VERSION_LOGIN_SCRIPT"
PYTHON_PATH_FOR_PREFS="$DEFAULT_PYTHON_PATH_LOGIN_SCRIPT"

CURRENT_USER=\$(whoami)
USER_LOGIN_LOG_FILE="\${USER_LOGIN_LOG_DIR_BASE}/\${CURRENT_USER}_login_setup.log"
_log_user_setup() { mkdir -p "\${USER_LOGIN_LOG_DIR_BASE}"; echo "\$(date '+%Y-%m-%d %H:%M:%S') [\${CURRENT_USER}] - \$1" >> "\${USER_LOGIN_LOG_FILE}"; }
_ensure_command_exists() { command -v "\$1" >/dev/null 2>&1 || { _log_user_setup "Error: Command '\$1' not found."; return 1; }; return 0; }

_setup_user_r_environment() {
    _log_user_setup "Starting R env setup for \${CURRENT_USER}."
    local r_path; r_path=\$(which R) || { _log_user_setup "R cmd not found."; return 1; }
    local r_version; r_version=\$($r_path --version | head -n1 | awk '{print \$3}' | awk -F. '{print \$1"."\$2}')
    [[ -z "\$r_version" ]] && { _log_user_setup "Could not get R version."; return 1; }
    local user_specific_projects_dir="\${USER_PROJECTS_BASE_DIR}/\${CURRENT_USER}"
    local user_r_config_dir="\${user_specific_projects_dir}/.config"
    local user_r_data_dir="\${user_specific_projects_dir}/.local/share"
    local user_r_libs_dir="\${user_specific_projects_dir}/R/x86_64-pc-linux-gnu-library/\${r_version}"
    for dir in "\$user_specific_projects_dir" "\$user_r_config_dir" "\$user_r_data_dir" "\$user_r_libs_dir"; do
        mkdir -p "\$dir" || { _log_user_setup "Failed to create \$dir"; return 1; }
        if [[ "\$dir" == "\$user_r_config_dir" ]] || [[ "\$dir" == "\$user_r_data_dir" ]]; then chmod 700 "\$dir"; else chmod 750 "\$dir"; fi
    done
    _log_user_setup "User R dirs created."
    local user_actual_home; user_actual_home=\$(eval echo ~\${CURRENT_USER}) # SC2046, SC2086: eval is tricky. This is for tilde expansion.
    local r_environ_file="\${user_actual_home}/.Renviron"; touch "\${r_environ_file}"
    declare -A renviron_settings=(
        ["R_LIBS_USER"]="\"\${user_r_libs_dir}\""
        ["XDG_CONFIG_HOME"]="\"\${user_r_config_dir}\""
        ["XDG_DATA_HOME"]="\"\${user_r_data_dir}\""
    )
    for key in "\${!renviron_settings[@]}"; do local entry="\${key}=\${renviron_settings[\$key]}"; if ! grep -qxF "\${entry}" "\${r_environ_file}"; then printf "%s\n" "\${entry}" >> "\${r_environ_file}"; fi; done
    _log_user_setup ".Renviron configured at \${r_environ_file}."
    return 0
}
_setup_rstudio_user_prefs() {
    _log_user_setup "Configuring RStudio user prefs for \${CURRENT_USER}."
    _ensure_command_exists "jq" || return 1
    local user_specific_projects_dir="\${USER_PROJECTS_BASE_DIR}/\${CURRENT_USER}"
    local rstudio_prefs_dir="\${user_specific_projects_dir}/.config/rstudio"
    local rstudio_prefs_file="\${rstudio_prefs_dir}/rstudio-prefs.json"
    mkdir -p "\${rstudio_prefs_dir}" && chmod 700 "\${rstudio_prefs_dir}"
    touch "\${rstudio_prefs_file}" && chmod 600 "\${rstudio_prefs_file}"
    local prefs_json_template; read -r -d '' prefs_json_template <<PREFS_EOF || true
{ "initial_working_directory": "%s", "default_project_location": "%s", "posix_terminal_shell": "bash",
  "show_last_dot_value": true, "auto_detect_indentation": true, "highlight_selected_line": true, "highlight_r_function_calls": true,
  "rainbow_parentheses": true, "check_arguments_to_r_function_calls": true, "check_unexpected_assignment_in_function_call": true,
  "warn_if_no_such_variable_in_scope": true, "warn_variable_defined_but_not_used": true, "show_diagnostics_other": true,
  "syntax_color_console": true, "auto_expand_error_tracebacks": true, "show_hidden_files": true,
  "terminal_initial_directory": "current", "show_invisibles": true, "show_help_tooltip_on_idle": true,
  "indent_guides": "rainbowfills", "code_formatter": "styler", "python_type": "system",
  "python_version": "\${PYTHON_VERSION_FOR_PREFS}", "python_path": "\${PYTHON_PATH_FOR_PREFS}", "reformat_on_save": true }
PREFS_EOF
    local prefs_json; printf -v prefs_json "\$prefs_json_template" "\${user_specific_projects_dir}" "\${user_specific_projects_dir}"
    local temp_prefs_file; temp_prefs_file=\$(mktemp)
    if [[ ! -s "\$rstudio_prefs_file" ]] || ! jq -e . "\$rstudio_prefs_file" >/dev/null 2>&1; then
        printf "%s\n" "\$prefs_json" > "\$rstudio_prefs_file"; _log_user_setup "Initialized RStudio prefs at \${rstudio_prefs_file}."
    else
        jq -s '.[0] * .[1]' "\$rstudio_prefs_file" <(printf "%s\n" "\$prefs_json") > "\$temp_prefs_file" && mv "\$temp_prefs_file" "\$rstudio_prefs_file"
        _log_user_setup "Merged RStudio prefs into \${rstudio_prefs_file}."
    fi; rm -f "\$temp_prefs_file"; chmod 600 "\$rstudio_prefs_file"; return 0
}
_log_user_setup "User login script started."
if _ensure_command_exists "R" && _ensure_command_exists "awk" && _ensure_command_exists "grep" && _ensure_command_exists "sed" && \
   _ensure_command_exists "mkdir" && _ensure_command_exists "touch" && _ensure_command_exists "chmod" && \
   _ensure_command_exists "printf" && _ensure_command_exists "eval" && _ensure_command_exists "mktemp"; then
    if _setup_user_r_environment && _setup_rstudio_user_prefs; then
        _log_user_setup "User R env and RStudio prefs setup successfully."
    else _log_user_setup "Errors during user R env or RStudio prefs setup."; fi
else _log_user_setup "Critical commands missing. Aborting user setup script."; fi
_log_user_setup "User login script finished."
EOF_USER_LOGIN_SCRIPT
    run_command "chmod +x $RSTUDIO_PROFILE_SCRIPT_PATH"
    log "$RSTUDIO_PROFILE_SCRIPT_PATH configured."
}

configure_rstudio_global_tmp() {
    log "Configuring RStudio global temporary directory settings..."
    ensure_dir_exists "$GLOBAL_RSTUDIO_TMP_DIR" || return 1
    run_command "chmod 1777 \"$GLOBAL_RSTUDIO_TMP_DIR\""

    ensure_file_exists "$GLOBAL_R_ENVIRON_SITE_PATH" || return 1
    declare -a tmp_settings=(
        "TMPDIR=\"$GLOBAL_RSTUDIO_TMP_DIR\""
        "TMP=\"$GLOBAL_RSTUDIO_TMP_DIR\""
        "TEMP=\"$GLOBAL_RSTUDIO_TMP_DIR\""
    )
    for setting in "${tmp_settings[@]}"; do add_line_if_not_present "$setting" "$GLOBAL_R_ENVIRON_SITE_PATH"; done
    log "Global R temp dirs set in $GLOBAL_R_ENVIRON_SITE_PATH. Restarting RStudio Server..."
    run_command "systemctl restart rstudio-server"
}

test_rstudio_pam_auth() {
    log "Performing RStudio PAM authentication test with pamtester..."
    if ! command -v pamtester &>/dev/null; then
        log "pamtester not found. Run SSSD/Kerberos setup or install manually."
        return 1
    fi
    local ad_user_id; read -r -p "Enter username for RStudio PAM test (e.g., user@domain.com or shortname): " ad_user_id
    if [[ -z "$ad_user_id" ]]; then log "No user entered. Skipping PAM test."; return 0; fi
    log "Testing PAM for service 'rstudio' with user '$ad_user_id'..."
    local pam_output
    if pam_output=$(pamtester --verbose rstudio "$ad_user_id" authenticate acct_mgmt 2>&1); then
        log "RStudio PAM authentication test SUCCEEDED for $ad_user_id."
        log "pamtester output: $pam_output"
    else
        log "RStudio PAM authentication test FAILED for $ad_user_id. pamtester output: $pam_output"
        return 1
    fi
}

configure_rstudio_session_env_settings() {
    log "Configuring RStudio session settings and R profile..."
    ensure_file_exists "$RSESSION_CONF_PATH" || return 1
    ensure_file_exists "$RSTUDIO_LOGGING_CONF_PATH" || return 1
    ensure_file_exists "$RSTUDIO_ENV_VARS_PATH" || return 1
    ensure_file_exists "$GLOBAL_R_PROFILE_SITE_PATH" || return 1
    ensure_dir_exists "$RSTUDIO_FILE_LOCKING_LOG_DIR" || return 1
    ensure_dir_exists "$RSTUDIO_SERVER_LOG_DIR" || return 1

    declare -A rsession_settings=(
        ["session-timeout-minutes"]="$RSESSION_TIMEOUT_MINUTES"
        ["websocket-log-level"]="$RSESSION_WEBSOCKET_LOG_LEVEL"
        ["session-handle-offline-enabled"]="1"
        ["session-connections-block-suspend"]="1"
        ["session-external-pointers-block-suspend"]="1"
        ["copilot-enabled"]="1"
    )
    for key in "${!rsession_settings[@]}"; do
        local line="${key}=${rsession_settings[$key]}"
        if grep -q "^${key}=" "$RSESSION_CONF_PATH"; then run_command "sed -i 's|^${key}=.*|${line}|' '$RSESSION_CONF_PATH'"
        else add_line_if_not_present "$line" "$RSESSION_CONF_PATH"; fi
    done; log "$RSESSION_CONF_PATH updated."

    cat <<EOF_LOGGING_CONF > "$RSTUDIO_LOGGING_CONF_PATH"
[*]
log-level=info
logger-type=file
max-size-mb=20
rotate=yes
[@rserver]
log-level=debug
log-dir=$RSTUDIO_SERVER_LOG_DIR
logger-type=file
max-size-mb=10
rotate=yes
[file-locking]
log-dir=$RSTUDIO_FILE_LOCKING_LOG_DIR
log-file-mode=600
EOF_LOGGING_CONF
    log "$RSTUDIO_LOGGING_CONF_PATH updated."

    declare -A env_vars_settings=(
        ["OPENBLAS_NUM_THREADS"]="$OPENBLAS_NUM_THREADS_RSTUDIO"
        ["OMP_NUM_THREADS"]="$OMP_NUM_THREADS_RSTUDIO"
    )
    >"$RSTUDIO_ENV_VARS_PATH" # Clear file
    for key in "${!env_vars_settings[@]}"; do add_line_if_not_present "${key}=${env_vars_settings[$key]}" "$RSTUDIO_ENV_VARS_PATH"; done
    log "$RSTUDIO_ENV_VARS_PATH updated."
    
    local r_host; r_host=$(hostname -f 2>/dev/null || hostname)
    local r_ip; r_ip=$(hostname -I | awk '{print $1}') # SC2012: Use 'hostname -I | cut -d" " -f1' for first IP. This is fine for simple cases.
    local welcome_sentinel="You are welcome to '${r_host}'"
    if ! grep -qF "$welcome_sentinel" "$GLOBAL_R_PROFILE_SITE_PATH"; then
        log "Adding welcome message to $GLOBAL_R_PROFILE_SITE_PATH..."
        # Using printf for the heredoc content to avoid issues with backticks or variables
        printf '%s\n' \
"
# Added by RStudio setup script $(date)
setHook(\"rstudio.sessionInit\", function(newSession) {
  if (newSession) {
    message(\"******************************************************************\")
    message(\"*** ${welcome_sentinel} - '${r_ip}' ***\")
    message(\"*** For personal R package installation:                       ***\")
    message(\"*** - Check .libPaths() for '$R_PROJECTS_ROOT/YOUR_USER/R/...' ***\")
    message(\"*** - If issues with bspm/PPM: bspm::disable() then install.packages() ***\")
    message(\"******************************************************************\")
  }
}, action = \"append\")" >> "$GLOBAL_R_PROFILE_SITE_PATH"
    fi; log "$GLOBAL_R_PROFILE_SITE_PATH updated."
    log "RStudio session/environment settings applied. Restarting RStudio Server..."
    run_command "systemctl restart rstudio-server"
}

uninstall_rstudio_configs() {
    log "Uninstalling RStudio Server configurations..."
    backup_config
    if systemctl is-active --quiet rstudio-server; then run_command "systemctl stop rstudio-server"; fi
    read -r -p "Remove RStudio Server package (apt remove --purge rstudio-server)? (y/n): " confirm_pkg
    if [[ "$confirm_pkg" == "y" || "$confirm_pkg" == "Y" ]]; then
        if dpkg -l | grep -q 'rstudio-server'; then run_command "apt-get remove --purge -y rstudio-server"
        else log "RStudio Server package not found."; fi
    else log "Skipping RStudio Server package removal."; fi
    log "Removing script-added configurations..."; run_command "rm -f $RSTUDIO_PROFILE_SCRIPT_PATH"
    log "RStudio configurations uninstalled. User data in $R_PROJECTS_ROOT not touched."
}

main_rstudio_menu() {
    while true; do
        # SC2059: Use printf for formatted output. echo -e is non-portable.
        printf "\n===== RStudio Configuration Menu =====\n"
        printf "1. Full RStudio Setup (Prerequisites, Server Conf, User Dirs, Temp, Session Env)\n"
        printf "2. Check RStudio Prerequisites & Configure rserver.conf (%s)\n" "$RSERVER_CONF_PATH"
        printf "3. Configure User Directories & Login Script (%s)\n" "$RSTUDIO_PROFILE_SCRIPT_PATH"
        printf "4. Configure Global RStudio Temporary Directory (%s)\n" "$GLOBAL_RSTUDIO_TMP_DIR"
        printf "5. Configure RStudio Session/Environment Settings & R Profile\n"
        printf "--------------------------------------\n"
        printf "S. Configure SSSD/Kerberos for AD Integration (Launches separate script)\n"
        printf "6. Test RStudio PAM Authentication (after SSSD/Kerberos setup)\n"
        printf "--------------------------------------\n"
        printf "7. Uninstall RStudio Configurations (profile script, optional package removal)\n"
        printf "8. Restore All Configurations from Last Backup\n"
        printf "9. Exit\n"
        printf "======================================\n"
        read -r -p "Enter choice: " choice

        case $choice in
            1) backup_config && check_rstudio_prerequisites && configure_rstudio_server_conf && \
               configure_rstudio_user_dirs_and_login_script && configure_rstudio_global_tmp && \
               configure_rstudio_session_env_settings && log "Full RStudio setup completed." || \
               log "Full RStudio setup failed or was interrupted."
               log "NOTE: SSSD/Kerberos setup is separate (Option S).";;
            2) backup_config && check_rstudio_prerequisites && configure_rstudio_server_conf ;;
            3) backup_config && check_rstudio_prerequisites && configure_rstudio_user_dirs_and_login_script ;;
            4) backup_config && check_rstudio_prerequisites && configure_rstudio_global_tmp ;;
            5) backup_config && check_rstudio_prerequisites && configure_rstudio_session_env_settings ;;
            S|s) if [[ -f "$SSSD_KERBEROS_SCRIPT_PATH" ]]; then
                    log "Launching SSSD/Kerberos Setup Script..."; bash "$SSSD_KERBEROS_SCRIPT_PATH"
                    log "Returned from SSSD/Kerberos Setup Script."
                 else log "ERROR: SSSD/Kerberos script ($SSSD_KERBEROS_SCRIPT_PATH) not found."; fi ;;
            6) test_rstudio_pam_auth ;; 
            7) uninstall_rstudio_configs ;;
            8) restore_config ;;
            9) log "Exiting RStudio Setup."; break ;;
            *) printf "Invalid choice. Please try again.\n" ;;
        esac
        [[ "$choice" != "9" ]] && read -r -p "Press Enter to continue..."
    done
}
log "=== RStudio Setup Script Started ==="
setup_backup_dir # Initialize backup dir when script starts
main_rstudio_menu
log "=== RStudio Setup Script Finished ==="
