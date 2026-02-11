#!/bin/bash
# common_utils.sh - Common utilities for RStudio, Nginx, and SSSD setup scripts
# This script provides shared functions for logging, command execution, backups,
# file/directory manipulation, and template processing.
# It should be sourced by the main setup scripts.
#
# VERSION: Universal Compatibility Mod 1.4 - CORRECTED man-db suppression
# UPDATED: Removed invalid dpkg.cfg.d configuration
# KEY FIX: Uses ONLY valid dpkg options and environment variables

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
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        if command -v log &> /dev/null; then
            log "ERROR" "This script must be run as root."
        else
            printf "ERROR: This script must be run as root.\n" >&2
        fi
        exit 1
    fi
}

# Check for required dependencies/tools
# Usage: check_dependencies "jq" "curl" "systemctl"
check_dependencies() {
    local missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR" "Missing required dependencies: ${missing[*]}"
        log "INFO" "Install with: apt-get install ${missing[*]}"
        return 1
    fi
    return 0
}

# Verify Bash version (4.0+ required for associative arrays)
check_bash_version() {
    local required_major="${1:-4}"
    local current_major="${BASH_VERSINFO[0]}"
    
    if [[ "$current_major" -lt "$required_major" ]]; then
        log "ERROR" "Bash version $required_major.0+ required (current: ${BASH_VERSION})"
        return 1
    fi
    return 0
}

# --- CONFIGURATION VARIABLES (Internal to common_utils) ---
if [[ -z "${LOG_FILE:-}" ]]; then
    mkdir -p "/var/log/r_env_manager"
    LOG_FILE="/var/log/r_env_manager/common_utils.log"
fi

BACKUP_DIR_BASE="/var/backups/r_env_manager/config_backups_$(date +%Y%m%d)"
CURRENT_BACKUP_DIR=""

# --- Core Compatibility Functions ---

# Configure system for non-interactive operation
# ENHANCED v1.4: Corrected - uses ONLY valid dpkg options
setup_noninteractive_mode() {
    if [[ "${NONINTERACTIVE_CONFIGURED:-}" == "true" ]]; then
        return 0
    fi

    log "INFO" "Configuring system for non-interactive operation..."
    
    # === SYSTEM-WIDE NONINTERACTIVE SETTINGS ===
    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export APT_LISTCHANGES_FRONTEND=none
    export NEEDRESTART_MODE=a
    
    # === ADDITIONAL ENVIRONMENT SUPPRESSIONS ===
    # These environment variables help suppress man-db interactions
    export MANPAGER=/bin/true
    export MAN_DB_IGNORE_UPDATES=1
    
    # === DISABLE MAN-DB AUTO-UPDATE ===
    if ! debconf-get-selections 2>/dev/null | grep -q "man-db/auto-update.*false"; then
        log "INFO" "Disabling man-db auto-update..."
        echo "set man-db/auto-update false" | debconf-communicate >/dev/null 2>&1 || true
        dpkg-reconfigure -p critical man-db >/dev/null 2>&1 || true
    fi

    # === CONFIGURE DPKG TO SKIP DOCUMENTATION ===
    local nodoc_conf="/etc/dpkg/dpkg.cfg.d/01_nodoc"
    if [[ ! -f "$nodoc_conf" ]] || ! grep -q "path-exclude /usr/share/man" "$nodoc_conf" 2>/dev/null; then
        log "INFO" "Configuring dpkg to skip documentation..."
        mkdir -p "$(dirname "$nodoc_conf")"
        cat > "$nodoc_conf" << 'EOF'
# Automatically added by common_utils.sh to prevent documentation triggers
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/locale/*
path-include /usr/share/locale/*/LC_MESSAGES/*.mo
EOF
        log "INFO" "Created $nodoc_conf to skip documentation"
        dpkg --clear-avail || true
    fi

    # === VERIFY CONFIGURATION ===
    local config_status="OK"
    if [[ ! -f "$nodoc_conf" ]]; then
        config_status="WARNING: $nodoc_conf not created"
    fi
    if ! debconf-get-selections 2>/dev/null | grep -q "man-db/auto-update.*false"; then
        config_status="WARNING: man-db auto-update not disabled"
    fi

    if [[ "$config_status" == "OK" ]]; then
        log "INFO" "Non-interactive mode configured successfully"
    else
        log "WARN" "Non-interactive mode configuration issues: $config_status"
    fi

    export NONINTERACTIVE_CONFIGURED="true"
}


# Run lightweight apt/dpkg health checks
check_apt_health() {
    log "INFO" "Running apt/dpkg health checks..."

    # 1) Try to finish any interrupted configuration
    if dpkg --configure -a >/dev/null 2>&1; then
        log "DEBUG" "dpkg --configure -a completed"
    else
        log "WARN" "dpkg --configure -a returned non-zero (see logs)"
    fi

    # 2) Attempt to fix broken dependencies (non-interactive)
    if command -v apt-get >/dev/null 2>&1; then
        if DEBIAN_FRONTEND=noninteractive apt-get -y -f install </dev/null >/dev/null 2>&1; then
            log "DEBUG" "apt-get -f install completed"
        else
            log "WARN" "apt-get -f install returned non-zero (see logs)"
        fi
    fi

    # 3) Check for and remove stale lock files
    for lock in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock; do
        if [[ -e "$lock" ]]; then
            if lsof "$lock" >/dev/null 2>&1 || fuser "$lock" >/dev/null 2>&1; then
                log "DEBUG" "Lock $lock is held by a running process"
            else
                log "WARN" "Removing stale lock file $lock"
                rm -f "$lock" || log "ERROR" "Failed to remove stale lock $lock"
            fi
        fi
    done

    # 4) Check disk space on root and /var
    local avail_root avail_var
    avail_root=$(df --output=pcent / | tail -1 | tr -dc '0-9') || avail_root=0
    avail_var=$(df --output=pcent /var 2>/dev/null | tail -1 | tr -dc '0-9' ) || avail_var=$avail_root
    if [[ -n "$avail_root" && "$avail_root" -ge 95 ]]; then
        log "WARN" "Low disk space on / (used ${avail_root}%). apt operations may fail."
    fi
    if [[ -n "$avail_var" && "$avail_var" -ge 95 ]]; then
        log "WARN" "Low disk space on /var (used ${avail_var}%). apt operations may fail."
    fi

    log "DEBUG" "Apt/dpkg health checks complete"
}

# Universal log function
log() {
    if [[ $# -eq 0 ]]; then
        return
    fi

    local level="INFO"
    local message

    if [[ "$1" =~ ^(INFO|WARN|ERROR|FATAL|DEBUG)$ ]] && [[ $# -gt 1 ]]; then
        level="$1"
        shift
        message="$*"
    else
        message="$*"
    fi

    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    printf "%s - %-5s - %s\n" "$timestamp" "$level" "$message" | tee -a "${LOG_FILE}"
    if [[ -n "${MAIN_LOG_FILE:-}" ]] && [[ "$LOG_FILE" != "$MAIN_LOG_FILE" ]]; then
        printf "%s - %-5s - %s\n" "$timestamp" "$level" "$message" >> "$MAIN_LOG_FILE"
    fi
}

# Handle errors
handle_error() {
    local exit_code="${1:-1}"
    local message="${2:-Unknown error}"
    log "ERROR" "An error occurred: ${message} (Exit Code: ${exit_code})"
}


# Function to run commands with automatic error handling and retries
# ENHANCED v1.4: Corrected with VALID dpkg options only
run_command() {
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
    local max_retries=${MAX_RETRIES:-3}
    local timeout_seconds=${TIMEOUT:-1800}

    log "INFO" "Starting: ${description}"

    while [ $retry_count -lt "$max_retries" ]; do
        log "DEBUG" "Executing: ${cmd} (Attempt $((retry_count + 1))/${max_retries})"
        
        local target_log_file="${MAIN_LOG_FILE:-$LOG_FILE}"
        local first_word
        first_word=$(awk '{print $1}' <<<"${cmd}")

        # Handle sudo prefix
        if [[ "${first_word}" == "sudo" ]]; then
            local second_word
            second_word=$(awk '{print $2}' <<<"${cmd}")
            if [[ "${second_word}" == "apt-get" || "${second_word}" == "apt" ]]; then
                cmd="${cmd#sudo }"
                first_word="${second_word}"
            fi
        fi

        # Detect and handle composite apt commands (e.g., "apt-get update && apt-get install -y pkg")
        # Split on && and run each apt command separately so each gets proper wrapper treatment
        if [[ "${first_word}" == "apt-get" || "${first_word}" == "apt" ]] && [[ "${cmd}" == *"&&"* ]]; then
            log "DEBUG" "Detected composite apt command; splitting and running sequentially..."
            local -a parts
            IFS='&&' read -ra parts <<<"${cmd}"
            for part in "${parts[@]}"; do
                part="${part#"${part%%[![:space:]]*}"}"  # Left trim
                part="${part%"${part##*[![:space:]]}"}"  # Right trim
                if [[ -z "$part" ]]; then
                    continue
                fi
                log "DEBUG" "Running composite part: $part"
                if ! run_command "${description}" "$part"; then
                    return $?
                fi
            done
            log "INFO" "SUCCESS: ${description}"
            return 0
        fi

        # Check if this is an apt/apt-get command
        if [[ "${first_word}" == "apt-get" || "${first_word}" == "apt" ]]; then
            setup_noninteractive_mode
            check_apt_health

            local rest
            rest="${cmd#${first_word}}"
            
            # Determine timeout based on operation
            local cmd_timeout=180
                if [[ "${cmd}" =~ (install|upgrade|dist-upgrade) ]] && [[ "${rest}" != *"update"* ]]; then
                cmd_timeout=300
            elif [[ "${cmd}" =~ update ]]; then
                cmd_timeout=120
            elif [[ "${cmd}" =~ (remove|purge|autoremove) ]]; then
                cmd_timeout=180
            fi
            
            # Build command array
            local -a cmd_array=()
            cmd_array+=(timeout)
            cmd_array+=(--kill-after=30s)
            cmd_array+=("${cmd_timeout}s")
            cmd_array+=("${first_word}")
            
            # Determine if -y is needed
            local need_yes=0
            if [[ "${rest}" =~ ^[[:space:]]*(install|remove|purge|upgrade|dist-upgrade|autoremove)[[:space:]] ]]; then
                if [[ "${rest}" != *" -y"* ]] && [[ "${rest}" != *" --yes"* ]]; then
                    need_yes=1
                fi
            fi
            
            if [ "$need_yes" -eq 1 ]; then
                cmd_array+=(-y)
                log "DEBUG" "Adding -y flag to prevent prompts"
            fi
            
            # Add dpkg options with man-db suppression (VALID OPTIONS ONLY - v1.4)
            if [[ "${cmd}" != *"Dpkg::Options::="* ]]; then
                # Force noninteractive configuration
                cmd_array+=(-o "Dpkg::Options::=--force-confdef")
                cmd_array+=(-o "Dpkg::Options::=--force-confold")
                
                # Prevent install of recommended packages
                cmd_array+=(--no-install-recommends)
                
                # Disable progress and status output
                cmd_array+=(-o "Dpkg::Progress-Fancy=0")
                cmd_array+=(-o "Dpkg::Progress=0")
                
                # Extra assurance for non-interactive mode
                cmd_array+=(-o "APT::Get::Assume-Yes=true")
                cmd_array+=(-o "APT::Get::allow-unauthenticated=false")
                cmd_array+=(-o "Dpkg::Use-Pty=0")
                
                # === MAN-DB SUPPRESSION (VALID DPKG OPTIONS - v1.4) ===
                # These are official dpkg options that work reliably
                cmd_array+=(-o "DPkg::Pre-Install-Pkgs::=/bin/true")
                cmd_array+=(-o "DPkg::Post-Invoke::=/bin/true")
            fi
            
            # Parse rest of command
            local -a rest_args
            read -ra rest_args <<<"${rest}"
            cmd_array+=("${rest_args[@]}")
            
            log "DEBUG" "Command array: ${cmd_array[*]}"
            
            # Determine stdin handling: redirect to /dev/null for non-interactive apt,
            # but allow stdin for interactive commands (INTERACTIVE=true)
            local stdin_source="/dev/null"
            if [[ "${INTERACTIVE:-false}" == "true" ]]; then
                stdin_source="/dev/stdin"
                log "DEBUG" "Running in interactive mode (stdin will be available)"
            fi
            
            # Execute with stdin handling based on INTERACTIVE flag
            set -o pipefail
            
            if env \
                DEBIAN_FRONTEND=noninteractive \
                DEBCONF_NONINTERACTIVE_SEEN=true \
                APT_LISTCHANGES_FRONTEND=none \
                NEEDRESTART_MODE=a \
                DPKG_TRIGGER_TIMEOUT=30 \
                MAN_DB_DISABLE_UPDATE=1 \
                MANDB_DONT_UPDATE=1 \
                MANPAGER=/bin/true \
                MAN_DB_IGNORE_UPDATES=1 \
                "${cmd_array[@]}" < "$stdin_source" 2>&1 | tee -a "$target_log_file"; then
                local exit_code=${PIPESTATUS[0]}
                set +o pipefail
                
                if [ "$exit_code" -eq 0 ]; then
                    log "INFO" "SUCCESS: ${description}"
                    return 0
                else
                    set +o pipefail
                    retry_count=$((retry_count + 1))
                    
                    if [ $retry_count -lt "$max_retries" ]; then
                        log "WARN" "Task '${description}' failed (Exit Code: ${exit_code}). Retrying in 5 seconds..."
                        sleep 5
                    else
                        handle_error "${exit_code}" "Task '${description}' failed after ${max_retries} attempts. See log for details."
                        return "${exit_code}"
                    fi
                fi
            else
                local exit_code=${PIPESTATUS[0]}
                set +o pipefail
                retry_count=$((retry_count + 1))
                
                if [ $retry_count -lt "$max_retries" ]; then
                    log "WARN" "Task '${description}' failed (Exit Code: ${exit_code}). Retrying in 5 seconds..."
                    sleep 5
                else
                    handle_error "${exit_code}" "Task '${description}' failed after ${max_retries} attempts. See log for details."
                    return "${exit_code}"
                fi
            fi
        else
            # Non-apt commands
            local cmd_timeout="${timeout_seconds}"
            
            # Determine stdin handling for non-apt commands too
            local stdin_source="/dev/null"
            if [[ "${INTERACTIVE:-false}" == "true" ]]; then
                stdin_source="/dev/stdin"
                log "DEBUG" "Running non-apt command in interactive mode (stdin connected to terminal)"
            elif [ ! -t 0 ]; then
                stdin_source="/dev/stdin"
                log "DEBUG" "Detected piped input; enabling stdin for non-apt command"
            fi
            
            set -o pipefail
            
            # For interactive commands, run directly without piping (preserves terminal I/O)
            # For non-interactive, use bash -c with tee for logging
            if [[ "${INTERACTIVE:-false}" == "true" ]]; then
                # Interactive mode: run command directly without any piping
                # This preserves terminal control for password prompts and user input
                log "DEBUG" "Executing interactive command: $cmd"
                if timeout --kill-after=30s "${cmd_timeout}s" bash -c "${cmd}"; then
                    local exit_code=$?
                    set +o pipefail
                    log "INFO" "SUCCESS: ${description}"
                    return 0
                else
                    local exit_code=$?
                    set +o pipefail
                    retry_count=$((retry_count + 1))
                    
                    if [ $retry_count -lt "$max_retries" ]; then
                        log "WARN" "Task '${description}' failed (Exit Code: ${exit_code}). Retrying in 5 seconds..."
                        sleep 5
                    else
                        handle_error "${exit_code}" "Task '${description}' failed after ${max_retries} attempts. See log for details."
                        return "${exit_code}"
                    fi
                fi
            else
                # Non-interactive mode: pipe through tee for real-time logging
                if timeout --kill-after=30s "${cmd_timeout}s" bash -c "${cmd}" < "$stdin_source" 2>&1 | tee -a "$target_log_file"; then
                    local exit_code=${PIPESTATUS[0]}
                    set +o pipefail
                    
                    if [ "$exit_code" -eq 0 ]; then
                        log "INFO" "SUCCESS: ${description}"
                        return 0
                    else
                        set +o pipefail
                        retry_count=$((retry_count + 1))
                        
                        if [ $retry_count -lt "$max_retries" ]; then
                            log "WARN" "Task '${description}' failed (Exit Code: ${exit_code}). Retrying in 5 seconds..."
                            sleep 5
                        else
                            handle_error "${exit_code}" "Task '${description}' failed after ${max_retries} attempts. See log for details."
                            return "${exit_code}"
                        fi
                    fi
                else
                    local exit_code=${PIPESTATUS[0]}
                    set +o pipefail
                    retry_count=$((retry_count + 1))
                    
                    if [ $retry_count -lt "$max_retries" ]; then
                        log "WARN" "Task '${description}' failed (Exit Code: ${exit_code}). Retrying in 5 seconds..."
                        sleep 5
                    else
                        handle_error "${exit_code}" "Task '${description}' failed after ${max_retries} attempts. See log for details."
                        return "${exit_code}"
                    fi
                fi
            fi
        fi
    done
}


# --- Backup and Restore Functions ---

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
    log "INFO" "Configuration files restored from $latest_backup."
    log "INFO" "Restarting services if they are installed..."
    
    local -a services_to_restart=()
    if command -v sssd &>/dev/null && systemctl list-units --full -all | grep -q 'sssd.service'; then services_to_restart+=("sssd"); fi
    if command -v rstudio-server &>/dev/null && systemctl list-units --full -all | grep -q 'rstudio-server.service'; then services_to_restart+=("rstudio-server"); fi
    if command -v nginx &>/dev/null && systemctl list-units --full -all | grep -q 'nginx.service'; then services_to_restart+=("nginx"); fi
    
    if [[ ${#services_to_restart[@]} -gt 0 ]]; then
        for service_name in "${services_to_restart[@]}"; do
            run_command "Restart ${service_name}" "systemctl restart ${service_name}"
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

# --- Robust Template Processing ---
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
        
        local escaped_value
        # Escape backslashes, hash (sed delimiter), and ampersand (sed replacement)
        escaped_value=$(sed -e 's/\\/\\\\/g' -e 's/#/\\#/g' -e 's/&/\\&/g' <<<"$value")
        
        template_content=$(echo "$template_content" | sed "s#$placeholder#$escaped_value#g")
    done
    
    printf -v "$output_var_name" "%s" "$template_content"
    return 0
}

process_systemd_template() {
    local template_name=$1
    local service_name=$2
    local template_path="$template_name"
    local output_path=""

    if [[ "$service_name" == /* ]]; then
        output_path="$service_name"
    else
        output_path="/etc/systemd/system/${service_name}"
    fi
    
    log "INFO" "Processing template for ${output_path}..."
    ensure_dir_exists "$(dirname "$output_path")"

    local temp_file; temp_file=$(mktemp)
    local sed_script="";
    for var in $(grep -o '{{[A-Z_]*}}' "$template_path" | sort -u | tr -d '{}'); do
        sed_script+="s|{{\s*$var\s*}}|${!var}|g;"
    done
    
    sed "$sed_script" "$template_path" > "$temp_file"
    
    sudo mv "$temp_file" "$output_path"
    sudo chown root:root "$output_path"
    sudo chmod 644 "$output_path"
}


# --- Interactive Function ---
prompt_for_value() {
    local prompt_text="$1"
    local var_name="$2"
    local current_value="${!var_name}"
    local new_value

    read -rp "$(printf "%-40s [${CYAN}%s${NC}]: " "$prompt_text" "$current_value")" new_value

    if [[ -n "$new_value" ]]; then
        printf -v "$var_name" "%s" "$new_value"
    fi
}


# Final initialization message
log "INFO" "common_utils.sh v1.4 sourced and initialized with corrected man-db suppression (valid dpkg options only)."
