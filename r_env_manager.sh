#!/usr/bin/env bash

################################################################################
#
# R Environment Manager (`r_env_manager.sh`)
#
# Version: 1.1.0 (Cleaned and Corrected)
# Last Updated: 2025-09-09
#
# This script orchestrates the complete setup and management of an R
# development environment on Debian-based systems. It includes robust error
# handling, logging, state management, and maintenance features.
#
################################################################################

set -euo pipefail

# --- Source Utilities First ---
# By sourcing the library first, we allow this script's global variables to
# override any defaults set in the library, establishing a clear hierarchy.
# The SCRIPT_DIR is determined here to locate the library correctly.
SCRIPT_DIR_INIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR_INIT}/lib/common_utils.sh"

# --- Global Constants and Configuration ---
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="${SCRIPT_DIR_INIT}"

# Define critical paths. These will override any defaults from common_utils.sh
readonly LOG_DIR="/var/log/r_env_manager"
readonly BACKUP_DIR="/var/backups/r_env_manager"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"
readonly STATE_FILE="${SCRIPT_DIR}/.r_env_state"
readonly R_ENV_STATE_FILE="${SCRIPT_DIR}/.r_env_state_packages" # Specific file for package state
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
readonly LOCK_FILE="/var/run/${SCRIPT_NAME}.lock"
readonly PID_FILE="/var/run/${SCRIPT_NAME}.pid"
readonly CONFIG_FILE="${CONFIG_DIR}/r_env_manager.conf"

# Export the main log file path so the library can use it for command output
export MAIN_LOG_FILE="${LOG_FILE}"

# --- Global Variables ---
R_PROFILE_SITE_PATH="" # Will be determined dynamically
export MAX_RETRIES=3
export TIMEOUT=1800  # 30 minutes for long operations
export DEBIAN_FRONTEND=noninteractive
declare -A OPERATION_STATE

# --- Core Infrastructure Layer ---

acquire_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
        log "FATAL" "Another instance is running (PID: $pid). Lock file found: ${LOCK_FILE}"
        exit 1
    fi
    ensure_dir_exists "$(dirname "$LOCK_FILE")"
    touch "$LOCK_FILE"
    echo $$ > "$PID_FILE"
}

check_system_resources() {
    local min_memory=${MIN_MEMORY_MB:-2048}
    local min_disk=${MIN_DISK_MB:-5120}
    
    local available_memory
    available_memory=$(free -m | awk '/^Mem:/{print $7}')
    if (( available_memory < min_memory )); then
        handle_error 4 "Insufficient memory: ${available_memory}MB available, ${min_memory}MB required."
        return 1
    fi
    
    local available_disk
    available_disk=$(df -m "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    if (( available_disk < min_disk )); then
        handle_error 4 "Insufficient disk space: ${available_disk}MB available, ${min_disk}MB required."
        return 1
    fi
    return 0
}

setup_logging() {
    ensure_dir_exists "$LOG_DIR"
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 640 "$LOG_FILE"
    fi
    # Redirect stderr to log while maintaining console output
    exec 3>&2
    exec 2> >(tee -a "$LOG_FILE" >&2)
}

rotate_logs() {
    local max_size=$((50 * 1024 * 1024))  # 50MB
    local max_backups=5
    
    if [[ ! -f "$LOG_FILE" ]]; then return; fi
    
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > max_size )); then
        log "INFO" "Log file size ($size bytes) exceeds max size ($max_size bytes). Rotating."
        for ((i = max_backups - 1; i >= 1; i--)); do
            if [[ -f "${LOG_FILE}.$i" ]]; then
                mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i + 1))"
            fi
        done
        mv "$LOG_FILE" "${LOG_FILE}.1"
        touch "$LOG_FILE"
        chmod 640 "$LOG_FILE"
    fi
}

cleanup() {
    local exit_code=$?
    log "INFO" "Script execution ending with code: $exit_code"
    if [[ -f "$LOCK_FILE" ]]; then rm -f "$LOCK_FILE"; fi
    if [[ -f "$PID_FILE" ]]; then rm -f "$PID_FILE"; fi
    exec 2>&3 # Restore stderr
    exit "$exit_code"
}
trap cleanup EXIT
trap 'log "FATAL" "Received signal to terminate. Cleaning up..."; exit 1' HUP INT QUIT TERM

#check_security_requirements() {
#    if [[ $EUID -ne 0 ]]; then
#        log "FATAL" "This script must be run as root. Please use sudo."
#        exit 1
#    fi
#    
#    if [[ "$PATH" == *.* ]] || [[ "$PATH" == *:* ]]; then
#        log "FATAL" "Insecure PATH environment detected. Aborting."
#        exit 1
#    fi
#
#    for dir in "$LOG_DIR" "$BACKUP_DIR"; do
#        ensure_dir_exists "$dir"
#        chmod 750 "$dir"
#    done
#}

check_security_requirements() {
    if [[ $EUID -ne 0 ]]; then
        log "FATAL" "This script must be run as root. Please use sudo."
        exit 1
    fi
    
    # --- Corrected and More Precise PATH Security Check ---
    # The old check incorrectly flagged any path containing a '.', like '.local'.
    # This new version specifically checks for the dangerous current directory '.'
    # or empty path components '::' which can also be a security risk.
    local insecure_path_found=0
    local old_ifs="$IFS"
    IFS=':'
    for dir in $PATH; do
        if [[ "$dir" == "." ]] || [[ -z "$dir" ]]; then
            insecure_path_found=1
            break
        fi
    done
    IFS="$old_ifs"

    if [[ $insecure_path_found -eq 1 ]]; then
        log "FATAL" "Insecure PATH environment detected (contains '.' or '::'). Aborting."
        exit 1
    fi
    # --- End of Corrected Check ---

    for dir in "$LOG_DIR" "$BACKUP_DIR"; do
        ensure_dir_exists "$dir"
        chmod 750 "$dir"
    done
}

ensure_config_dir() {
    ensure_dir_exists "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "WARN" "Main configuration file not found at $CONFIG_FILE. Creating a default one."
        create_default_config
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        log "INFO" "Loading configuration from $CONFIG_FILE"
        # shellcheck disable=SC1090,SC1091
        source "$CONFIG_FILE"
    else
        log "FATAL" "Configuration file could not be created or loaded. Aborting."
        exit 1
    fi
}

create_default_config() {
    log "INFO" "Creating default configuration file at $CONFIG_FILE..."
    cat > "$CONFIG_FILE" << 'EOF'
# R Environment Manager Configuration
# Generated on: $(date)

# CRAN Repository Settings
CRAN_REPO_URL_BIN="https://cloud.r-project.org/bin/linux/ubuntu"
CRAN_APT_KEY_URL="https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc"
CRAN_APT_KEYRING_FILE="/etc/apt/trusted.gpg.d/cran.gpg"

# R2U Repository Settings
R2U_REPO_URL_BASE="https://r2u.stat.illinois.edu"
R2U_APT_SOURCES_LIST_D_FILE="/etc/apt/sources.list.d/r2u.list"

# RStudio Server Settings
RSTUDIO_VERSION_FALLBACK="2023.06.0"
RSTUDIO_ARCH_FALLBACK="amd64"

# R Package Lists
R_USER_PACKAGES_CRAN=(
    "tidyverse"
    "devtools"
    "rmarkdown"
)

R_USER_PACKAGES_GITHUB=(
    "rstudio/renv"
    "r-lib/cli"
)

# Backup Settings
MAX_BACKUPS=5
BACKUP_RETENTION_DAYS=30

# System Requirements
MIN_MEMORY_MB=2048
MIN_DISK_MB=5120
EOF
    chmod 640 "$CONFIG_FILE"
    log "INFO" "Default configuration created successfully."
}

# --- Implemented Helper Functions (Formerly Placeholders) ---

validate_configuration() {
    log "INFO" "Validating configuration..."
    local required_vars=("CRAN_REPO_URL_BIN" "CRAN_APT_KEY_URL" "R_USER_PACKAGES_CRAN")
    local missing=0
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log "ERROR" "Configuration validation failed: Required variable '${var}' is not set in ${CONFIG_FILE}."
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then return 1; else log "INFO" "Configuration appears valid."; return 0; fi
}

display_installation_status() {
    log "INFO" "--- Current Installation Status ---"
    # Check for R
    if command -v R &>/dev/null; then
        log "INFO" "R Installation: DETECTED - $(R --version | head -n 1)"
    else
        log "INFO" "R Installation: NOT FOUND"
    fi
    # Check for RStudio Server
    if command -v rstudio-server &>/dev/null; then
        log "INFO" "RStudio Server: DETECTED - Version $(rstudio-server version)"
        if systemctl is-active --quiet rstudio-server; then
            log "INFO" "RStudio Status: ACTIVE (running)"
        else
            log "WARN" "RStudio Status: INACTIVE (not running)"
        fi
    else
        log "INFO" "RStudio Server: NOT FOUND"
    fi
    log "INFO" "-----------------------------------"
}

pre_flight_checks() {
    log "INFO" "Performing pre-flight checks..."
    # Check for essential commands
    local commands=("awk" "grep" "curl" "gpg" "tee" "stat" "free" "df" "ldd")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "FATAL" "Essential command '${cmd}' not found. Please install it."
            exit 1
        fi
    done
    log "INFO" "All essential commands are present."
    return 0
}

get_state() {
    local key="$1"
    local default_value="${2:-}"
    if [[ -v "OPERATION_STATE[$key]" ]]; then echo "${OPERATION_STATE[$key]}"; else echo "$default_value"; fi
}

backup_file() {
    local file_path="$1"
    if [[ ! -e "$file_path" ]]; then
        log "WARN" "Cannot backup '${file_path}': file does not exist."
        return 1
    fi
    local backup_target_dir="${BACKUP_DIR}/files/$(dirname "${file_path}")"
    ensure_dir_exists "$backup_target_dir"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_name
    backup_name="$(basename "$file_path").${timestamp}.bak"
    
    log "INFO" "Backing up '${file_path}' to '${backup_target_dir}/${backup_name}'"
    cp -aL "${file_path}" "${backup_target_dir}/${backup_name}"
}

restore_latest_backup() {
    local file_path="$1"
    local backup_search_dir="${BACKUP_DIR}/files/$(dirname "${file_path}")"
    if [[ ! -d "$backup_search_dir" ]]; then
        log "ERROR" "Cannot restore '${file_path}': no backup directory found at '${backup_search_dir}'."
        return 1
    fi
    
    local latest_backup
    latest_backup=$(find "$backup_search_dir" -type f -name "$(basename "$file_path")*.bak" | sort -r | head -n 1)
    
    if [[ -z "$latest_backup" ]]; then
        log "ERROR" "No backup found for '${file_path}' in '${backup_search_dir}'."
        return 1
    fi
    
    log "INFO" "Restoring '${file_path}' from latest backup: '${latest_backup}'"
    cp -a "${latest_backup}" "${file_path}"
}

verify_secure_permissions() {
    local path="$1"
    local expected_perms="$2"
    log "DEBUG" "Verifying permissions for ${path}..."
    if [[ ! -e "$path" ]]; then
        log "WARN" "Cannot verify permissions for '${path}': path does not exist."
        return 1
    fi
    local current_perms
    current_perms=$(stat -c "%a" "$path")
    if [[ "$current_perms" != "$expected_perms" ]]; then
        log "WARN" "Permissions for '${path}' are '${current_perms}', expected '${expected_perms}'."
        return 1
    fi
    return 0
}

# --- State Management ---
save_state() {
    local operation=$1
    local status=$2
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    OPERATION_STATE["${operation}_status"]=$status
    OPERATION_STATE["${operation}_timestamp"]=$timestamp
    
    {
        echo "# R Environment Manager State - $timestamp"
        for key in "${!OPERATION_STATE[@]}"; do
            echo "${key}=${OPERATION_STATE[$key]}"
        done
    } > "$STATE_FILE"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        log "INFO" "Loading previous operation state from $STATE_FILE"
        while IFS='=' read -r key value; do
            [[ $key == \#* ]] && continue
            OPERATION_STATE["$key"]=$value
        done < "$STATE_FILE"
    fi
}

# --- Core Helper Functions ---
get_r_profile_site_path() {
    if [[ -n "${USER_SPECIFIED_R_PROFILE_SITE_PATH:-}" ]]; then
        R_PROFILE_SITE_PATH="$USER_SPECIFIED_R_PROFILE_SITE_PATH"
        log "INFO" "Using user-specified R_PROFILE_SITE_PATH: ${R_PROFILE_SITE_PATH}"
        return
    fi

    if command -v R &>/dev/null; then
        local r_home
        r_home=$(R RHOME 2>/dev/null)
        if [[ -n "$r_home" && -d "$r_home" ]]; then
            R_PROFILE_SITE_PATH="${r_home}/etc/Rprofile.site"
            log "INFO" "Auto-detected R_PROFILE_SITE_PATH (from R RHOME): ${R_PROFILE_SITE_PATH}"
            return
        fi
    fi

    R_PROFILE_SITE_PATH="/usr/lib/R/etc/Rprofile.site"
    log "INFO" "Defaulting Rprofile.site to standard location: ${R_PROFILE_SITE_PATH}"
}

is_vm_or_ci_env() {
    if [[ "${CI:-false}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -f /.dockerenv ]]; then
        return 0
    else
        return 1
    fi
}

# --- RStudio Server Functions ---
get_latest_rstudio_info() {
    log "INFO" "Detecting latest RStudio Server version..."
    # Fallback values from config
    local rstudio_version=${RSTUDIO_VERSION_FALLBACK:-"2023.06.0"}
    local rstudio_arch=${RSTUDIO_ARCH_FALLBACK:-"amd64"}

    local html
    html=$(curl -fsSL "https://rstudio.com/products/rstudio/download-server/" 2>/dev/null || true)

    if [[ -n "$html" ]]; then
        # Attempt to parse a modern version format
        local parsed_version
        parsed_version=$(echo "$html" | grep -oP 'rstudio-server-[\d.]+-amd64\.deb' | head -n1 | sed -E 's/rstudio-server-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)-amd64\.deb/\1/')
        if [[ -n "$parsed_version" ]]; then
             rstudio_version="$parsed_version"
        fi
    fi

    RSTUDIO_DEB_FILENAME="rstudio-server-${rstudio_version}-${rstudio_arch}.deb"
    RSTUDIO_DEB_URL="https://download2.rstudio.org/server/bionic/${rstudio_arch}/${RSTUDIO_DEB_FILENAME}"
    log "INFO" "Using RStudio Server version: ${rstudio_version}"
}

#install_rstudio_server() {
#    if systemctl is-active --quiet rstudio-server; then
#        log "INFO" "RStudio Server is already installed and running."
#        return 0
#    fi
#    
#    get_latest_rstudio_info
#    
#    log "INFO" "Installing RStudio Server..."
#    local rstudio_deb_path="/tmp/${RSTUDIO_DEB_FILENAME}"
    
#    run_command "Download RStudio Server" "wget -O \"${rstudio_deb_path}\" \"${RSTUDIO_DEB_URL}\""
#    run_command "Install RStudio Server package" "apt-get install -y \"${rstudio_deb_path}\""
#    rm -f "$rstudio_deb_path"
#     run_command "Enable and start RStudio Server" "systemctl enable --now rstudio-server"
#    
#    log "INFO" "RStudio Server installation complete."
#}

install_rstudio_server() {
    if systemctl is-active --quiet rstudio-server; then
        log "INFO" "RStudio Server is already installed and running."
        return 0
    fi
    
    get_latest_rstudio_info
    
    log "INFO" "Installing RStudio Server..."
    local rstudio_deb_path="/tmp/${RSTUDIO_DEB_FILENAME}"
    
    # Downloading the file is fine with run_command
    run_command "Download RStudio Server" "wget -O \"${rstudio_deb_path}\" \"${RSTUDIO_DEB_URL}\""
    
    # --- MODIFIED BLOCK ---
    # Call apt-get directly to prevent hanging on hidden prompts and to show progress.
    log "INFO" "Installing the downloaded .deb package. Apt output will be displayed below:"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "${rstudio_deb_path}"; then
        log "INFO" "SUCCESS: RStudio Server package installed."
    else
        handle_error $? "Failed to install RStudio .deb package."
        rm -f "${rstudio_deb_path}" # Clean up the downloaded file on failure
        return 1
    fi
    # --- END MODIFIED BLOCK ---
    
    # Clean up the downloaded file on success
    rm -f "$rstudio_deb_path"
    
    # Enabling the service is a quick, non-interactive command
    run_command "Enable and start RStudio Server" "systemctl enable --now rstudio-server"
    
    log "INFO" "RStudio Server installation complete."
}

check_rstudio_server() {
    display_installation_status # This function now handles the status check
    if ss -tuln | grep -q ':8787'; then
        log "INFO" "RStudio Server is listening on port 8787."
        log "INFO" "Access it at http://<YOUR_SERVER_IP>:8787"
    else
        log "WARN" "RStudio Server is not listening on port 8787. Check firewall or service status."
    fi
}

# --- Core Installation Functions ---
setup_cran_repo() {
    log "INFO" "Setting up CRAN repository..."
    local ubuntu_codename
    ubuntu_codename=$(lsb_release -cs)
    #local cran_repo_line="deb [signed-by=${CRAN_APT_KEYRING_FILE}] ${CRAN_REPO_URL_BIN}/${ubuntu_codename}-cran40/"
    local cran_repo_line="deb [signed-by=${CRAN_APT_KEYRING_FILE}] ${CRAN_REPO_URL_BIN} ${ubuntu_codename}-cran40/"
    
    #run_command "Add CRAN apt key" "wget -qO- \"${CRAN_APT_KEY_URL}\" | gpg --dearmor -o \"${CRAN_APT_KEYRING_FILE}\""
    run_command "Add CRAN apt key" "wget -qO- \"${CRAN_APT_KEY_URL}\" | gpg --dearmor > \"${CRAN_APT_KEYRING_FILE}\""
    echo "$cran_repo_line" > /etc/apt/sources.list.d/cran.list
    run_command "Update apt package list" "apt-get update"
}

#install_r() {
#    if command -v R &>/dev/null; then
#        log "INFO" "R is already installed."
#        return 0
#    fi
#    log "INFO" "Installing R base and development packages..."
#    run_command "Install R base packages" "apt-get install -y --no-install-recommends r-base r-base-dev"
#}

install_r() {
    if command -v R &>/dev/null; then
        log "INFO" "R is already installed."
        return 0
    fi
    log "INFO" "Installing R base and development packages..."
    log "INFO" "This may take several minutes. Apt output will be displayed below:"
    
    # Call apt-get directly to ensure it is fully non-interactive and to show progress.
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends r-base r-base-dev; then
        log "INFO" "SUCCESS: R base packages installed."
    else
        handle_error $? "Failed to install R base packages."
        return 1
    fi
}



# ... (The rest of your script from install_openblas_openmp to the end is largely fine)
# --- Paste the remaining functions from your previous script here, starting from ---
# install_openblas_openmp()
# ... all the way to ...
# main()
# --- Then replace the initialize_environment and main functions with these improved versions ---


#install_openblas_openmp() {
#    log "INFO" "Installing OpenBLAS and OpenMP for performance..."
#    run_command "Install OpenBLAS/OpenMP" "apt-get install -y libopenblas-dev libomp-dev"
#}

install_openblas_openmp() {
    log "INFO" "Installing OpenBLAS and OpenMP for performance..."
    log "INFO" "Apt output will be displayed below:"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y libopenblas-dev libomp-dev; then
        log "INFO" "SUCCESS: OpenBLAS and OpenMP installed."
    else
        handle_error $? "Failed to install OpenBLAS/OpenMP packages."
        return 1
    fi
}

#verify_openblas_openmp() {
#    log "INFO" "Verifying OpenBLAS/OpenMP linkage..."
#    if ldd /usr/lib/R/lib/libRblas.so | grep -q 'openblas'; then
#        log "INFO" "SUCCESS: OpenBLAS is correctly linked to R."
#    else
#        log "WARN" "OpenBLAS does not appear to be linked to R. Performance may be suboptimal."
#    fi
#}

# Verifies that R is correctly linked against OpenBLAS.
#verify_openblas_openmp() {
#    log "INFO" "Verifying OpenBLAS/OpenMP installation..."
#    if ldd /usr/lib/R/lib/libRblas.so | grep -q openblas; then
#        log "INFO" "OpenBLAS is linked to Rblas."
#        return 0
#    else
#        log "WARN" "OpenBLAS not linked to Rblas."
#        return 1
#    fi
#}

verify_openblas_openmp() {
    log "INFO" "Verifying OpenBLAS and OpenMP integration with R..."
    if ! command -v Rscript &>/dev/null; then
        handle_error 1 "Rscript not found. Cannot perform verification. Please install R."
        return 1
    fi

    local r_check_script="/tmp/verify_blas.R"
    cat > "$r_check_script" << 'EOF'
    # Get session info to check for BLAS/LAPACK linkage
    info <- sessionInfo()
    
    # Check for OpenBLAS or other high-performance libraries
    blas_ok <- grepl("openblas", info$BLAS, ignore.case = TRUE) || grepl("atlas", info$BLAS, ignore.case = TRUE) || grepl("mkl", info$BLAS, ignore.case = TRUE)
    
    if (blas_ok) {
        cat("SUCCESS: High-performance BLAS detected.\n")
        print(info$BLAS)
    } else {
        cat("WARNING: Standard reference BLAS detected. Performance may be suboptimal.\n")
        print(info$BLAS)
    }
    
    # Perform a small benchmark to ensure it works
    cat("\nPerforming a small matrix multiplication benchmark...\n")
    N <- 500
    m <- matrix(rnorm(N*N), ncol=N)
    time <- system.time(crossprod(m))
    print(time)
    cat("Benchmark completed.\n")
EOF

    log "INFO" "Executing R verification script. Output will be in the log."
    # We run this within the run_command to capture output and handle errors
    if run_command "Run R BLAS/LAPACK verification" "Rscript ${r_check_script}"; then
        log "INFO" "R environment verification check passed."
        rm -f "$r_check_script"
        return 0
    else
        handle_error 1 "R environment verification FAILED. Check log for details from R."
        rm -f "$r_check_script"
        return 1
    fi
}


setup_bspm() {
    log "INFO" "Setting up bspm (Binary R Package Manager)..."
    get_r_profile_site_path
    if [[ -z "$R_PROFILE_SITE_PATH" ]]; then
        handle_error 1 "R_PROFILE_SITE_PATH could not be determined. Cannot setup bspm."
        return 1
    fi

    # ... (rest of setup_bspm function)

    if ! is_vm_or_ci_env; then
        log "INFO" "Not in root or CI/VM environment. Skipping bspm setup for safety."
        return 0
    fi

    local r_profile_dir
    r_profile_dir=$(dirname "$R_PROFILE_SITE_PATH")
    if [[ ! -d "$r_profile_dir" ]]; then run_command "Create Rprofile.site dir ${r_profile_dir}" mkdir -p "$r_profile_dir"; fi

    if [[ ! -f "$R_PROFILE_SITE_PATH" && ! -L "$R_PROFILE_SITE_PATH" ]]; then
        log "INFO" "Rprofile.site does not exist, creating it..."
        run_command "Create Rprofile.site: ${R_PROFILE_SITE_PATH}" touch "$R_PROFILE_SITE_PATH"
    fi

    if ! command -v sudo &>/dev/null; then
        log "WARN" "'sudo' is not installed. Attempting to install..."
        if [[ $EUID -ne 0 ]]; then
            log "ERROR" "'sudo' is not installed and you are not running as root. Please run this script as root to install sudo."
            return 1
        else
            run_command "Install sudo" apt-get update -y
            run_command "Install sudo" apt-get install -y sudo
            if ! command -v sudo &>/dev/null; then
                log "ERROR" "Failed to install sudo."
                return 1
            else
                log "INFO" "'sudo' successfully installed."
            fi
        fi
    else
        log "INFO" "'sudo' is already installed."
    fi

    log "INFO" "Adding R2U repository (if missing)..."
    if [[ -f "$R2U_APT_SOURCES_LIST_D_FILE" ]] || grep -qrE "r2u\.stat\.illinois\.edu/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d/; then
        log "INFO" "R2U repository already configured."
    else
        local ubuntu_codename
        ubuntu_codename=$(lsb_release -cs)
        local r2u_add_script_url="${R2U_REPO_URL_BASE}/add-r2u"
        log "INFO" "Downloading R2U setup script: ${r2u_add_script_url}"
        run_command "Download R2U setup script" curl -sSLf "${r2u_add_script_url}" -o /tmp/add-r2u
        log "INFO" "Executing R2U repository setup script..."
        if ! sudo bash /tmp/add-r2u 2>&1 | sudo tee -a "$LOG_FILE"; then
            log "ERROR" "Failed to execute R2U repository setup script."
            return 1
        fi
        rm -f /tmp/add-r2u
    fi

    if systemctl list-units --type=service | grep -q dbus.service; then
        log "INFO" "Restarting dbus service..."
        sudo systemctl restart dbus.service
    elif service --status-all 2>&1 | grep -q dbus; then
        log "INFO" "Restarting dbus service..."
        sudo service dbus restart
    else
        log "WARN" "dbus service not found. If package management fails, ensure dbus is running."
    fi

    log "INFO" "Checking for required system packages (r-base-core python3-dbus python3-gi python3-apt)..."
    local missing_pkgs=()
    for pkg in "r-base-core" "python3-dbus" "python3-gi" "python3-apt"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log "INFO" "Installing missing system packages: ${missing_pkgs[*]}..."
        if ! sudo apt-get install -y "${missing_pkgs[@]}"; then
            log "ERROR" "Failed to install required system packages."
            return 1
        else
            log "INFO" "Successfully installed required system packages."
        fi
    else
        log "INFO" "All required system packages are already installed."
    fi

    local system_r_lib_path
    system_r_lib_path=$(sudo Rscript -e 'cat(.Library)' 2>/dev/null)
    log "INFO" "System R library path: $system_r_lib_path"

    export BSPM_ALLOW_SYSREQS=TRUE
    export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1

    log "INFO" "Installing bspm as a system package (via apt)..."
    if ! sudo apt-get install -y r-cran-bspm; then
        log "ERROR" "Failed to install bspm as a system package via apt."
        return 1
    fi

    log "INFO" "Configuring bspm to use sudo and system requirements..."
    local rprofile_lines="options(bspm.sudo = TRUE)
options(bspm.allow.sysreqs = TRUE)
suppressMessages(bspm::enable())"
    sed -i '/options(bspm\.sudo *= *TRUE)/d' "$R_PROFILE_SITE_PATH"
    sed -i '/options(bspm\.allow\.sysreqs *= *TRUE)/d' "$R_PROFILE_SITE_PATH"
    sed -i '/suppressMessages(bspm::enable())/d' "$R_PROFILE_SITE_PATH"
    printf "\n%s\n" "$rprofile_lines" | tee -a "$R_PROFILE_SITE_PATH" >/dev/null

    log "INFO" "Debug: Content of Rprofile.site (${R_PROFILE_SITE_PATH}):"
    tee -a "$LOG_FILE" < "$R_PROFILE_SITE_PATH" || log "WARN" "Could not display Rprofile.site content."

    log "INFO" "Verifying bspm activation..."
    set +e
    local bspm_status_output
    bspm_status_output=$(sudo R --vanilla -e "
.libPaths(c('$system_r_lib_path', .libPaths()))
if (!requireNamespace('bspm', quietly=TRUE)) {
  cat('BSPM_NOT_INSTALLED\n'); quit(status=1)
}
options(bspm.sudo=TRUE, bspm.allow.sysreqs=TRUE)
suppressMessages(bspm::enable())
if ('bspm' %in% loadedNamespaces() && 'bspm' %in% rownames(installed.packages())) {
  cat('BSPM_WORKING\n')
} else {
  cat('BSPM_NOT_MANAGING\n')
  quit(status=2)
}")
    local bspm_status_rc=$?
    set -e

    if [[ $bspm_status_rc -eq 0 && "$bspm_status_output" == *BSPM_WORKING* ]]; then
        log "INFO" "bspm is installed and managing packages."
    elif [[ "$bspm_status_output" == *BSPM_NOT_INSTALLED* ]]; then
        log "ERROR" "bspm is NOT installed properly."
        return 2
    elif [[ "$bspm_status_output" == *BSPM_NOT_MANAGING* ]]; then
        log "ERROR" "bspm is installed but NOT managing packages."
        log "ERROR" "Debug output: $bspm_status_output"
        return 3
    else
        log "ERROR" "Unknown bspm status: $bspm_status_output"
        return 4
    fi

    log "INFO" "bspm setup and verification completed."
}

#install_r_build_deps() {
#    log "INFO" "Installing system dependencies for building R packages..."
#    local build_deps=(
#        build-essential libcurl4-openssl-dev libssl-dev libxml2-dev libgit2-dev
#        libfontconfig1-dev libcairo2-dev libharfbuzz-dev libfribidi-dev
#        libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev zlib1g-dev
#    )
#    run_command "Install R package build dependencies" "apt-get install -y ${build_deps[*]}"
#}

install_r_build_deps() {
    log "INFO" "Installing system dependencies for building R packages..."
    local build_deps=(
        build-essential libcurl4-openssl-dev libssl-dev libxml2-dev libgit2-dev
        libfontconfig1-dev libcairo2-dev libharfbuzz-dev libfribidi-dev
        libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev zlib1g-dev
    )
    log "INFO" "Apt output will be displayed below:"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "${build_deps[@]}"; then
        log "INFO" "SUCCESS: R build dependencies installed."
    else
        handle_error $? "Failed to install R build dependencies."
        return 1
    fi
}

install_r_pkg_list() {
        local pkg_type="$1"; shift
    local r_packages_list=("${@}")

    if [[ ${#r_packages_list[@]} -eq 0 ]]; then
        log "INFO" "No ${pkg_type} R packages specified in the list to install."
        return
    fi

    log "INFO" "Processing ${pkg_type} R packages for installation: ${r_packages_list[*]}"

    local pkg_install_script_path="/tmp/install_r_pkg_script.R"
    local github_pat_warning_shown=false

    for pkg_name_full in "${r_packages_list[@]}"; do
        local pkg_name_short

        if [[ "$pkg_type" == "CRAN" ]]; then
            pkg_name_short="$pkg_name_full"
            # Use a heredoc to create the R script, preventing shell expansion
            cat > "$pkg_install_script_path" <<EOF
            pkg_short_name <- '${pkg_name_short}'
            n_cpus <- max(1, parallel::detectCores(logical=FALSE) %/% 2)

            if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                message(paste0('R package ', pkg_short_name, ' not found, attempting installation...'))
                installed_successfully <- FALSE
                if (requireNamespace('bspm', quietly = TRUE) && isTRUE(getOption('bspm.MANAGES', FALSE))) {
                    message(paste0('Attempting to install ', pkg_short_name, ' via bspm (binary)...'))
                    tryCatch({
                        install.packages(pkg_short_name, Ncpus = n_cpus)
                        installed_successfully <- requireNamespace(pkg_short_name, quietly = TRUE)
                    }, error = function(e) {
                        message(paste0('bspm install failed for ', pkg_short_name, ': ', e\$message))
                    })
                }
                if (!installed_successfully) {
                    message(paste0('bspm failed or disabled, trying to install ', pkg_short_name, ' from source...'))
                    install.packages(pkg_short_name, Ncpus = n_cpus, type = 'source')
                }
            } else {
                message(paste0('R package ', pkg_short_name, ' is already installed.'))
            }
            if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                stop(paste0('Failed to install R package: ', pkg_short_name))
            }
EOF
        elif [[ "$pkg_type" == "GitHub" ]]; then
            pkg_name_short=$(basename "$pkg_name_full")
            # Use a heredoc for the GitHub installation script
            cat > "$pkg_install_script_path" <<EOF
            pkg_repo <- '${pkg_name_full}'
            pkg_short_name <- '${pkg_name_short}'
            if (!requireNamespace('remotes', quietly = TRUE)) {
                message('remotes package not found, installing it first...')
                install.packages('remotes')
            }
            if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                message(paste0('Installing GitHub package ', pkg_repo, '...'))
                remotes::install_github(pkg_repo, force = TRUE)
            } else {
                message(paste0('GitHub package ', pkg_short_name, ' (from ', pkg_repo, ') is already installed.'))
            }
            if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                stop(paste0('Failed to install GitHub package: ', pkg_repo))
            }
EOF
            if [[ -z "${GITHUB_PAT:-}" ]] && ! $github_pat_warning_shown; then
                log "WARN" "GITHUB_PAT environment variable is not set. GitHub package installations may fail due to API rate limiting."
                github_pat_warning_shown=true
            fi
        else
            log "ERROR" "Unknown package type: $pkg_type"
            continue
        fi

        if run_command "Install R package: ${pkg_name_full}" Rscript "$pkg_install_script_path"; then
            # On success, add to the state file
            if [[ "$pkg_type" == "CRAN" ]]; then
                add_to_env_state "INSTALLED_CRAN_PACKAGES" "$pkg_name_short"
            elif [[ "$pkg_type" == "GitHub" ]]; then
                add_to_env_state "INSTALLED_GITHUB_PACKAGES" "$pkg_name_full"
            fi
        fi
    done
    rm -f "$pkg_install_script_path"
}

#install_core_r_dev_pkgs() {
#    log "INFO" "Installing core R development packages (devtools, remotes)..."
#    install_r_pkg_list "CRAN" "devtools" "remotes"
#}

install_core_r_dev_pkgs() {
    log "INFO" "Installing core R development packages (devtools, remotes)..."
    local core_r_dev_pkgs=("devtools" "remotes")
    install_r_pkg_list "CRAN" "${core_r_dev_pkgs[@]}"
}

install_user_cran_pkgs() {
    log "INFO" "Installing user-defined CRAN packages..."
    install_r_pkg_list "CRAN" "${R_USER_PACKAGES_CRAN[@]}"
}

install_user_github_pkgs() {
    log "INFO" "Installing user-defined GitHub packages..."
    install_r_pkg_list "GitHub" "${R_USER_PACKAGES_GITHUB[@]}"
}

# --- Maintenance and Orchestration ---

backup_all() {
    log "INFO" "--- Backing Up All Configurations ---"
    get_r_profile_site_path
    backup_file "$R_PROFILE_SITE_PATH"
    backup_file "/etc/apt/sources.list.d/cran.list"
    backup_file "$R2U_APT_SOURCES_LIST_D_FILE"
    backup_file "/etc/rstudio/rserver.conf"
    backup_file "/etc/rstudio/rsession.conf"
    log "INFO" "Backup process completed."
}

uninstall() {
    log "INFO" "--- Starting Uninstall Process ---"
        log "INFO" "--- Starting Uninstall Process ---"
    save_state "uninstall" "starting"
    
    if [[ -f "$STATE_FILE" ]]; then
        log "INFO" "Loading state for uninstall..."
        load_state
    fi
    # Uninstall R packages
    if [[ ${#INSTALLED_CRAN_PACKAGES[@]} -gt 0 ]] || [[ ${#INSTALLED_GITHUB_PACKAGES[@]} -gt 0 ]]; then
        log "INFO" "The following R packages will be uninstalled:"
        [[ ${#INSTALLED_CRAN_PACKAGES[@]} -gt 0 ]] && echo "  CRAN:" && printf "    - %s\n" "${INSTALLED_CRAN_PACKAGES[@]}"
        [[ ${#INSTALLED_GITHUB_PACKAGES[@]} -gt 0 ]] && echo "  GitHub:" && printf "    - %s\n" "${INSTALLED_GITHUB_PACKAGES[@]}"
        read -r -p "Are you sure you want to uninstall these packages? [y/N] " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            if [[ -f "$R_ENV_STATE_FILE" ]]; then
                log "INFO" "Reloading environment state from $R_ENV_STATE_FILE..."
                # shellcheck disable=SC1090,SC1091
                source "$R_ENV_STATE_FILE"
            fi
            if [[ ${#INSTALLED_CRAN_PACKAGES[@]} -gt 0 ]]; then
                run_command "Uninstall user CRAN packages" Rscript -e "remove.packages(c($(printf "'%s'," "${INSTALLED_CRAN_PACKAGES[@]}")))"
            fi
            if [[ ${#INSTALLED_GITHUB_PACKAGES[@]} -gt 0 ]]; then
                run_command "Uninstall user GitHub packages" Rscript -e "remove.packages(c($(printf "'%s'," "${INSTALLED_GITHUB_PACKAGES[@]}")))"
            fi
        fi
    fi

    # Uninstall system packages
    run_command "Uninstall RStudio Server" apt-get purge -y rstudio-server
    run_command "Uninstall R and related packages" apt-get purge -y r-base r-base-dev r-cran-bspm
    run_command "Uninstall build dependencies" apt-get purge -y build-essential libcurl4-openssl-dev libssl-dev libxml2-dev
    run_command "Autoremove unused packages" apt-get autoremove -y

    # Remove config files
    run_command "Remove Rprofile.site" rm -f "$R_PROFILE_SITE_PATH"
    run_command "Remove CRAN apt source" rm -f /etc/apt/sources.list.d/cran.list
    run_command "Remove R2U apt source" rm -f "$R2U_APT_SOURCES_LIST_D_FILE"
    run_command "Remove environment state file" rm -f "$R_ENV_STATE_FILE"

    log "INFO" "Uninstall process completed."
}

restore_all() {
    log "INFO" "--- Starting Restore Process ---"
    get_r_profile_site_path
    restore_latest_backup "$R_PROFILE_SITE_PATH"
    restore_latest_backup "/etc/apt/sources.list.d/cran.list"
    restore_latest_backup "$R2U_APT_SOURCES_LIST_D_FILE"
    restore_latest_backup "/etc/rstudio/rserver.conf"
    restore_latest_backup "/etc/rstudio/rsession.conf"
    log "INFO" "Restore process completed. Run 'apt-get update' to apply changes."
}

full_install() {
    log "INFO" "--- Starting Full R Environment Installation ---"
    backup_all
    setup_cran_repo
    install_r
    install_openblas_openmp
    verify_openblas_openmp
    setup_bspm # Uncomment if you use it
    install_r_build_deps
    install_core_r_dev_pkgs
    install_user_cran_pkgs
    install_user_github_pkgs
    install_rstudio_server
    check_rstudio_server
    log "INFO" "--- Full Installation Complete ---"
}

launch_external_script() {
        local scripts_dir="${SCRIPT_DIR}/scripts"
    if [[ ! -d "$scripts_dir" ]]; then
        log "WARN" "Scripts directory not found at '${scripts_dir}'."
        return
    fi

    local scripts_found=()
    while IFS= read -r -d $'\0'; do
        scripts_found+=("$REPLY")
    done < <(find "$scripts_dir" -maxdepth 1 -type f -name "*.sh" -print0)

    if [[ ${#scripts_found[@]} -eq 0 ]]; then
        log "WARN" "No executable scripts found in '${scripts_dir}'."
        return
    fi

    printf "\n--- External Script Launcher ---\n"
    printf "Select a script to run:\n"
    local i=1
    for script_path in "${scripts_found[@]}"; do
        printf "%d. %s\n" "$i" "$(basename "$script_path")"
        ((i++))
    done
    printf "B. Back to Main Menu\n"

    local choice
    read -r -p "Enter choice: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le ${#scripts_found[@]} ]]; then
        local selected_script="${scripts_found[$((choice-1))]}"
        log "INFO" "Executing selected script: ${selected_script}"
        bash "$selected_script"
    elif [[ "$choice" =~ ^[Bb]$ ]]; then
        return
    else
        log "ERROR" "Invalid choice."
    fi
}

main_menu() {
    while true; do
        check_system_resources || {
            handle_error 4 "System resources check failed. Aborting menu."
            return 1
        }
        rotate_logs
        
        printf "\n================ R Environment Manager ================\n"
        printf "1.  Full Installation (Recommended for first run)\n"
        printf "2.  Install/Verify R, OpenBLAS, and bspm\n"
        printf "3.  Install All User R Packages (CRAN & GitHub)\n"
        printf "4.  Install RStudio Server\n"
        printf "5.  Check RStudio Server Status\n"
        printf -- "-------------------- Maintenance --------------------\n"
        printf "6.  Launch Other Setup Scripts (Nginx, SSSD, etc.)\n"
        printf "7.  Backup All Configurations\n"
        printf "8.  Restore All Configurations from Last Backup\n"
        printf "9.  Uninstall Entire R Environment\n"
        printf "10. View Logs\n"
        printf "11. Check Installation Status\n"
        printf "E.  Exit\n"
        printf "=======================================================\n"
        
        read -r -p "Enter choice: " choice
        
        case $choice in
            1) full_install ;;
            2) setup_cran_repo; install_r; install_openblas_openmp; verify_openblas_openmp; setup_bspm ;;
            3) install_core_r_dev_pkgs; install_user_cran_pkgs; install_user_github_pkgs ;;
            4) install_rstudio_server ;;
            5) check_rstudio_server ;;
            6) launch_external_script ;;
            7) backup_all ;;
            8) restore_all ;;
            9) uninstall ;;
            10) if [[ -f "$LOG_FILE" ]]; then less "$LOG_FILE"; else log "ERROR" "Log file not found"; fi ;;
            11) display_installation_status ;;
            [Ee]) log "INFO" "Exiting R Environment Manager."; break ;;
            *) log "ERROR" "Invalid choice. Please enter a number 1-11 or E to exit." ;;
        esac
        if [[ ! "$choice" =~ ^[Ee]$ ]]; then
            read -r -p "Press Enter to return to the menu..."
        fi
    done
    return 0
}

initialize_environment() {
    # Setup logging first, so all subsequent steps are recorded.
    setup_logging
    log "INFO" "--- R Environment Manager Starting ---"
    
    acquire_lock
    check_security_requirements
    pre_flight_checks
    
    ensure_config_dir
    
    if ! validate_configuration; then
        log "FATAL" "Configuration validation failed. Please check your .conf file and try again."
        exit 1
    fi
    
    load_state
    
    if ! check_system_resources; then
        # The function itself logs the specific error
        log "FATAL" "System resources check failed."
        exit 1
    fi
    
    log "INFO" "Environment initialization complete."
}

main() {
    initialize_environment
    main_menu
    # Cleanup is handled by the trap, so no explicit call is needed here
}

# Start script execution
main "$@"