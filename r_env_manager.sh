#!/usr/bin/env bash

################################################################################
#
# R Environment Manager (`r_env_manager.sh`)
#
# Version: 2.0.0 (Definitive)
# Last Updated: 2025-09-09
#
# This script orchestrates the complete setup and management of an R
# development environment on Debian-based systems. It is designed to be
# robust, idempotent, and follow system engineering best practices.
#
################################################################################

set -euo pipefail

# --- Source Utilities First ---
SCRIPT_DIR_INIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR_INIT}/lib/common_utils.sh"

# --- Global Constants and Configuration ---
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="${SCRIPT_DIR_INIT}"
readonly LOG_DIR="/var/log/r_env_manager"
readonly BACKUP_DIR="/var/backups/r_env_manager"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"
readonly STATE_FILE="${SCRIPT_DIR}/.r_env_state"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
readonly LOCK_FILE="/var/run/${SCRIPT_NAME}.lock"
readonly PID_FILE="/var/run/${SCRIPT_NAME}.pid"
readonly CONFIG_FILE="${CONFIG_DIR}/r_env_manager.conf"

# --- Use the standard, reliable system-wide path for R configuration ---
readonly R_PROFILE_SITE_PATH="/etc/R/Rprofile.site"

export MAIN_LOG_FILE="${LOG_FILE}"
export MAX_RETRIES=3
export TIMEOUT=1800
export DEBIAN_FRONTEND=noninteractive
declare -A OPERATION_STATE

# --- Core Infrastructure ---
acquire_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
        log "FATAL" "Another instance is running (PID: $pid)."
        exit 1
    fi
    ensure_dir_exists "$(dirname "$LOCK_FILE")"
    touch "$LOCK_FILE"
    echo $$ > "$PID_FILE"
}

check_system_resources() {
    local min_memory=${MIN_MEMORY_MB:-2048}
    local min_disk=${MIN_DISK_MB:-5120}
    
    # Check available memory
    local available_memory
    available_memory=$(free -m | awk '/^Mem:/{print $7}')
    if (( available_memory < min_memory )); then
        handle_error 4 "Insufficient memory (${available_memory}MB available, ${min_memory}MB required)."
        return 1
    fi
    
    # Check available disk space
    local available_disk
    available_disk=$(df -m "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    if (( available_disk < min_disk )); then
        handle_error 4 "Insufficient disk space (${available_disk}MB available, ${min_disk}MB required)."
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
    # Save original stderr
    exec 3>&2
    # Redirect stderr through tee
    exec 2> >(tee -a "$LOG_FILE" >&2)
}

cleanup() {
    local exit_code=$?
    log "INFO" "Script execution ending with code: $exit_code"
    # Remove lock file if it exists
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
    # Remove PID file if it exists
    if [[ -f "$PID_FILE" ]]; then
        rm -f "$PID_FILE"
    fi
    # Restore original stderr
    exec 2>&3
    exit "$exit_code"
}

# Set up trap handlers
trap cleanup EXIT
trap 'log "FATAL" "Received signal to terminate."; exit 1' HUP INT QUIT TERM
check_security_requirements() { if [[ $EUID -ne 0 ]]; then log "FATAL" "This script must be run as root."; exit 1; fi; local insecure_path_found=0; local old_ifs="$IFS"; IFS=':'; for dir in $PATH; do if [[ "$dir" == "." ]] || [[ -z "$dir" ]]; then insecure_path_found=1; break; fi; done; IFS="$old_ifs"; if [[ $insecure_path_found -eq 1 ]]; then log "FATAL" "Insecure PATH detected."; exit 1; fi; for dir in "$LOG_DIR" "$BACKUP_DIR"; do ensure_dir_exists "$dir"; chmod 750 "$dir"; done; }
# (Other core functions like config loading, state management, etc. are omitted for brevity but should be included from previous versions)

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

# --- NEW --- System Time Synchronization
sync_system_time() {
    log "INFO" "Attempting to synchronize system time..."
    if command -v timedatectl &>/dev/null; then
        run_command "Enable and check NTP time synchronization" "timedatectl set-ntp true"
        log "INFO" "System time synchronization enabled via timedatectl."
    elif command -v ntpdate &>/dev/null; then
        run_command "Synchronize time using ntpdate" "ntpdate pool.ntp.org"
        log "INFO" "System time synchronized via ntpdate."
    else
        log "WARN" "Neither timedatectl nor ntpdate found. Skipping time synchronization."
        log "WARN" "If apt commands fail, please manually sync your system's clock."
    fi
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


# --- Main Installation and Verification Functions ---

setup_cran_repo() {
    log "INFO" "Setting up CRAN repository..."
    local ubuntu_codename=$(lsb_release -cs)
    local cran_repo_line="deb [signed-by=/etc/apt/trusted.gpg.d/cran.gpg] ${CRAN_REPO_URL_BIN} ${ubuntu_codename}-cran40/"
    run_command "Add CRAN apt key" "wget -qO- \"${CRAN_APT_KEY_URL}\" | gpg --dearmor > \"/etc/apt/trusted.gpg.d/cran.gpg\""
    echo "$cran_repo_line" > /etc/apt/sources.list.d/cran.list
    run_command "Update apt package list" "apt-get update"
}

install_r() {
    if command -v R &>/dev/null; then log "INFO" "R is already installed."; return 0; fi
    log "INFO" "Installing R base and development packages..."
        if run_command "Install R base packages" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends r-base r-base-dev"; then
        log "INFO" "SUCCESS: R base packages installed."
    else
        handle_error $? "Failed to install R base packages."; return 1
    fi
}

install_openblas_openmp() {
    log "INFO" "Installing OpenBLAS and OpenMP for performance..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y libopenblas-dev libomp-dev; then
        log "INFO" "SUCCESS: OpenBLAS and OpenMP installed."
    else
        handle_error $? "Failed to install OpenBLAS/OpenMP packages."; return 1
    fi
}


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
    log "INFO" "--- Starting bspm (Binary R Package Manager) Setup ---"

    # 1. ALWAYS clean up previous configurations to ensure idempotency.
    log "INFO" "Cleaning up previous bspm entries in Rprofile.site..."
    sed -i '/# Added by r_env_manager for bspm/,+3d' "$R_PROFILE_SITE_PATH"

    # 2. Manually add the r2u repository and key.
    log "INFO" "Configuring r2u repository for binary packages..."
    local ubuntu_codename
    ubuntu_codename=$(lsb_release -cs)
    run_command "Add r2u GPG key" "wget -qO- https://eddelbuettel.github.io/r2u/assets/dirk_eddelbuettel_key.asc | tee /etc/apt/trusted.gpg.d/cranapt_key.asc >/dev/null"
    echo "deb [arch=amd64] https://r2u.stat.illinois.edu/ubuntu ${ubuntu_codename} main" | tee "${R2U_APT_SOURCES_LIST_D_FILE}" >/dev/null

    # 3. Update apt lists to read the new repository.
    run_command "Update apt package list" "apt-get update"

    # 4. Install the binary package 'r-cran-bspm' and its prerequisites.
    log "INFO" "Installing r-cran-bspm and prerequisites..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y r-cran-bspm python3-dbus python3-gi python3-apt; then
        handle_error $? "Failed to install r-cran-bspm package via apt."; return 1
    fi

    # 5. Configure Rprofile.site with the user-specified settings.
    log "INFO" "Writing bspm configuration to Rprofile.site..."
    cat >> "$R_PROFILE_SITE_PATH" << EOF

# Added by r_env_manager for bspm
suppressMessages(bspm::enable())
options(bspm.sudo = TRUE)
#options(bspm.allow.sysreqs = TRUE)
EOF

    # 6. Inform the user and prompt for a reboot.
    log "INFO" "SUCCESS: bspm has been installed and configured."
    printf "\n"
    log "WARN" "A system reboot is required for all changes to take full effect."
    log "WARN" "This ensures that D-Bus and all system services are in a clean state."
    printf "\n"
    
    read -r -p "Reboot now? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        log "INFO" "Rebooting system now..."
        # Wait a moment to ensure the log is written before the system goes down
        sleep 3
        reboot
    else
        log "INFO" "Reboot cancelled. Please reboot the system manually."
        log "INFO" "After rebooting, you can perform a final verification by running:"
        printf "\n    sudo Rscript -e 'bspm::install_sys(\"units\"); bspm::remove_sys(\"units\"); bspm::available_sys()'\n\n"
    fi

    log "INFO" "--- bspm Setup Complete ---"
}


verify_bspm() {
    log "INFO" "--- Starting bspm Verification (Post-Reboot) ---"

    # Step 1: Check if the configuration exists in the system-wide R profile.
    log "INFO" "Step 1: Checking for bspm configuration in ${R_PROFILE_SITE_PATH}..."
    if ! grep -q "suppressMessages(bspm::enable())" "$R_PROFILE_SITE_PATH"; then
        log "ERROR" "FAILURE: The bspm configuration is MISSING from Rprofile.site."
        save_state "bspm_status" "unconfigured"
        return 1
    fi
    log "INFO" "SUCCESS: bspm configuration found in Rprofile.site."

    # Step 2: Perform a live test of bspm by installing and removing a system package.
    log "INFO" "Step 2: Performing a live test of bspm (installing/removing 'units' package)..."
    log "INFO" "This command will test the full functionality. R output will be displayed below:"
    
    local bspm_test_command="Rscript -e 'bspm::install_sys(\"units\"); bspm::remove_sys(\"units\")'"
    
    # --- THIS IS THE CORRECTED BLOCK ---
    # We call the Rscript command directly to prevent hanging on hidden prompts.
    # The 'eval' is used to correctly handle the quotes within the command.
    if eval "$bspm_test_command"; then
        log "INFO" "SUCCESS: The bspm live test completed without errors."
    else
        local exit_code=$?
        log "ERROR" "FAILURE: The bspm live test failed with exit code ${exit_code}."
        log "ERROR" "Please review the detailed R output above and in the log file: ${LOG_FILE}"
        save_state "bspm_status" "failed_test"
        return 1
    fi
    # --- END OF CORRECTION ---

    save_state "bspm_status" "verified"
    log "INFO" "--- SUCCESS: bspm is fully installed and functional. ---"
}


# --- RStudio Server Functions ---
get_latest_rstudio_info() {
    log "INFO" "Detecting latest RStudio Server version..."
    
    # Fallback values from configuration
    local rstudio_version=${RSTUDIO_VERSION_FALLBACK:-"2023.06.0"}
    local rstudio_arch=${RSTUDIO_ARCH_FALLBACK:-"amd64"}
    local max_retry_attempts=3
    local retry_delay=5
    local attempt=1
    
    # Try to get the download page with retries
    local html=""
    while [[ $attempt -le $max_retry_attempts ]]; do
        log "INFO" "Attempt $attempt of $max_retry_attempts: Fetching RStudio Server version info..."
        if html=$(curl -m 30 -fsSL "https://posit.co/download/rstudio-server/" 2>/dev/null); then
            log "INFO" "Successfully retrieved version information."
            break
        else
            log "WARN" "Attempt $attempt failed to fetch version information."
            if [[ $attempt -lt $max_retry_attempts ]]; then
                log "INFO" "Retrying in $retry_delay seconds..."
                sleep $retry_delay
            fi
            ((attempt++))
        fi
    done
    
    # If all attempts failed, use fallback values
    if [[ -z "$html" ]]; then
        log "WARN" "Could not fetch latest version info after $max_retry_attempts attempts."
        log "INFO" "Using fallback version: $rstudio_version ($rstudio_arch)"
        echo "$rstudio_version $rstudio_arch"
        return 0
    fi
    # Try to parse a modern version format safely. Avoid letting grep/sed failures
    # trigger 'set -e' by using '|| true' and checking results before using them.
    if [[ -n "$html" ]]; then
        local parsed_filename=""
        # Prefer grep -oE (extended regex) which is more portable than -P (Perl)
        parsed_filename=$(printf "%s" "$html" | grep -oE 'rstudio-server-[0-9]+(\.[0-9]+)*(-[0-9]+)?-amd64\\.deb' | head -n1 || true)

        if [[ -n "$parsed_filename" ]]; then
            # Extract version portion from filename safely
            local parsed_version=""
            parsed_version=$(sed -E 's/rstudio-server-([0-9]+(\.[0-9]+)*(\-[0-9]+)?)\-amd64\\.deb/\1/' <<<"$parsed_filename" || true)
            if [[ -n "$parsed_version" ]]; then
                rstudio_version="$parsed_version"
            fi
        else
            log "DEBUG" "Could not parse RStudio .deb filename from HTML; keeping fallback: ${rstudio_version}"
        fi
    fi

    RSTUDIO_DEB_FILENAME="rstudio-server-${rstudio_version}-${rstudio_arch}.deb"
    RSTUDIO_DEB_URL="https://download2.rstudio.org/server/bionic/${rstudio_arch}/${RSTUDIO_DEB_FILENAME}"
    log "INFO" "Using RStudio Server version: ${rstudio_version}"
    log "INFO" "RStudio Server download URL: ${RSTUDIO_DEB_URL}"
}   


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
        log "INFO" "No ${pkg_type} R packages specified to install."
        return
    fi

    log "INFO" "Processing ${pkg_type} packages: ${r_packages_list[*]}"

    # --- Step 1: Efficiently find which packages are actually missing ---
    local r_check_pkg_vector
    r_check_pkg_vector=$(printf "'%s'," "${r_packages_list[@]}")
    r_check_pkg_vector="c(${r_check_pkg_vector%,})"

    local check_script_path="/tmp/check_missing_pkgs.R"
    cat > "$check_script_path" <<EOF
    # For GitHub, we check the package name, not the full repo path
    all_pkgs_full <- ${r_check_pkg_vector}
    all_pkgs_short <- gsub(".*/", "", all_pkgs_full)
    
    installed_pkgs <- installed.packages()[, "Package"]
    missing_pkgs_short <- all_pkgs_short[!all_pkgs_short %in% installed_pkgs]
    
    # Find the corresponding full repo paths for the missing packages
    missing_pkgs_full <- all_pkgs_full[match(missing_pkgs_short, all_pkgs_short)]

    if (length(missing_pkgs_full) > 0) {
        cat(paste(missing_pkgs_full, collapse = "\n"))
    }
EOF
    
    local missing_packages
    missing_packages=$(Rscript "$check_script_path")
    rm -f "$check_script_path"

    if [[ -z "$missing_packages" ]]; then
        log "INFO" "All specified packages are already installed."
        return 0
    fi
    
    log "INFO" "Packages to install: ${missing_packages//$'\n'/ }"

    # --- Step 2: Build and execute the installation script ---
    local r_install_pkg_vector
    r_install_pkg_vector=$(echo "$missing_packages" | awk '{printf "\"%s\",", $1}' | sed 's/,$//')
    r_install_pkg_vector="c(${r_install_pkg_vector})"

    local pkg_install_script_path="/tmp/install_packages.R"
    
    cat > "$pkg_install_script_path" <<EOF
    # --- Configuration ---
    pkgs_to_install <- ${r_install_pkg_vector}
    pkg_type <- "${pkg_type}"
    cran_mirror <- "${CRAN_MIRROR_URL}"
    options(repos = c(CRAN = cran_mirror))

    # --- This is the definitive logic that mimics a successful interactive session ---
    if (pkg_type == "CRAN") {
        if (requireNamespace('bspm', quietly = TRUE)) {
            message("--> bspm package found. Enabling binary installs...")
            suppressMessages(bspm::enable()) 
        } else {
            message("--> bspm not available. Using source install.")
        }
        # This single call is intercepted by bspm if active, otherwise it uses source.
        install.packages(pkgs_to_install)

    } else if (pkg_type == "GitHub") {
        message("--> Installing GitHub packages...")
        if (!requireNamespace('remotes', quietly=TRUE)) install.packages('remotes')
        # --- THIS IS THE CORRECTED GITHUB CALL ---
        # We pass the vector of packages to install_github
        remotes::install_github(pkgs_to_install, force = TRUE)
    }

    # --- Final verification ---
    installed_pkgs_after <- installed.packages()[, "Package"]
    pkgs_to_verify <- gsub(".*/", "", pkgs_to_install) # Get just the package names for verification
    failed_pkgs <- pkgs_to_verify[!pkgs_to_verify %in% installed_pkgs_after]
    if (length(failed_pkgs) > 0) {
        stop(paste("FATAL: Failed to install:", paste(failed_pkgs, collapse = ", ")))
    }
    message("All packages processed successfully.")
EOF

    # --- Execute the single R script ---
    log "INFO" "Running R package installation script. Output will be displayed below:"
    if eval "dbus-run-session Rscript '${pkg_install_script_path}'"; then
        log "INFO" "SUCCESS: R package installation script completed."
    else
        handle_error $? "R package installation script failed. Check R output for details."
        return 1
    fi

    rm -f "$pkg_install_script_path"
}

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
    verify_bspm 
    install_r_build_deps
    install_core_r_dev_pkgs
    install_user_cran_pkgs
    install_user_github_pkgs
    install_rstudio_server
    check_rstudio_server
    log "INFO" "--- Full Installation Complete ---"
}

#launch_external_script() {
#        local scripts_dir="${SCRIPT_DIR}/scripts"
#    if [[ ! -d "$scripts_dir" ]]; then
#        log "WARN" "Scripts directory not found at '${scripts_dir}'."
#        return
#    fi
#
#    local scripts_found=()
#    while IFS= read -r -d $'\0'; do
#        scripts_found+=("$REPLY")
#    done < <(find "$scripts_dir" -maxdepth 1 -type f -name "*.sh" -print0)
#
#    if [[ ${#scripts_found[@]} -eq 0 ]]; then
#        log "WARN" "No executable scripts found in '${scripts_dir}'."
#        return
#    fi
#
#    printf "\n--- External Script Launcher ---\n"
#    printf "Select a script to run:\n"
#    local i=1
#    for script_path in "${scripts_found[@]}"; do
#        printf "%d. %s\n" "$i" "$(basename "$script_path")"
#        ((i++))
#    done
#    printf "B. Back to Main Menu\n"
#
#    local choice
#    read -r -p "Enter choice: " choice
#
#    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le ${#scripts_found[@]} ]]; then
#        local selected_script="${scripts_found[$((choice-1))]}"
#        log "INFO" "Executing selected script: ${selected_script}"
#        bash "$selected_script"
#    elif [[ "$choice" =~ ^[Bb]$ ]]; then
#        return
#    else
#        log "ERROR" "Invalid choice."
#    fi
#}


# =================================================================
# HELPER FUNCTIONS FOR EXTERNAL SCRIPT LAUNCHER
# =================================================================

# --- Handler for web-terminals-setup.sh ---
# This function provides the interactive sub-menu for the web terminals script.
_handle_web_terminals() {
    local script_path="$1"
    local action=""
    
    while true; do
        printf "\n--- Secure Web Access Manager ---\n"
        printf "Select an action for %s:\n" "$(basename "$script_path")"
        printf "1. Install Services\n"
        printf "2. Uninstall Services\n"
        printf "3. Check Status\n"
        printf "B. Back to Script Launcher\n"
        
        local choice
        read -r -p "Enter action choice: " choice

        case "$choice" in
            1) action="install"; break ;;
            2) action="uninstall"; break ;;
            3) action="status"; break ;;
            [Bb]*) return ;;
            *) log "ERROR" "Invalid option. Please try again." ;;
        esac
    done

    # If an action was selected, execute the script with that action
    if [[ -n "$action" ]]; then
        log "INFO" "Executing: ${script_path} ${action}"
        # Execute the script, passing the chosen action as the first argument
        bash "$script_path" "$action"
    fi
}

# --- Handler for nginx_setup.sh ---
# This function automatically provides the required config file argument.
_handle_nginx_setup() {
    local script_path="$1"
    # SCRIPT_DIR is from the parent r_env_manager.sh script
    local config_file="${SCRIPT_DIR}/config/nginx_setup.vars.conf"

    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "Nginx config file not found at ${config_file}. Cannot run script."
        return
    fi
    
    log "INFO" "Executing: ${script_path} with config ${config_file}"
    # Execute the script, passing the '-c' flag and the config path
    bash "$script_path" -c "$config_file"
}

# =================================================================
# MAIN EXTERNAL SCRIPT LAUNCHER
# =================================================================

launch_external_script() {
    local scripts_dir="${SCRIPT_DIR}/scripts"
    if [[ ! -d "$scripts_dir" ]]; then
        log "WARN" "Scripts directory not found at '${scripts_dir}'."
        return
    fi

    # Find all executable .sh files
    local scripts_found=()
    while IFS= read -r -d $'\0'; do
        scripts_found+=("$REPLY")
    done < <(find "$scripts_dir" -maxdepth 1 -type f -name "*.sh" -executable -print0 | sort -z)

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
        local script_name
        script_name=$(basename "$selected_script")

        # --- INTELLIGENT DISPATCHER ---
        # This case statement checks for scripts that need special handling.
        case "$script_name" in
            "secure-web-access-setup.sh")
                _handle_web_terminals "$selected_script"
                ;;
            "nginx_setup.sh")
                _handle_nginx_setup "$selected_script"
                ;;
            *)
                # Default case for any other script that takes no arguments.
                log "INFO" "Executing default script: ${selected_script}"
                bash "$selected_script"
                ;;
        esac

        # Pause to allow the user to see the output of the executed script
        echo
        read -r -p "Script finished. Press Enter to return to the launcher..."

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
        sync_system_time || {
            handle_error 4 "System Ntp out of Sync. Aborting menu."
            return 1
        }
        rotate_logs
        
        printf "\n================ R Environment Manager ================\n"
        printf "1.  Full Installation (Recommended for first run)\n"
        printf "2.  Install/Verify R, OpenBLAS, and bspm\n"
        printf "3.  Verify bspm\n"
        printf "4.  Install All User R Packages (CRAN & GitHub)\n"
        printf "5.  Install RStudio Server\n"
        printf "6.  Check RStudio Server Status\n"
        printf -- "-------------------- Maintenance --------------------\n"
        printf "7.  Launch Other Setup Scripts (Nginx, SSSD, etc.)\n"
        printf "8.  Backup All Configurations\n"
        printf "9.  Restore All Configurations from Last Backup\n"
        printf "10.  Uninstall Entire R Environment\n"
        printf "11. View Logs\n"
        printf "12. Check Installation Status\n"
        printf "E.  Exit\n"
        printf "=======================================================\n"
        
        read -r -p "Enter choice: " choice
        
        case $choice in
            1) full_install ;;
            2) setup_cran_repo; install_r; install_openblas_openmp; verify_openblas_openmp; setup_bspm ;;
            3) verify_bspm ;;
            4) install_core_r_dev_pkgs; install_user_cran_pkgs; install_user_github_pkgs ;;
            5) install_rstudio_server ;;
            6) check_rstudio_server ;;
            7) launch_external_script ;;
            8) backup_all ;;
            9) restore_all ;;
            10) uninstall ;;
            11) if [[ -f "$LOG_FILE" ]]; then less "$LOG_FILE"; else log "ERROR" "Log file not found"; fi ;;
            12) display_installation_status ;;
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
