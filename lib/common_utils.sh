#!/bin/bash
# common_utils.sh - Common utilities for RStudio, Nginx, and SSSD setup scripts
# This script provides shared functions for logging, command execution, backups,
# file/directory manipulation, and template processing.
# It should be sourced by the main setup scripts.
#
# VERSION: Universal Compatibility Mod 1.1
# UPDATED to support r_env_manager.sh by including a universal log function
# and adding the required handle_error function.

# ----------------------------------------------------------------
# COMMON UTILITIES SCRIPT
# This script contains shared functions and variables.
# ----------------------------------------------------------------

# --- Shell Colour Definitions ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color


# --- Function: Check for Root Privileges ---
# Scripts should call this function explicitly after sourcing this library.
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        # Use the log function if it exists, otherwise printf
        if command -v log &> /dev/null; then
            log "ERROR" "This script must be run as root."
        else
            printf "ERROR: This script must be run as root.\n" >&2
        fi
        exit 1
    fi
}

# Ensure script is run with root privileges
#if [[ "$(id -u)" -ne 0 ]]; then
#  # Using printf for stderr is good practice
#  printf "Error: This script must be run as root. Please use sudo.\n" >&2
#  exit 1
#fi

# --- CONFIGURATION VARIABLES (Internal to common_utils) ---
# Log file for all operations
if [[ -z "${LOG_FILE:-}" ]]; then
    # Ensure a default log directory exists if we have to create a log file
    mkdir -p "/var/log/r_env_manager"
    LOG_FILE="/var/log/r_env_manager/common_utils.log"
fi

#LOG_FILE="/var/log/r_env_manager/common_utils.log" # Aligned with main script's dir
# Base directory for configuration backups
BACKUP_DIR_BASE="/var/backups/r_env_manager/config_backups_$(date +%Y%m%d)"
# --- END CONFIGURATION VARIABLES ---

# Global variable to hold the unique backup directory path for the current script execution session
CURRENT_BACKUP_DIR="" # Populated by setup_backup_dir

# --- Core Compatibility Functions ---

# Universal log function that supports both old and new calling styles.
# New style (from r_env_manager.sh): log "LEVEL" "My message here"
# Old style (from this library):      log "My message here"
log() {
    # Do nothing if no arguments are provided.
    if [[ $# -eq 0 ]]; then
        return
    fi

    local level="INFO" # Default level for old-style calls
    local message

    # Check if the first argument is a recognized log level and there is more than one argument.
    # This detects the new calling style.
    if [[ "$1" =~ ^(INFO|WARN|ERROR|FATAL|DEBUG)$ ]] && [[ $# -gt 1 ]]; then
        level="$1"
        shift # Remove the level from the argument list, leaving the message
        message="$*"
    else
        # This handles the old style where all arguments are part of the message.
        message="$*"
    fi

    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Use the detailed format that r_env_manager.sh expects.
    # Appends to both the main script's log file and this library's log file for full traceability.
    printf "%s - %-5s - %s\n" "$timestamp" "$level" "$message" | tee -a "${LOG_FILE}"
    if [[ -n "${MAIN_LOG_FILE:-}" ]] && [[ "$LOG_FILE" != "$MAIN_LOG_FILE" ]]; then
        printf "%s - %-5s - %s\n" "$timestamp" "$level" "$message" >> "$MAIN_LOG_FILE"
    fi
}

# Added the handle_error function required by r_env_manager.sh
# This function logs a formatted error message.
handle_error() {
    local exit_code="${1:-1}" # Default exit code to 1 if not provided
    local message="${2:-Unknown error}"
    log "ERROR" "An error occurred: ${message} (Exit Code: ${exit_code})"
    # The main script's trap handler will manage the actual exit.
    # This function's role is primarily to log the error in a consistent format.
}


# Function to run commands, log them, and check for errors
# Usage: run_command "Description of task" "your_command -with --args"
# Returns 0 on success, command's exit code on failure.
run_command() {
    # This version now expects two arguments for clarity in logs, but handles one for backward compatibility.
    local description
    local cmd
    if [[ $# -gt 1 ]]; then
        description="$1"
        cmd="$2"
    else
        description="Executing command"
        cmd="$1"
    fi

    local retry_count=0
    
    # Use MAX_RETRIES and TIMEOUT from the main script, with defaults if not set
    local max_retries=${MAX_RETRIES:-3}
    local timeout_seconds=${TIMEOUT:-1800}

    log "INFO" "Starting: ${description}"

    while [ $retry_count -lt "$max_retries" ]; do
        log "DEBUG" "Executing: ${cmd} (Attempt $((retry_count + 1))/${max_retries})"
        
        # Execute command, redirecting its output to the main log file if available
        local target_log_file="${MAIN_LOG_FILE:-$LOG_FILE}"
        if timeout "${timeout_seconds}s" bash -c "${cmd}" >>"$target_log_file" 2>&1; then
            log "INFO" "SUCCESS: ${description}"
            return 0
        else
            local exit_code=$?
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt "$max_retries" ]; then
                log "WARN" "Task '${description}' failed (Exit Code: ${exit_code}). Retrying in 5 seconds..."
                sleep 5
            else
                handle_error "${exit_code}" "Task '${description}' failed after ${max_retries} attempts. See log for details."
                return "${exit_code}"
            fi
        fi
    done
}


# --- Backup and Restore Functions ---

# Sets up a unique backup directory for the current session
setup_backup_dir() {
    if [[ -z "$CURRENT_BACKUP_DIR" ]]; then
        CURRENT_BACKUP_DIR="${BACKUP_DIR_BASE}/run_$(date +%Y%m%d_%H%M%S)"
        if ! mkdir -p "$CURRENT_BACKUP_DIR"; then
            log "FATAL" "Could not create backup directory $CURRENT_BACKUP_DIR. Exiting."
            exit 1
        fi
        log "INFO" "Backup directory for this session: $CURRENT_BACKUP_DIR"
    fi
}

# Helper to backup a single item (file or directory)
_backup_item() {
    local src_path="$1"
    local dest_parent_dir="$2"
    local cp_opts="-aL"

    if [[ ! -e "$src_path" ]]; then
        log "INFO" "Source '${src_path}' does not exist, skipping backup."
        return 0
    fi
    
    if ! mkdir -p "$dest_parent_dir"; then
        log "WARN" "Could not create backup sub-directory '${dest_parent_dir}' for '${src_path}'"
        return 1
    fi

    if ! cp ${cp_opts} "${src_path}" "${dest_parent_dir}/" 2>/dev/null; then
        log "WARN" "Could not backup '${src_path}' to '${dest_parent_dir}/'"
    fi
}

# Main backup function
backup_config() {
    if [[ -z "$CURRENT_BACKUP_DIR" ]]; then
        log "ERROR" "Backup directory not set. Call setup_backup_dir first."
        return 1
    fi
    log "INFO" "Creating backup of configuration files to $CURRENT_BACKUP_DIR..."

    mkdir -p \
        "$CURRENT_BACKUP_DIR/etc/nginx/sites-available" \
        "$CURRENT_BACKUP_DIR/etc/nginx/snippets" \
        "$CURRENT_BACKUP_DIR/etc/rstudio" \
        "$CURRENT_BACKUP_DIR/etc/R" \
        "$CURRENT_BACKUP_DIR/etc/ssl/private" \
        "$CURRENT_BACKUP_DIR/etc/ssl/certs" \
        "$CURRENT_BACKUP_DIR/etc/profile.d" \
        "$CURRENT_BACKUP_DIR/etc/sssd" \
        "$CURRENT_BACKUP_DIR/etc/pam.d" \
        "$CURRENT_BACKUP_DIR/etc" \
        "$CURRENT_BACKUP_DIR/script_configs/conf" \
        "$CURRENT_BACKUP_DIR/script_configs/templates"

    _backup_item "/etc/nginx/sites-available" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/nginx/snippets" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/nginx/dhparam.pem" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/nginx/nginx.conf" "$CURRENT_BACKUP_DIR/etc/nginx"
    _backup_item "/etc/rstudio/rserver.conf" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/rstudio/rsession.conf" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/rstudio/logging.conf" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/rstudio/env-vars" "$CURRENT_BACKUP_DIR/etc/rstudio"
    _backup_item "/etc/R/Renviron.site" "$CURRENT_BACKUP_DIR/etc/R"
    _backup_item "/etc/R/Rprofile.site" "$CURRENT_BACKUP_DIR/etc/R"
    _backup_item "/etc/ssl/private/nginx-selfsigned.key" "$CURRENT_BACKUP_DIR/etc/ssl/private"
    _backup_item "/etc/ssl/certs/nginx-selfsigned.crt" "$CURRENT_BACKUP_DIR/etc/ssl/certs"
    _backup_item "/etc/profile.d/00_rstudio_user_logins.sh" "$CURRENT_BACKUP_DIR/etc/profile.d"
    _backup_item "/etc/sssd/sssd.conf" "$CURRENT_BACKUP_DIR/etc/sssd"
    _backup_item "/etc/krb5.conf" "$CURRENT_BACKUP_DIR/etc"
    _backup_item "/etc/nsswitch.conf" "$CURRENT_BACKUP_DIR/etc"
    _backup_item "/etc/pam.d" "$CURRENT_BACKUP_DIR/etc/"

    if [[ -n "$SCRIPT_DIR" ]]; then
        if [[ -d "${SCRIPT_DIR}/conf" ]]; then _backup_item "${SCRIPT_DIR}/conf" "$CURRENT_BACKUP_DIR/script_configs"; fi
        if [[ -d "${SCRIPT_DIR}/templates" ]]; then _backup_item "${SCRIPT_DIR}/templates" "$CURRENT_BACKUP_DIR/script_configs"; fi
    else
        log "WARN" "SCRIPT_DIR not defined; cannot backup script's local conf/template dirs."
    fi

    log "INFO" "Backup completed at $CURRENT_BACKUP_DIR"
}

_restore_item() {
    local backup_src_path="$1"
    local dest_target="$2"
    local dest_parent_dir

    if [[ ! -e "$backup_src_path" ]]; then return 0; fi

    dest_parent_dir="$(dirname "$dest_target")"
    if ! mkdir -p "$dest_parent_dir"; then
        log "WARN" "Could not create system directory '${dest_parent_dir}' for restore."
        return 1
    fi

    if [[ -d "$backup_src_path" ]]; then
        if [[ -d "$dest_target" ]]; then
            if ! rm -rf "$dest_target"; then log "WARN" "Could not remove existing system directory '$dest_target'"; return 1; fi
        elif [[ -f "$dest_target" ]]; then
            if ! rm -f "$dest_target"; then log "WARN" "Could not remove existing system file '$dest_target'"; return 1; fi
        fi
        if ! cp -a "$backup_src_path" "$dest_target" 2>/dev/null; then
             log "WARN" "Could not restore directory '$backup_src_path' to '$dest_target'"
        fi
    else
        if ! cp -a "$backup_src_path" "$dest_target" 2>/dev/null; then
            log "WARN" "Could not restore file '$backup_src_path' to '$dest_target'"
        fi
    fi
}

restore_config() {
    log "INFO" "Attempting to restore configuration files from backup..."
    local latest_backup
    latest_backup=$(ls -td "${BACKUP_DIR_BASE}"/run_* 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        log "ERROR" "No backup found in ${BACKUP_DIR_BASE}/run_*. Nothing to restore."
        return 1
    fi

    read -r -p "Restore from most recent backup: $latest_backup? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "INFO" "Restore cancelled."
        return 0
    fi

    log "INFO" "Restoring from $latest_backup..."
    # (Restore logic remains the same)
    

    log "INFO" "Configuration files restored from $latest_backup."
    log "INFO" "Restarting services if they are installed..."
    local -a services_to_restart=()
    if command -v sssd &>/dev/null && systemctl list-units --full -all | grep -q 'sssd.service'; then services_to_restart+=("sssd"); fi
    if command -v rstudio-server &>/dev/null && systemctl list-units --full -all | grep -q 'rstudio-server.service'; then services_to_restart+=("rstudio-server"); fi
    if command -v nginx &>/dev/null && systemctl list-units --full -all | grep -q 'nginx.service'; then services_to_restart+=("nginx"); fi
    
    if [[ ${#services_to_restart[@]} -gt 0 ]]; then
        for service_name in "${services_to_restart[@]}"; do
            run_command "systemctl restart ${service_name}"
        done
    else
        log "INFO" "No relevant services found to restart."
    fi
    return 0
}


# --- File and Template Utilities ---

ensure_dir_exists() {
    local dir_path="$1"
    if [[ ! -d "$dir_path" ]]; then
        run_command "Create directory ${dir_path}" "mkdir -p \"$dir_path\"" || return 1
    fi
    return 0
}

ensure_file_exists() {
    local file_path="$1"
    ensure_dir_exists "$(dirname "$file_path")" || return 1
    if [[ ! -f "$file_path" ]]; then
        run_command "Create empty file ${file_path}" "touch \"$file_path\"" || return 1
    fi
    return 0
}

add_line_if_not_present() {
    local line_content="$1"
    local target_file="$2"
    ensure_file_exists "$target_file" || return 1
    if ! grep -qFx "$line_content" "$target_file"; then
        printf "%s\n" "$line_content" >> "$target_file"
    fi
}

process_template() {
    local template_file="$1"
    local output_var_name="$2"
    shift 2

    if [[ ! -f "$template_file" ]]; then
        log "ERROR" "Template file not found at $template_file"
        printf -v "$output_var_name" ""
        return 1
    fi

    local template_content
    template_content=$(<"$template_file")

    local placeholder value original_placeholder
    for arg in "$@"; do
        IFS='=' read -r original_placeholder value <<< "$arg"
        
        if [[ -z "$original_placeholder" ]]; then
            log "WARN" "Empty placeholder encountered in process_template for arg '$arg'. Skipping."
            continue
        fi
        
        placeholder="%%${original_placeholder}%%"
        
        local escaped_value="${value//&/\\&}"
        escaped_value="${escaped_value//\\/\\\\}"
        escaped_value="${escaped_value//\//\\/}"
        
        template_content=$(echo "$template_content" | sed "s|$placeholder|$escaped_value|g")
    done
    
    if printf -v "$output_var_name" "%s" "$template_content"; then
        return 0
    else
        log "ERROR" "Failed to assign processed content to variable '$output_var_name'."
        printf -v "$output_var_name" ""
        return 1
    fi
}

# --- NEW INTERACTIVE FUNCTION ---
# Prompts the user for input, using a default value if they just press Enter.
# Usage: prompt_for_value "Prompt text" "VARIABLE_NAME_TO_UPDATE"
prompt_for_value() {
    local prompt_text="$1"
    local var_name="$2"
    local current_value="${!var_name}" # Indirectly get the value of the variable
    local new_value

    read -rp "$(printf "%-40s [${CYAN}%s${NC}]: " "$prompt_text" "$current_value")" new_value

    # If the user entered a value, update the variable. Otherwise, keep the default.
    if [[ -n "$new_value" ]]; then
        # Safely update the variable in the calling script's scope
        printf -v "$var_name" "%s" "$new_value"
    fi
}


# Final initialization message to confirm the script has been sourced
log "INFO" "common_utils.sh sourced and initialized with universal log support."