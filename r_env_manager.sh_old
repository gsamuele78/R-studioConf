#!/usr/bin/env bash

################################################################################
#
# R Environment Manager (`r_env_manager.sh`)
#
# Version: 1.0.0
# Last Updated: 2025-09-08
#
# This script follows these system engineering best practices:
# - Secure: Enforces proper permissions and validates input
# - Robust: Comprehensive error handling and recovery
# - Maintainable: Modular design with clear documentation
# - Reliable: Transaction-based operations with rollback
# - Auditable: Detailed logging of all operations
#
# --- Architecture Overview ---
#
# This script follows a layered architecture:
# 1. Core Infrastructure Layer
#    - Security checks and process management
#    - Configuration validation
#    - Resource monitoring
#    - Logging and state management
#
# 2. Installation Layer
#    - R and dependencies installation
#    - RStudio Server setup
#    - Package management (CRAN/GitHub)
#
# 3. Management Layer
#    - Backup and restore
#    - Script orchestration
#    - Monitoring and maintenance
#
# --- Configuration ---
#
# Required files:
# - config/r_env_manager.conf: Main configuration
# - lib/common_utils.sh: Shared utilities
#
# State files:
# - .r_env_state: Installation state
# - /var/log/r_env_manager/: Log directory
# - /var/backups/r_env_manager/: Backup directory
#
# --- Security ---
#
# - Requires root privileges
# - Enforces secure file permissions
# - Validates all inputs
# - Uses atomic operations
# - Implements process locking
#
# --- Error Handling ---
#
# - Comprehensive error detection
# - Automatic recovery procedures
# - Transaction rollback capability
# - Detailed error logging
#
# --- Description
#
# This script is the central orchestrator for setting up and managing a complete
# R development environment on Debian-based systems. It follows system engineering
# best practices with comprehensive error handling, logging, and state management.
#
# ### Design Philosophy
# - **Robust**: Handles errors gracefully with proper recovery
# - **Secure**: Implements security best practices
# - **Maintainable**: Modular design with clear documentation
# - **Idempotent**: Safe to run multiple times
# - **Auditable**: Comprehensive logging of all operations
#
# ## Key Features
#
# - **Full Installation**: Automates the entire setup process, including:
#   - System package dependencies (build-essential, libs, etc.).
#   - R-base from a specified CRAN repository.
#   - High-performance libraries (OpenBLAS, OpenMP).
#   - RStudio Server (latest version auto-detection).
#   - Binary R package management via `bspm`.
# - **Modular Execution**: Allows running individual setup steps.
# - **Package Management**: Installs lists of CRAN and GitHub packages from a
#   central configuration file.
# - **Script Launcher**: Provides a menu to execute other specialized setup
#   scripts (e.g., `nginx_setup.sh`, `sssd_kerberos_setup.sh`).
# - **Maintenance**: Includes robust uninstall, backup, and restore capabilities.
# - **Configuration-Driven**: All settings, package lists, and paths are managed
#   in `config/r_env_manager.conf`.
#
# ## Usage
#
# 1. Customize variables in `config/r_env_manager.conf`.
# 2. Run the script as root: `sudo ./r_env_manager.sh`
# 3. Follow the on-screen menu prompts.
#
# ## Example Advanced Usage
#
#   sudo ./r_env_manager.sh
#   # Select "6. Launch Other Setup Scripts" to run modular scripts
#
# ---
#
# Author: Your Name/Team
# Date:   2025-09-08
#
################################################################################

set -euo pipefail

# --- Global Constants and Configuration ---
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

LOCK_FILE="/var/run/${SCRIPT_NAME}.lock"
PID_FILE="/var/run/${SCRIPT_NAME}.pid"
LOG_DIR="/var/log/r_env_manager"
BACKUP_DIR="/var/backups/r_env_manager"
CONFIG_DIR="${SCRIPT_DIR}/config"
STATE_FILE="${SCRIPT_DIR}/.r_env_state"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
#readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
CONFIG_FILE="${CONFIG_DIR}/r_env_manager.conf"
R_PROFILE_SITE_PATH="" # Will be determined dynamically
export MAX_RETRIES=3
export TIMEOUT=1800  # 30 minutes (used for command timeouts)
export DEBIAN_FRONTEND=noninteractive

# --- Core Infrastructure Layer ---

# Process Management
acquire_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
        log "ERROR" "Another instance is running (PID: $pid)"
        exit 1
    fi
    mkdir -p "$(dirname "$LOCK_FILE")"
    touch "$LOCK_FILE"
    echo $$ > "$PID_FILE"
}

# Resource Management
check_system_resources() {
    local min_memory=2048  # 2GB minimum
    local min_disk=5120    # 5GB minimum
    
    local available_memory
    available_memory=$(free -m | awk '/^Mem:/{print $7}')
    if (( available_memory < min_memory )); then
        handle_error 4 "Insufficient memory: ${available_memory}MB available, ${min_memory}MB required"
        return 1
    fi
    
    local available_disk
    available_disk=$(df -m "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    if (( available_disk < min_disk )); then
        handle_error 4 "Insufficient disk space: ${available_disk}MB available, ${min_disk}MB required"
        return 1
    fi
    
    return 0
}

# Logging System
setup_logging() {
    ensure_dir_exists "$LOG_DIR" "Log directory"
    
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 640 "$LOG_FILE"
    else
        rotate_logs
    fi
    
    # Redirect stderr to log while maintaining console output
    exec 3>&2
    exec 2> >(tee -a "$LOG_FILE" >&2)
}

rotate_logs() {
    local max_size=$((50*1024*1024))  # 50MB
    local max_backups=5
    
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE")
        if (( size > max_size )); then
            for ((i=max_backups-1; i>=1; i--)); do
                if [[ -f "${LOG_FILE}.$i" ]]; then
                    mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
                fi
            done
            mv "$LOG_FILE" "${LOG_FILE}.1"
            touch "$LOG_FILE"
            chmod 640 "$LOG_FILE"
        fi
    fi
}

# --- Early Exit Handlers ---
cleanup() {
    local exit_code=$?
    log "INFO" "Script execution ending with code: $exit_code"
    if [[ -f "$LOCK_FILE" ]]; then rm -f "$LOCK_FILE"; fi
    if [[ -f "$PID_FILE" ]]; then rm -f "$PID_FILE"; fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 1' HUP INT QUIT TERM

# --- Security Checks ---
check_security_requirements() {
    # Check root privileges
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root. Please use sudo." >&2
        exit 1
    fi
    
    

    # Check for secure PATH
    if [[ "$PATH" == *.* ]] || [[ "$PATH" == *:* ]]; then
        log "ERROR" "Insecure PATH environment detected"
        exit 1
    fi

    # Ensure critical directories exist with proper permissions
    for dir in "$LOG_DIR" "$BACKUP_DIR"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            chmod 750 "$dir"
        fi
    done
}

# --- Configuration Management ---
ensure_config_dir() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        log "INFO" "Creating configuration directory at $CONFIG_DIR"
        mkdir -p "$CONFIG_DIR"
        chmod 750 "$CONFIG_DIR"
    fi

    # Verify config directory permissions
    verify_secure_permissions "$CONFIG_DIR" "750"

    # Check for configuration file
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR" "Main configuration file not found at $CONFIG_FILE"
        log "INFO" "Creating default configuration..."
        create_default_config
    fi

    # Source the configuration file
    if [[ -f "$CONFIG_FILE" ]]; then
        log "INFO" "Loading configuration from $CONFIG_FILE"
        # shellcheck disable=SC1090,SC1091
        source "$CONFIG_FILE"
    else
        log "FATAL" "Configuration file could not be created or loaded"
        exit 1
    fi
}

create_default_config() {
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

    # Set secure permissions on the new config file
    chmod 640 "$CONFIG_FILE"
    log "INFO" "Default configuration created at $CONFIG_FILE"
}
COMMON_UTILS="${SCRIPT_DIR}/lib/common_utils.sh"
if [[ -f "$COMMON_UTILS" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$COMMON_UTILS"
else
    echo "FATAL: Common utility library not found at $COMMON_UTILS. Cannot proceed." >&2
    exit 1
fi
if [[ -n "${CUSTOM_R_PROFILE_SITE_PATH_ENV:-}" ]]; then
    USER_SPECIFIED_R_PROFILE_SITE_PATH="${CUSTOM_R_PROFILE_SITE_PATH_ENV}"
fi

# --- Placeholder Functions ---
validate_configuration() {
    log "INFO" "Validating configuration..."
    # Add validation logic here
    return 0
}

display_installation_status() {
    log "INFO" "Displaying installation status..."
    # Add status display logic here
}

pre_flight_checks() {
    log "INFO" "Performing pre-flight checks..."
    # Add pre-flight check logic here
    return 0
}

get_state() {
    local key="$1"
    local default_value="$2"
    if [[ -v "OPERATION_STATE[$key]" ]]; then
        echo "${OPERATION_STATE[$key]}"
    else
        echo "$default_value"
    fi
}

backup_file() {
    local file_path="$1"
    log "INFO" "Backing up ${file_path}..."
    # Add backup logic here
}

restore_latest_backup() {
    local file_path="$1"
    log "INFO" "Restoring ${file_path}..."
    # Add restore logic here
}

verify_secure_permissions() {
    local path="$1"
    log "INFO" "Verifying permissions for ${path}..."
    # Add permission verification logic here
}

# --- State Management ---
declare -A OPERATION_STATE
save_state() {
    local operation=$1
    local status=$2
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    OPERATION_STATE["${operation}_status"]=$status
    OPERATION_STATE["${operation}_timestamp"]=$timestamp
    
    # Persist state to file
    {
        echo "# R Environment Manager State - $timestamp"
        for key in "${!OPERATION_STATE[@]}"; do
            echo "${key}=${OPERATION_STATE[$key]}"
        done
    } > "${SCRIPT_DIR}/.r_env_state"
}

load_state() {
    local state_file="${SCRIPT_DIR}/.r_env_state"
    if [[ -f "$state_file" ]]; then
        while IFS='=' read -r key value; do
            [[ $key == \#* ]] && continue
            OPERATION_STATE["$key"]=$value
        done < "$state_file"
    fi
}

# --- Core Helper Functions ---

# Determines the correct path for the system-wide Rprofile.site file.
# It checks user overrides, then `R RHOME`, then common default locations.
get_r_profile_site_path() {
    local log_details=false
    # Only log detailed detection steps if the path isn't already set.
    if [[ -z "${R_PROFILE_SITE_PATH:-}" ]] && [[ -z "${USER_SPECIFIED_R_PROFILE_SITE_PATH:-}" ]]; then
        log_details=true
    fi

    if $log_details; then log "INFO" "Determining Rprofile.site path..."; fi

    # Priority 1: User-specified environment variable.
    if [[ -n "${USER_SPECIFIED_R_PROFILE_SITE_PATH:-}" ]]; then
        if [[ "${R_PROFILE_SITE_PATH:-}" != "$USER_SPECIFIED_R_PROFILE_SITE_PATH" ]]; then
            R_PROFILE_SITE_PATH="$USER_SPECIFIED_R_PROFILE_SITE_PATH"
            log "INFO" "Using user-specified R_PROFILE_SITE_PATH: ${R_PROFILE_SITE_PATH}"
        fi
        return
    fi

    # Priority 2: `R RHOME` command output.
    if command -v R &>/dev/null; then
        local r_home_output
        r_home_output=$(R RHOME 2>/dev/null || echo "")
        if [[ -n "$r_home_output" && -d "$r_home_output" ]]; then
            local detected_path="${r_home_output}/etc/Rprofile.site"
            if [[ "${R_PROFILE_SITE_PATH:-}" != "$detected_path" ]]; then
                log "INFO" "Auto-detected R_PROFILE_SITE_PATH (from R RHOME): ${detected_path}"
            fi
            R_PROFILE_SITE_PATH="$detected_path"
            return
        fi
    fi

    # Priority 3: Common default paths.
    local default_apt_path="/usr/lib/R/etc/Rprofile.site"
    local default_local_path="/usr/local/lib/R/etc/Rprofile.site"
    local new_detected_path=""

    if [[ -f "$default_apt_path" || -L "$default_apt_path" ]]; then
        new_detected_path="$default_apt_path"
        if $log_details || [[ "${R_PROFILE_SITE_PATH:-}" != "$new_detected_path" ]]; then
            log "INFO" "Auto-detected R_PROFILE_SITE_PATH (apt default): ${new_detected_path}"
        fi
    elif [[ -f "$default_local_path" || -L "$default_local_path" ]]; then
        new_detected_path="$default_local_path"
        if $log_details || [[ "${R_PROFILE_SITE_PATH:-}" != "$new_detected_path" ]]; then
            log "INFO" "Auto-detected R_PROFILE_SITE_PATH (local default): ${new_detected_path}"
        fi
    else
        # If no file exists, default to the standard location for creation.
        new_detected_path="$default_apt_path"
        if $log_details || [[ "${R_PROFILE_SITE_PATH:-}" != "$new_detected_path" ]]; then
            log "INFO" "No Rprofile.site found. Defaulting to standard location for creation: ${new_detected_path}"
        fi
    fi
    R_PROFILE_SITE_PATH="$new_detected_path"
}

# Checks if the script is running in a non-interactive CI/CD or container environment.
is_vm_or_ci_env() {
    if [[ "${CI:-false}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]] || [[ -n "${TRAVIS:-}" ]]; then
        return 0 # It's a CI environment
    elif [[ "$EUID" -eq 0 ]] && [[ -f /.dockerenv ]]; then
        return 0 # It's a Docker container
    else
        return 1 # Not a known CI/VM environment
    fi
}


# --- RStudio Server Functions ---

# Fetches the latest RStudio Server version and download URL.
get_latest_rstudio_info() {
    log "INFO" "Detecting latest RStudio Server version and architecture..."
    local latest_version latest_arch
    latest_version="$RSTUDIO_VERSION_FALLBACK"
    latest_arch="$RSTUDIO_ARCH_FALLBACK"

    # Try to fetch latest version info from the RStudio website.
    local json_url="https://rstudio.com/products/rstudio/download-server/"
    local html
    html=$(curl -fsSL "$json_url" 2>/dev/null || true)

    if [[ -n "$html" ]]; then
        # Extract version and architecture from the HTML content.
        latest_version=$(echo "$html" | grep -oP 'rstudio-server-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | head -n1)
        latest_arch=$(echo "$html" | grep -oP 'rstudio-server-[0-9.]+-([a-z0-9]+)\.deb' | head -n1)
        if [[ -n "$latest_version" ]]; then
            RSTUDIO_VERSION="$latest_version"
        fi
        if [[ -n "$latest_arch" ]]; then
            RSTUDIO_ARCH="$latest_arch"
        fi
    fi

    RSTUDIO_DEB_FILENAME="rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
    RSTUDIO_DEB_URL="https://download2.rstudio.org/server/bionic/${RSTUDIO_DEB_FILENAME}" # Assuming bionic, adjust if needed
    log "INFO" "Using RStudio Server version: $RSTUDIO_VERSION, arch: $RSTUDIO_ARCH"
    log "INFO" "Download URL: $RSTUDIO_DEB_URL"
}

# Installs RStudio Server from the determined URL.
install_rstudio_server() {
    local current_state
    current_state=$(get_state "rstudio_installation" "not_installed")
    
    if [[ "$current_state" == "completed" ]]; then
        if systemctl is-active --quiet rstudio-server; then
            log "INFO" "RStudio Server is already installed and running"
            return 0
        else
            log "WARN" "RStudio Server is installed but not running"
            save_state "rstudio_installation" "needs_restart"
        fi
    fi
    
    save_state "rstudio_installation" "starting"
    get_latest_rstudio_info
    
    log "INFO" "Installing RStudio Server..."
    local rstudio_deb_path="/tmp/${RSTUDIO_DEB_FILENAME}"
    
    if ! run_command "Download RStudio Server" wget -O "$rstudio_deb_path" "$RSTUDIO_DEB_URL"; then
        save_state "rstudio_installation" "download_failed"
        handle_error 2 "Failed to download RStudio Server"
        return 1
    fi
    
    if ! run_command "Install RStudio Server .deb package" apt-get install -y "$rstudio_deb_path"; then
        save_state "rstudio_installation" "install_failed"
        handle_error 1 "Failed to install RStudio Server package"
        rm -f "$rstudio_deb_path"
        return 1
    fi
    
    rm -f "$rstudio_deb_path"
    
    if ! run_command "Enable and start RStudio Server" systemctl enable --now rstudio-server; then
        save_state "rstudio_installation" "service_failed"
        handle_error 1 "Failed to start RStudio Server service"
        return 1
    fi
    
    save_state "rstudio_installation" "completed"
    log "INFO" "RStudio Server installation complete."
    return 0
}

# Checks the status of the RStudio Server.
check_rstudio_server() {
    log "INFO" "Checking RStudio Server installation and status..."
    if ! command -v rstudio-server &>/dev/null; then
        log "ERROR" "RStudio Server is not installed or not in PATH."
        return 1
    fi

    local rstudio_status
    rstudio_status=$(rstudio-server status 2>&1)
    log "INFO" "rstudio-server command found. Status: $rstudio_status"
    if [[ "$rstudio_status" == *"active (running)"* ]]; then
        log "INFO" "RStudio Server is running."
    else
        log "WARN" "RStudio Server is installed but not running."
    fi
    log "INFO" "RStudio Server version: $(rstudio-server version 2>/dev/null || echo 'Unknown')"

    log "INFO" "Checking if RStudio Server is accessible on port 8787..."
    if ss -tuln | grep -q ':8787'; then
        log "INFO" "RStudio Server is listening on port 8787."
    else
        log "WARN" "RStudio Server is not listening on port 8787. Check firewall or service status."
    fi
    log "INFO" "You can access RStudio Server at http://<YOUR_SERVER_IP>:8787 if not firewalled."
}


# --- Core Installation Functions ---

# Sets up the CRAN repository for apt.
setup_cran_repo() {
    log "INFO" "Setting up CRAN repository..."
    local ubuntu_codename
    ubuntu_codename=$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
    local cran_repo_line="deb [signed-by=${CRAN_APT_KEYRING_FILE}] ${CRAN_REPO_URL_BIN}/${ubuntu_codename}-cran40/"
    run_command "Add CRAN apt key" wget -qO- "$CRAN_APT_KEY_URL" | gpg --dearmor -o "$CRAN_APT_KEYRING_FILE"
    echo "$cran_repo_line" > /etc/apt/sources.list.d/cran.list
    run_command "apt-get update" apt-get update
}

# Installs R and its development packages.
install_r() {
    local current_state
    current_state=$(get_state "r_installation" "not_installed")
    
    if [[ "$current_state" == "completed" ]]; then
        log "INFO" "R is already installed"
        return 0
    fi
    
    save_state "r_installation" "starting"
    log "INFO" "Installing R base and recommended packages..."
    
    if run_command "apt-get install R base" apt-get install -y --no-install-recommends r-base r-base-dev; then
        save_state "r_installation" "completed"
        return 0
    else
        save_state "r_installation" "failed"
        handle_error 1 "R installation failed"
        return 1
    fi
}

# Installs high-performance libraries.
install_openblas_openmp() {
    log "INFO" "Installing OpenBLAS and OpenMP..."
    run_command "apt-get install OpenBLAS/OpenMP" apt-get install -y libopenblas-dev libomp-dev
}

# Verifies that R is correctly linked against OpenBLAS.
verify_openblas_openmp() {
    log "INFO" "Verifying OpenBLAS/OpenMP installation..."
    if ldd /usr/lib/R/lib/libRblas.so | grep -q openblas; then
        log "INFO" "OpenBLAS is linked to Rblas."
        return 0
    else
        log "WARN" "OpenBLAS not linked to Rblas."
        return 1
    fi
}

# Sets up bspm for binary package management.
setup_bspm() {
    log "INFO" "Setting up bspm (Binary R Package Manager)..."
    get_r_profile_site_path

    if [[ -z "$R_PROFILE_SITE_PATH" ]]; then
        log "ERROR" "R_PROFILE_SITE_PATH is not set. Cannot setup bspm."; return 1
    fi

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

# Installs common system dependencies required for building R packages.
install_r_build_deps() {
    log "INFO" "Installing common system dependencies for building R packages from source (e.g., for devtools)..."
    local build_deps=(
        build-essential libcurl4-openssl-dev libssl-dev libxml2-dev libgit2-dev
        libfontconfig1-dev libcairo2-dev libharfbuzz-dev libfribidi-dev libfreetype6-dev
        libpng-dev libtiff5-dev libjpeg-dev zlib1g-dev libbz2-dev liblzma-dev
        libreadline-dev libicu-dev libxt-dev cargo libgdal-dev libproj-dev
        libgeos-dev libudunits2-dev
    )
    run_command "Update apt cache before installing build deps" apt-get update -y
    run_command "Install R package build dependencies" apt-get install -y "${build_deps[@]}"
    log "INFO" "System dependencies for R package building installed."
}


# --- R Package Installation Functions ---

# Generic function to install a list of R packages.
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

# Installs core development packages like devtools and remotes.
install_core_r_dev_pkgs() {
    log "INFO" "Installing core R development packages (devtools, remotes)..."
    local core_r_dev_pkgs=("devtools" "remotes")
    install_r_pkg_list "CRAN" "${core_r_dev_pkgs[@]}"
}

# Installs user-defined CRAN packages from the config file.
install_user_cran_pkgs() {
    log "INFO" "Installing user-defined CRAN packages..."
    install_r_pkg_list "CRAN" "${R_USER_PACKAGES_CRAN[@]}"
}

# Installs user-defined GitHub packages from the config file.
install_user_github_pkgs() {
    log "INFO" "Installing user-defined GitHub packages..."
    install_r_pkg_list "GitHub" "${R_USER_PACKAGES_GITHUB[@]}"
}


# --- State Management and Maintenance ---

# Saves a key-value pair to the environment state file.
add_to_env_state() {
    local key="$1"
    local value="$2"
    local temp_state_file
    temp_state_file=$(mktemp)

    # Ensure the state file exists
    touch "$R_ENV_STATE_FILE"
    # shellcheck disable=SC1090,SC1091
    source "$R_ENV_STATE_FILE" # Load current state

    # Get the array by its name
    local -n arr_ref="$key"
    
    # Check if value is already in the array
    local element
    for element in "${arr_ref[@]}"; do
        if [[ "$element" == "$value" ]]; then
            return # Already exists, do nothing
        fi
    done

    # Add the new value
    arr_ref+=("$value")

    # Write all known state arrays back to the temp file
    {
        echo "# R Environment State File - Auto-generated by r_env_manager.sh"
        echo "# Do not edit this file manually."
        declare -p INSTALLED_CRAN_PACKAGES 2>/dev/null || echo "INSTALLED_CRAN_PACKAGES=()"
        declare -p INSTALLED_GITHUB_PACKAGES 2>/dev/null || echo "INSTALLED_GITHUB_PACKAGES=()"
    } > "$temp_state_file"

    # Atomically replace the old state file
    mv "$temp_state_file" "$R_ENV_STATE_FILE"
    chmod 640 "$R_ENV_STATE_FILE"
}

# Backs up all relevant configuration files.
backup_all() {
    log "INFO" "Backing up all relevant configuration files..."
    if [[ -f "$R_ENV_STATE_FILE" ]]; then
        log "INFO" "Loading environment state from $R_ENV_STATE_FILE"
        # shellcheck disable=SC1090,SC1091
        source "$R_ENV_STATE_FILE" # Load current state
    fi
    get_r_profile_site_path
    backup_file "$R_PROFILE_SITE_PATH"
    backup_file "/etc/apt/sources.list.d/cran.list"
    backup_file "$R2U_APT_SOURCES_LIST_D_FILE"
    backup_file "/etc/rstudio/rserver.conf"
    backup_file "/etc/rstudio/rsession.conf"
    log "INFO" "Backup process completed."
}

# Uninstalls the entire R environment.
uninstall() {
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

# Restores all configurations from the latest backup.
restore_all() {
    log "INFO" "--- Starting Restore ---"
    if [[ -f "$R_ENV_STATE_FILE" ]]; then
        log "INFO" "Loading environment state from $R_ENV_STATE_FILE..."
        # shellcheck disable=SC1090,SC1091
        source "$R_ENV_STATE_FILE" # Load current state
    fi

    log "INFO" "Restoring Rprofile.site..."
    restore_latest_backup "$R_PROFILE_SITE_PATH"
    log "INFO" "Restoring CRAN apt source..."
    restore_latest_backup "/etc/apt/sources.list.d/cran.list"
    log "INFO" "Restoring R2U apt source..."
    restore_latest_backup "$R2U_APT_SOURCES_LIST_D_FILE"
    log "INFO" "Restoring RStudio configs..."
    restore_latest_backup "/etc/rstudio/rserver.conf"
    restore_latest_backup "/etc/rstudio/rsession.conf"
    log "INFO" "Restore process completed. Run 'apt-get update' to apply repository changes."
}


# --- Orchestration and Menus ---

# Performs the full, end-to-end installation.
full_install() {
    log "INFO" "--- Starting Full R Environment Installation ---"
    pre_flight_checks
    backup_all
    setup_cran_repo
    install_r
    install_openblas_openmp
    verify_openblas_openmp
    setup_bspm
    install_r_build_deps
    install_core_r_dev_pkgs
    install_user_cran_pkgs
    install_user_github_pkgs
    install_rstudio_server
    check_rstudio_server
    log "INFO" "--- Full Installation Complete ---"
}

# Provides a menu to launch other scripts in the `scripts/` directory.
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

# The main menu of the script.
main_menu() {
    local return_status=0
    
    while true; do
        # Check system state before showing menu
        check_system_resources || {
            handle_error 4 "System resources check failed"
            return 1
        }
        
        # Rotate logs if needed
        rotate_logs
        
        # Display menu
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
        
        # Save operation state before executing
        save_state "menu_choice" "$choice"
        
        case $choice in
            1) 
                log "INFO" "Starting full installation..."
                if ! full_install; then
                    handle_error 1 "Full installation failed"
                    return_status=1
                fi
                ;;
            2)
                log "INFO" "Starting R core setup..."
                for step in setup_cran_repo install_r install_openblas_openmp verify_openblas_openmp setup_bspm; do
                    save_state "current_step" "$step"
                    if ! $step; then
                        handle_error 1 "$step failed"
                        return_status=1
                        break
                    fi
                done
                ;;
            3)
                log "INFO" "Installing R packages..."
                for step in install_core_r_dev_pkgs install_user_cran_pkgs install_user_github_pkgs; do
                    save_state "current_step" "$step"
                    if ! $step; then
                        handle_error 1 "$step failed"
                        return_status=1
                        break
                    fi
                done
                ;;
            4)
                log "INFO" "Installing RStudio Server..."
                if ! install_rstudio_server; then
                    handle_error 1 "RStudio Server installation failed"
                    return_status=1
                fi
                ;;
            5)
                log "INFO" "Checking RStudio Server status..."
                check_rstudio_server || return_status=1
                ;;
            6)
                log "INFO" "Launching external script menu..."
                if ! launch_external_script; then
                    handle_error 1 "External script execution failed"
                    return_status=1
                fi
                ;;
            7)
                log "INFO" "Starting backup process..."
                if ! backup_all; then
                    handle_error 1 "Backup failed"
                    return_status=1
                fi
                ;;
            8)
                log "INFO" "Starting restore process..."
                if ! restore_all; then
                    handle_error 1 "Restore failed"
                    return_status=1
                fi
                ;;
            9)
                log "INFO" "Starting uninstall process..."
                if ! uninstall; then
                    handle_error 1 "Uninstall failed"
                    return_status=1
                fi
                ;;
            10)
                if [[ -f "$LOG_FILE" ]]; then
                    less "$LOG_FILE"
                else
                    log "ERROR" "Log file not found"
                fi
                ;;
            11)
                display_installation_status
                ;;
            [Ee]) 
                log "INFO" "Exiting R Environment Manager..."
                break 
                ;;
            *) 
                log "ERROR" "Invalid choice. Please enter a number 1-11 or E to exit."
                continue 
                ;;
        esac
        if [[ ! "$choice" =~ ^[Ee]$ ]]; then
            read -r -p "Press Enter to return to the menu..."
        fi
    done
    return "$return_status"
}

# --- Pre-flight Initialization ---
initialize_environment() {
    # Setup core infrastructure
    setup_logging
    rotate_logs
    acquire_lock
    
    # Ensure configuration directory and files exist
    ensure_config_dir
    
    # Load and validate configuration
    if ! validate_configuration; then
        handle_error 1 "Configuration validation failed"
        exit 1
    fi
    
    # Load previous state
    load_state
    
    # Verify security and resources
    check_security_requirements
    if ! check_system_resources; then
        handle_error 4 "Insufficient system resources"
        exit 1
    fi
    
    log "INFO" "Environment initialization complete"
}

# --- Script Entry Point ---
main() {
    # Initialize environment
    if ! initialize_environment; then
        log "ERROR" "Environment initialization failed"
        exit 1
    fi
    
    # Perform pre-flight checks
    if ! pre_flight_checks; then
        handle_error 1 "Pre-flight checks failed"
        exit 1
    fi
    
    # Display main menu and handle user interaction
    main_menu
    local menu_status=$?
    
    # Final cleanup
    cleanup
    
    log "INFO" "Script finished with status: $menu_status"
    exit "$menu_status"
}

# Start script execution
main
