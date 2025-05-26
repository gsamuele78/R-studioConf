#!/usr/bin/env bash

##############################################################################
# Script: setup_r_env.sh
# Desc:   Installs R, OpenBLAS, OpenMP, RStudio Server, BSPM, and R packages.
#         Includes auto-detection for latest RStudio Server, uninstall,
#         and backup/restore for Rprofile.site.
# Author: Your Name/Team
# Date:   $(date +%Y-%m-%d)
##############################################################################

# --- Configuration ---
set -euo pipefail 

export DEBIAN_FRONTEND=noninteractive

# Logging
LOG_DIR="/var/log/r_setup"
LOG_FILE="${LOG_DIR}/r_setup_$(date +'%Y%m%d_%H%M%S').log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE" 

# Backup
BACKUP_DIR="/opt/r_setup_backups"; mkdir -p "$BACKUP_DIR"

# System State File (for individual function calls)
R_ENV_STATE_FILE="/tmp/r_env_setup_state.sh"


# System
UBUNTU_CODENAME_DETECTED="" 
R_PROFILE_SITE_PATH=""
USER_SPECIFIED_R_PROFILE_SITE_PATH=""
FORCE_USER_CLEANUP="no"

# RStudio - Fallback Version
RSTUDIO_VERSION_FALLBACK="2023.12.1-402" 
RSTUDIO_ARCH_FALLBACK="amd64"
RSTUDIO_ARCH="${RSTUDIO_ARCH_FALLBACK}" 

RSTUDIO_VERSION="$RSTUDIO_VERSION_FALLBACK"
RSTUDIO_DEB_URL=""
RSTUDIO_DEB_FILENAME=""


# CRAN Repository
CRAN_REPO_URL_BASE="https://cloud.r-project.org"
CRAN_REPO_PATH_BIN="/bin/linux/ubuntu"
CRAN_REPO_PATH_SRC="/src/contrib" 
CRAN_REPO_URL_BIN="${CRAN_REPO_URL_BASE}${CRAN_REPO_PATH_BIN}"
CRAN_REPO_URL_SRC="${CRAN_REPO_URL_BASE}${CRAN_REPO_PATH_SRC}" 
CRAN_REPO_LINE="" # Will be: deb URL codename-cran40/
CRAN_APT_KEY_URL="https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc" # Direct URL to ASCII key
CRAN_APT_KEYRING_FILE="/etc/apt/trusted.gpg.d/cran_ubuntu_key.asc" # Path for ASCII key in trusted.gpg.d


# R2U/BSP Repository
R2U_REPO_URL_BASE="https://raw.githubusercontent.com/eddelbuettel/r2u/master/inst/scripts"
R2U_APT_SOURCES_LIST_D_FILE="/etc/apt/sources.list.d/r2u.list" 

# R Packages
R_PACKAGES_CRAN=(
    "terra" "raster" "sf" "enmSdmX" "dismo" "spThin" "rnaturalearth" "furrr"
    "doParallel" "future" "caret" "CoordinateCleaner" "tictoc" "devtools"
    "tidyverse" "dplyr" "spatstat" "ggplot2" "iNEXT" "DHARMa" "lme4" "glmmTMB"
    "geodata" "osmdata" "parallel" "doSNOW" "progress" "nngeo" "wdpar" "rgee" "tidyrgee"
    "data.table" "jsonlite" "httr" 
)
R_PACKAGES_GITHUB=(
    "SantanderMetGroup/transformeR"
    "SantanderMetGroup/mopa"
    "HelgeJentsch/ClimDatDownloadR"
)

UBUNTU_CODENAME="" 

if [[ -n "${CUSTOM_R_PROFILE_SITE_PATH_ENV:-}" ]]; then
    USER_SPECIFIED_R_PROFILE_SITE_PATH="${CUSTOM_R_PROFILE_SITE_PATH_ENV}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Rprofile.site path from env: ${USER_SPECIFIED_R_PROFILE_SITE_PATH}" | tee -a "$LOG_FILE"
fi

# --- Helper Functions ---
_log() {
    local type="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${type}] ${message}" | tee -a "$LOG_FILE"
}

_ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        _log "ERROR" "This script must be run as root or with sudo."
        exit 1
    fi
}

_run_command() {
    local cmd_desc="$1"; shift
    _log "INFO" "Start: $cmd_desc"
    _log "DEBUG" "Executing in _run_command: $*" 
    if [[ "$1" == "mv" ]]; then 
        _log "DEBUG" "mv source details: $(ls -ld "$2" 2>&1 || echo "source $2 not found")"
        _log "DEBUG" "mv target details: $(ls -ld "$3" 2>&1 || echo "target $3 not found")"
        _log "DEBUG" "mv target parent dir details: $(ls -ld "$(dirname "$3")" 2>&1 || echo "target parent dir for $3 not found")"
    fi
    if "$@" >>"$LOG_FILE" 2>&1; then
        _log "INFO" "OK: $cmd_desc"
        return 0
    else
        local exit_code=$?
        _log "ERROR" "FAIL: $cmd_desc (RC:$exit_code). See log: $LOG_FILE"
        if [ -f "$LOG_FILE" ]; then
            tail -n 10 "$LOG_FILE" | sed 's/^/    /' 
        fi
        return "$exit_code"
    fi
}

_backup_file() {
    local filepath="$1"
    if [[ -f "$filepath" || -L "$filepath" ]]; then
        local backup_filename
        backup_filename="$(basename "$filepath")_$(date +'%Y%m%d%H%M%S').bak"
        _log "INFO" "Backing up '${filepath}' to '${BACKUP_DIR}/${backup_filename}'"
        cp -a "$filepath" "${BACKUP_DIR}/${backup_filename}"
    else
        _log "INFO" "File '${filepath}' not found for backup. Skipping."
    fi
}

_restore_latest_backup() {
    local original_filepath="$1"
    local filename_pattern
    local latest_backup
    filename_pattern="$(basename "$original_filepath")_*.bak"
    latest_backup=$(find "$BACKUP_DIR" -name "$filename_pattern" -print0 | xargs -0 ls -1tr 2>/dev/null | tail -n 1)
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        _log "INFO" "Restoring '${original_filepath}' from latest backup '${latest_backup}'"
        cp -a "$latest_backup" "$original_filepath"
    else
        _log "INFO" "No backup found for '${original_filepath}' in '${BACKUP_DIR}' with pattern '${filename_pattern}'. Skipping restore."
    fi
}


_get_r_profile_site_path() {
    local log_details=false
    if [[ -z "$R_PROFILE_SITE_PATH" && -z "$USER_SPECIFIED_R_PROFILE_SITE_PATH" ]]; then
        log_details=true
    fi

    if $log_details; then _log "INFO" "Determining Rprofile.site path..."; fi

    if [[ -n "$USER_SPECIFIED_R_PROFILE_SITE_PATH" ]]; then
        if [[ "$R_PROFILE_SITE_PATH" != "$USER_SPECIFIED_R_PROFILE_SITE_PATH" ]]; then
            R_PROFILE_SITE_PATH="$USER_SPECIFIED_R_PROFILE_SITE_PATH"
            _log "INFO" "Using user-specified R_PROFILE_SITE_PATH: ${R_PROFILE_SITE_PATH}"
        fi
        return
    fi

    if command -v R &>/dev/null; then
        local r_home_output
        r_home_output=$(R RHOME 2>/dev/null || echo "") 
        if [[ -n "$r_home_output" && -d "$r_home_output" ]]; then
            local detected_path="${r_home_output}/etc/Rprofile.site"
            if [[ "$R_PROFILE_SITE_PATH" != "$detected_path" ]]; then
                _log "INFO" "Auto-detected R_PROFILE_SITE_PATH (from R RHOME): ${detected_path}"
            fi
            R_PROFILE_SITE_PATH="$detected_path"
            return
        fi
    fi

    local default_apt_path="/usr/lib/R/etc/Rprofile.site"
    local default_local_path="/usr/local/lib/R/etc/Rprofile.site"
    local new_detected_path=""

    if [[ -f "$default_apt_path" || -L "$default_apt_path" ]]; then
        new_detected_path="$default_apt_path"
        if $log_details || [[ "$R_PROFILE_SITE_PATH" != "$new_detected_path" ]]; then
            _log "INFO" "Auto-detected R_PROFILE_SITE_PATH (apt default): ${new_detected_path}"
        fi
    elif [[ -f "$default_local_path" || -L "$default_local_path" ]]; then
        new_detected_path="$default_local_path"
        if $log_details || [[ "$R_PROFILE_SITE_PATH" != "$new_detected_path" ]]; then
            _log "INFO" "Auto-detected R_PROFILE_SITE_PATH (local default): ${new_detected_path}"
        fi
    else
        new_detected_path="$default_apt_path"
        if $log_details || [[ "$R_PROFILE_SITE_PATH" != "$new_detected_path" ]]; then
            _log "INFO" "No Rprofile.site found. Defaulting to standard location for creation: ${new_detected_path}"
        fi
    fi
    R_PROFILE_SITE_PATH="$new_detected_path"
}


_safe_systemctl() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl "$@" >> "$LOG_FILE" 2>&1; then
            return 0 
        else
            local exit_code=$?
            if [[ "${CI:-false}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
                _log "WARN" "systemctl command '$*' failed (RC:$exit_code). Ignoring in CI context."
                return 0 
            else
                _log "ERROR" "systemctl command '$*' failed (RC:$exit_code)."
                return "$exit_code" 
            fi
        fi
    else
        _log "INFO" "systemctl command not found, skipping systemctl action: $*"
        return 0 
    fi
}


_is_vm_or_ci_env() {
    if [[ "${CI:-false}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]] || [[ -n "${TRAVIS:-}" ]]; then
        return 0 
    elif [[ "$EUID" -eq 0 ]]; then 
        return 0 
    else
        return 1 
    fi
}

# --- Core Functions ---
fn_get_latest_rstudio_info() {
    _log "INFO" "Attempting to detect latest RStudio Server for ${UBUNTU_CODENAME} ${RSTUDIO_ARCH}..."
    _log "WARN" "RStudio Server auto-detection is fragile and currently disabled. Using fallback version: ${RSTUDIO_VERSION_FALLBACK}"
    RSTUDIO_VERSION="$RSTUDIO_VERSION_FALLBACK"
    
    if [[ -z "${UBUNTU_CODENAME:-}" || -z "${RSTUDIO_ARCH:-}" ]] && [[ -f "$R_ENV_STATE_FILE" ]]; then
        _log "DEBUG" "fn_get_latest_rstudio_info: Sourcing state file as UBUNTU_CODENAME or RSTUDIO_ARCH is empty."
        # shellcheck source=/dev/null
        source "$R_ENV_STATE_FILE"
    fi
    RSTUDIO_DEB_URL="https://download2.rstudio.org/server/${UBUNTU_CODENAME}/${RSTUDIO_ARCH}/rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
    RSTUDIO_DEB_FILENAME="rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
    _log "INFO" "Using RStudio Server: ${RSTUDIO_VERSION} from ${RSTUDIO_DEB_URL}"
}

fn_pre_flight_checks() {
    _log "INFO" "Performing pre-flight checks..."
    _ensure_root 

    _log "INFO" "Updating apt package lists..."
    if ! apt-get update -y >> "$LOG_FILE" 2>&1; then
        _log "ERROR" "apt-get update failed. Subsequent package installations may fail. Check network and repository configuration."
    else
        _log "INFO" "apt-get update successful."
    fi

    UBUNTU_CODENAME_DETECTED=$(lsb_release -cs 2>/dev/null || echo "unknown")

    if [[ "$UBUNTU_CODENAME_DETECTED" == "unknown" ]] || ! command -v lsb_release &>/dev/null; then
        if ! command -v lsb_release &>/dev/null; then 
             _log "WARN" "lsb_release command not found. Attempting to install lsb-release."
        else 
             _log "WARN" "lsb_release -cs returned '${UBUNTU_CODENAME_DETECTED}'. Attempting to ensure lsb-release is correctly installed/functional."
        fi
        
        _run_command "Install lsb-release" apt-get install -y lsb-release
        
        if command -v lsb_release &>/dev/null; then
            UBUNTU_CODENAME_DETECTED=$(lsb_release -cs 2>/dev/null || echo "unknown_after_install")
        else
            _log "ERROR" "lsb_release still not found after attempting installation. Cannot determine Ubuntu codename."
            UBUNTU_CODENAME_DETECTED="critical_failure_lsb_release" 
        fi
    fi
    
    UBUNTU_CODENAME=$(echo "$UBUNTU_CODENAME_DETECTED" | tr -d '[:space:]')
    export UBUNTU_CODENAME 
    _log "DEBUG" "In fn_pre_flight_checks: UBUNTU_CODENAME_DETECTED (raw)='${UBUNTU_CODENAME_DETECTED}', UBUNTU_CODENAME (sanitized & exported)='${UBUNTU_CODENAME}'."

    _log "INFO" "Using Ubuntu codename: ${UBUNTU_CODENAME}"
    if [[ -z "$UBUNTU_CODENAME" || "$UBUNTU_CODENAME" == "unknown" || "$UBUNTU_CODENAME" == "unknown_after_install" || "$UBUNTU_CODENAME" == "critical_failure_lsb_release" ]]; then
        _log "ERROR" "Ubuntu codename is invalid or could not be determined (value: '${UBUNTU_CODENAME}'). This is critical. Exiting."
        exit 1
    fi

    if command -v dpkg &>/dev/null; then
        RSTUDIO_ARCH=$(dpkg --print-architecture)
        _log "INFO" "Detected system architecture: ${RSTUDIO_ARCH}"
        if [[ "$RSTUDIO_ARCH" != "amd64" && "$RSTUDIO_ARCH" != "arm64" ]]; then
            _log "WARN" "Unsupported architecture '${RSTUDIO_ARCH}' detected by dpkg. Defaulting to '${RSTUDIO_ARCH_FALLBACK}' for RStudio Server."
            RSTUDIO_ARCH="$RSTUDIO_ARCH_FALLBACK"
        fi
    else
        _log "WARN" "dpkg command not found. Using fallback RStudio architecture: ${RSTUDIO_ARCH_FALLBACK}"
        RSTUDIO_ARCH="$RSTUDIO_ARCH_FALLBACK"
    fi
    export RSTUDIO_ARCH

    fn_get_latest_rstudio_info 

    CRAN_REPO_LINE="deb ${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME}-cran40/"
    export CRAN_REPO_LINE 
    _log "DEBUG" "In fn_pre_flight_checks: CRAN_REPO_LINE constructed and exported as: '${CRAN_REPO_LINE}'"
    _log "DEBUG" "In fn_pre_flight_checks: CRAN_APT_KEYRING_FILE is: '${CRAN_APT_KEYRING_FILE}'"
    _log "INFO" "RStudio Server version to be used: ${RSTUDIO_VERSION} (URL: ${RSTUDIO_DEB_URL})"

    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "/etc/apt/trusted.gpg.d" "/etc/apt/keyrings" 

    local essential_deps=("wget" "gpg" "apt-transport-https" "ca-certificates" "curl" "gdebi-core" "software-properties-common" "dirmngr")
    local missing_deps=()
    for dep in "${essential_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        _log "INFO" "Installing missing essential script dependencies: ${missing_deps[*]}"
        _run_command "Install essential dependencies: ${missing_deps[*]}" apt-get install -y "${missing_deps[@]}"
    fi
    _log "INFO" "Pre-flight checks completed."

    _log "INFO" "Writing environment state to ${R_ENV_STATE_FILE}"
    {
        echo "export UBUNTU_CODENAME=\"${UBUNTU_CODENAME}\""
        echo "export RSTUDIO_ARCH=\"${RSTUDIO_ARCH}\""
        echo "export RSTUDIO_VERSION=\"${RSTUDIO_VERSION}\""
        echo "export RSTUDIO_DEB_URL=\"${RSTUDIO_DEB_URL}\""
        echo "export RSTUDIO_DEB_FILENAME=\"${RSTUDIO_DEB_FILENAME}\""
        echo "export CRAN_REPO_LINE=\"${CRAN_REPO_LINE}\""
        echo "export CRAN_APT_KEYRING_FILE=\"${CRAN_APT_KEYRING_FILE}\"" 
        echo "export CRAN_APT_KEY_URL=\"${CRAN_APT_KEY_URL}\""         
    } > "$R_ENV_STATE_FILE"
    _log "INFO" "State file written. If running functions individually, subsequent steps might use this."
}


fn_add_cran_repo() {
    _log "INFO" "Adding CRAN repository (using CRAN recommended method)..."
    
    if [[ -z "${UBUNTU_CODENAME:-}" || -z "${CRAN_REPO_LINE:-}" || -z "${CRAN_APT_KEYRING_FILE:-}" || -z "${CRAN_APT_KEY_URL:-}" ]]; then
        _log "WARN" "Key variables not set in current environment for fn_add_cran_repo."
        if [[ -f "$R_ENV_STATE_FILE" ]]; then
            _log "INFO" "Attempting to source state from ${R_ENV_STATE_FILE}"
            # shellcheck source=/dev/null
            source "$R_ENV_STATE_FILE"
        else
            _log "WARN" "State file ${R_ENV_STATE_FILE} not found."
        fi
    fi

    _log "DEBUG" "Entering fn_add_cran_repo: UBUNTU_CODENAME='${UBUNTU_CODENAME:-}', CRAN_REPO_LINE='${CRAN_REPO_LINE:-}', CRAN_APT_KEYRING_FILE='${CRAN_APT_KEYRING_FILE:-}'"

    if [[ -z "$UBUNTU_CODENAME" || -z "$CRAN_REPO_LINE" || -z "$CRAN_APT_KEYRING_FILE" || -z "$CRAN_APT_KEY_URL" ]]; then
        _log "ERROR" "FATAL: One or more critical CRAN variables is empty in fn_add_cran_repo. Run 'fn_pre_flight_checks' first. Aborting."
        return 1 
    fi

    if ! command -v add-apt-repository &>/dev/null; then
        _log "INFO" "'add-apt-repository' not found. Installing 'software-properties-common'."
        _run_command "Install software-properties-common" apt-get install -y software-properties-common
    fi
    
    if ! dpkg -s dirmngr &>/dev/null; then 
        _log "INFO" "dirmngr package not found. Installing dirmngr."
        _run_command "Install dirmngr" apt-get install -y dirmngr
    fi

    if [[ ! -f "$CRAN_APT_KEYRING_FILE" ]]; then
        _log "INFO" "Adding CRAN GPG key to ${CRAN_APT_KEYRING_FILE}"
        mkdir -p "$(dirname "$CRAN_APT_KEYRING_FILE")" 
        local key_download_cmd_desc="Download CRAN GPG key from ${CRAN_APT_KEY_URL} to ${CRAN_APT_KEYRING_FILE}"
        _log "INFO" "Start: ${key_download_cmd_desc}"
        
        local temp_key_file
        temp_key_file=$(mktemp)
        
        if curl -fsSL "${CRAN_APT_KEY_URL}" -o "$temp_key_file" >> "$LOG_FILE" 2>&1; then
            _log "DEBUG" "curl successfully downloaded key to $temp_key_file"
            if tee "${CRAN_APT_KEYRING_FILE}" > /dev/null < "$temp_key_file"; then
                 _log "INFO" "OK: ${key_download_cmd_desc}"
                 if [[ ! -s "$CRAN_APT_KEYRING_FILE" ]]; then 
                    _log "ERROR" "CRAN GPG key file ${CRAN_APT_KEYRING_FILE} is empty after download and tee. Key may not have been added correctly."
                    rm -f "$CRAN_APT_KEYRING_FILE" 
                    rm -f "$temp_key_file"
                    return 1
                 fi
            else
                local tee_rc=$?
                _log "ERROR" "Failed to tee key from $temp_key_file to ${CRAN_APT_KEYRING_FILE} (RC: $tee_rc)"
                rm -f "$temp_key_file"
                return 1
            fi
            rm -f "$temp_key_file" 
        else
            local curl_rc=$? 
            _log "ERROR" "FAIL: Curl command for ${key_download_cmd_desc} (RC:$curl_rc). See log: $LOG_FILE"
            rm -f "$temp_key_file" 
            return 1
        fi
    else
        _log "INFO" "CRAN GPG key ${CRAN_APT_KEYRING_FILE} already exists."
    fi
    
    local simple_grep_pattern_base
    simple_grep_pattern_base=$(echo "${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME}-cran40/" | sed 's|[&/\]|\\&|g')
    local simple_grep_pattern="^deb .*${simple_grep_pattern_base}"

    if grep -qrE "$simple_grep_pattern" /etc/apt/sources.list /etc/apt/sources.list.d/; then
        _log "INFO" "CRAN repository for '${UBUNTU_CODENAME}-cran40' (simple format) seems to be already configured."
    else
        _log "INFO" "CRAN repository line to add via add-apt-repository: ${CRAN_REPO_LINE}"
        _run_command "Add CRAN repository entry" add-apt-repository -y -n "${CRAN_REPO_LINE}"
        _run_command "Update apt cache after adding CRAN repo" apt-get update -y
        _log "INFO" "CRAN repository added and apt cache updated."
    fi
}

fn_install_r() {
    _log "INFO" "Installing R..."
    if [[ -z "${UBUNTU_CODENAME:-}" ]] && [[ -f "$R_ENV_STATE_FILE" ]]; then 
        _log "DEBUG" "fn_install_r: Sourcing state file as UBUNTU_CODENAME is empty."
        # shellcheck source=/dev/null
        source "$R_ENV_STATE_FILE"
    fi

    if dpkg -s r-base &>/dev/null; then
        _log "INFO" "R (r-base) is already installed. Version: $(dpkg-query -W -f='${Version}\n' r-base 2>/dev/null || echo 'N/A')"
    else
        _run_command "Install R (r-base, r-base-dev, r-base-core)" apt-get install -y r-base r-base-dev r-base-core
        _log "INFO" "R installed. Version: $(R --version | head -n 1)"
    fi
    _get_r_profile_site_path 
}

fn_install_openblas_openmp() {
    _log "INFO" "Installing OpenBLAS and OpenMP development libraries..."
    local pkgs_to_install=("libopenblas-dev" "libomp-dev")
    local pkgs_actually_needed=()
    for pkg in "${pkgs_to_install[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            pkgs_actually_needed+=("$pkg")
        else
            _log "INFO" "Package '$pkg' is already installed."
        fi
    done

    if [[ ${#pkgs_actually_needed[@]} -gt 0 ]]; then
        _run_command "Install OpenBLAS/OpenMP packages: ${pkgs_actually_needed[*]}" apt-get install -y "${pkgs_actually_needed[@]}"
        _log "INFO" "OpenBLAS/OpenMP development packages installation attempted."
    else
        _log "INFO" "All required OpenBLAS/OpenMP development packages are already installed."
    fi
}

_display_blas_alternatives() {
    local arch_suffix=""
    if [ -e "/usr/lib/x86_64-linux-gnu/libblas.so.3" ]; then
        arch_suffix="-x86_64-linux-gnu"
    elif [ -e "/usr/lib/aarch64-linux-gnu/libblas.so.3" ]; then
        arch_suffix="-aarch64-linux-gnu"
    fi

    _log "INFO" "Displaying BLAS/LAPACK alternatives (if configured):"
    update-alternatives --display libblas.so.3 >> "$LOG_FILE" 2>&1 || _log "INFO" "No generic libblas.so.3 alternatives configured or error displaying."
    if [[ -n "$arch_suffix" ]]; then
        update-alternatives --display "libblas.so.3${arch_suffix}" >> "$LOG_FILE" 2>&1 || _log "INFO" "No arch-specific libblas.so.3${arch_suffix} alternatives configured or error displaying."
    fi
    update-alternatives --display liblapack.so.3 >> "$LOG_FILE" 2>&1 || _log "INFO" "No generic liblapack.so.3 alternatives configured or error displaying."
    if [[ -n "$arch_suffix" ]]; then
        update-alternatives --display "liblapack.so.3${arch_suffix}" >> "$LOG_FILE" 2>&1 || _log "INFO" "No arch-specific liblapack.so.3${arch_suffix} alternatives configured or error displaying."
    fi
}


fn_verify_openblas_openmp() {
    _log "INFO" "Verifying OpenBLAS and OpenMP integration with R..."
    if ! command -v Rscript &>/dev/null; then
        _log "ERROR" "Rscript command not found. Cannot verify OpenBLAS/OpenMP. Please install R first."
        return 1
    fi

    _log "INFO" "Checking system BLAS/LAPACK alternatives configuration..."
    _display_blas_alternatives 

    if command -v openblas_get_config &>/dev/null; then
        _log "INFO" "Attempting to get OpenBLAS compile-time configuration..."
        ( openblas_get_config >> "$LOG_FILE" 2>&1 ) || _log "WARN" "openblas_get_config command executed with a non-zero exit code. Output (if any) is in the log."
    else
        _log "INFO" "openblas_get_config command not found. Skipping."
    fi

    local r_check_script_file="/tmp/check_r_blas_openmp.R"
cat > "$r_check_script_file" << 'EOF'
# Stricter error handling at the start
options(warn=1) # Print warnings as they occur
error_occurred <- FALSE
current_step <- "Initialization"

# Function to handle and log errors more gracefully
handle_r_error <- function(e, step_name) {
    error_occurred <<- TRUE
    cat(paste0("ERROR during R script step: '", step_name, "'\n"), file = stderr())
    cat("Error message: ", conditionMessage(e), "\n", file = stderr())
    cat("Traceback:\n", file = stderr())
    try(print(sys.calls()), silent=TRUE, file=stderr()) # Print call stack
}

# Global error handler
options(error = quote({
    cat("------------------------------------------------------------\n", file = stderr())
    cat(paste0("Unhandled R Error (likely during step: '", current_step, "'):\n"), file = stderr())
    cat("Message: ", geterrmessage(), "\n", file = stderr())
    cat("------------------------------------------------------------\n", file = stderr())
    cat("Dumping frames to .RData and Rplots.pdf for debugging (if permissions allow).\n", file=stderr())
    dump.frames(to.file = TRUE, include.GlobalEnv = TRUE) 
    q("no", status = 1, runLast = FALSE) 
}))

# Ensure necessary packages are loadable
current_step <- "Loading required namespaces (utils, parallel)"
if (!requireNamespace("utils", quietly = TRUE)) {
    cat("ERROR: 'utils' namespace not found. This is a base R package and should be available.\n", file=stderr())
    q("no", status = 10, runLast = FALSE)
}
if (!requireNamespace("parallel", quietly = TRUE)) {
    cat("ERROR: 'parallel' namespace not found. This is a recommended R package.\n", file=stderr())
    q("no", status = 11, runLast = FALSE)
}


cat("--- R Environment Details ---\n")

current_step <- "Printing R.version"
tryCatch({
    cat("R version and platform:\n"); print(R.version)
}, error = function(e) handle_r_error(e, current_step))
if(error_occurred) q("no", status=1, runLast=FALSE)

current_step <- "Printing sessionInfo()"
tryCatch({
    cat("\nSession Info (BLAS/LAPACK linkage by R):\n"); print(sessionInfo())
}, error = function(e) handle_r_error(e, current_step))
if(error_occurred) q("no", status=1, runLast=FALSE)

current_step <- "Printing utils::extSoftVersion()"
cat("\nExtended Software Version (BLAS/LAPACK versions used by R):\n")
if (!"package:utils" %in% search()) {
    tryCatch(attachNamespace("utils"), warning=function(w) {
        cat("Warning attaching 'utils' namespace: ", conditionMessage(w), "\n", file=stderr())
    })
}
if (exists("extSoftVersion") && is.function(get("extSoftVersion"))) { 
    tryCatch({
        print(extSoftVersion())
    }, error = function(e) handle_r_error(e, current_step))
} else {
    cat("extSoftVersion() not found or not a function in the search path.\n", file=stderr())
    cat("R_SCRIPT_WARN: extSoftVersion() function was not available. This might be okay.\n", file=stderr())
}
if(error_occurred && current_step == "Printing utils::extSoftVersion()") { 
    q("no", status=1, runLast=FALSE)
}


current_step <- "Printing LD_LIBRARY_PATH"
cat("\nChecking R's LD_LIBRARY_PATH:\n"); print(Sys.getenv("LD_LIBRARY_PATH"))

current_step <- "Getting Loaded DLLs/Shared Objects"
cat("\nLoaded DLLs/shared objects for BLAS/LAPACK:\n")
if (exists("getLoadedDLLs", where="package:base") && is.function(getLoadedDLLs)) {
  tryCatch({
    loaded_dlls_obj <- getLoadedDLLs()
    if (is.list(loaded_dlls_obj) && length(loaded_dlls_obj) > 0) {
      dll_names <- vapply(loaded_dlls_obj, function(dll) as.character(dll[["name"]]), FUN.VALUE = character(1))
      dll_paths <- vapply(loaded_dlls_obj, function(dll) as.character(dll[["path"]]), FUN.VALUE = character(1))
      dll_info_df <- data.frame(Name = dll_names, Path = dll_paths, stringsAsFactors = FALSE)
      blas_lapack_pattern <- "blas|lapack|openblas|mkl|atlas|accelerate" 
      blas_lapack_indices <- grepl(blas_lapack_pattern, dll_info_df$Name, ignore.case = TRUE) | grepl(blas_lapack_pattern, dll_info_df$Path, ignore.case = TRUE)
      blas_lapack_dlls_found <- dll_info_df[blas_lapack_indices, , drop = FALSE] 
      if (nrow(blas_lapack_dlls_found) > 0) { cat("Potential BLAS/LAPACK DLLs:\n"); print(blas_lapack_dlls_found) } else { cat("No DLLs matching BLAS/LAPACK patterns found via getLoadedDLLs().\n") }
    } else { cat("getLoadedDLLs() returned empty or non-list.\n") }
  }, error = function(e) handle_r_error(e, current_step))
} else { cat("getLoadedDLLs() not found in base package.\n") }
if(error_occurred) q("no", status=1, runLast=FALSE)

cat("\n--- BLAS Performance Benchmark (crossprod) ---\n")
current_step <- "BLAS Benchmark (crossprod)"
N <- 1000; m <- matrix(rnorm(N*N), ncol=N)
cat("Attempting matrix multiplication (crossprod(m)) for a ", N, "x", N, " matrix...\n")
blas_benchmark_status <- "NOT_RUN"; blas_error_message <- ""
crossprod_result <- tryCatch({
    time_taken <- system.time(crossprod(m)); cat("SUCCESS: crossprod(m) completed.\n"); print(time_taken); blas_benchmark_status <- "SUCCESS"; TRUE 
}, error = function(e) {
    blas_benchmark_status <<- "FAILED"; blas_error_message <<- conditionMessage(e)
    cat("ERROR during crossprod(m):\n", file = stderr()); cat("Msg: ", blas_error_message, "\n", file = stderr())
    if (grepl("illegal operation|illegal operand|illegal instruction", blas_error_message, ignore.case = TRUE)) {
        cat("\n--- IMPORTANT QEMU/VM CPU Incompatibility INFO ---\n", file = stderr())
        cat("Error suggests BLAS library uses CPU instructions (e.g., AVX, AVX2) NOT supported by the current QEMU CPU model or VM configuration.\n", file = stderr())
        cat("Possible Solutions:\n", file = stderr())
        cat("  1. If using QEMU: Try with '-cpu host' or a specific model supporting needed instructions (e.g., '-cpu Haswell-noTSX').\n", file = stderr())
        cat("  2. On any VM/System: Switch to a reference BLAS implementation if performance BLAS causes issues:\n", file = stderr())
        cat("     'sudo update-alternatives --config libblas.so.3' (and liblapack.so.3 if separate)\n", file = stderr())
        cat("     Then choose the non-OpenBLAS/non-optimized version.\n", file = stderr())
        cat("--------------------------------------------------\n\n", file = stderr())
    } else { cat("Unexpected error during BLAS benchmark. Check for BLAS library compatibility or resource limits.\n", file=stderr()) }
    FALSE 
})
if (!crossprod_result) { cat("\nBLAS benchmark FAILED. Status:", blas_benchmark_status, "\n"); q("no", status = 2, runLast = FALSE) } else { cat("\nBLAS benchmark OK.\n") }

cat("\n--- OpenMP Support Check (via parallel package) ---\n")
current_step <- "OpenMP Check (parallel::mclapply)"
omp_test <- function() {
    num_cores <- tryCatch(parallel::detectCores(logical=TRUE), error=function(e){cat("Warning: detectCores() failed:",conditionMessage(e),"\n");1L})
    if(!is.numeric(num_cores) || num_cores < 1L) num_cores <- 1L
    cat("Logical cores detected by R:", num_cores, "\n")
    if (.Platform$OS.type == "unix") {
        test_cores <- min(num_cores, 2L); 
        cat("Attempting parallel::mclapply test with", test_cores, "core(s)...\n")
        res <- tryCatch(parallel::mclapply(1:test_cores, function(x) Sys.getpid(), mc.cores=test_cores), 
                        error=function(e){
                            cat("Error during mclapply:",conditionMessage(e),"\n",file=stderr())
                            error_occurred <<- TRUE 
                            NULL
                        })
        if(error_occurred) return() 

        if(!is.null(res) && length(res) > 0){
             cat("mclapply call successful. Unique PIDs from workers:",length(unique(unlist(res))),"\n")
             if (length(unique(unlist(res))) > 1) {
                cat("Multiple PIDs suggest mclapply is using multiple processes (good sign for OpenMP if R was built with it).\n")
             } else if (test_cores > 1) {
                cat("Single PID returned by mclapply with multiple cores requested. This might indicate a problem with forking or OpenMP setup in R's parallel capabilities.\n")
             }
        } else {
            cat("mclapply failed or returned no results (check for previous errors if mclapply was caught by tryCatch).\n")
        }
    } else {
        cat("mclapply test skipped (not on a Unix-like OS).\n")
    }
    cat("Note: True OpenMP usage in BLAS/LAPACK operations (like matrix multiplication) depends on how those libraries were compiled (e.g., OpenBLAS with USE_OPENMP=1).\n")
    cat("The sessionInfo() output can sometimes indicate OpenMP linkage if R itself was compiled with OpenMP support.\n")
}
tryCatch({
    omp_test()
}, error = function(e) handle_r_error(e, current_step))

if(error_occurred) {
    cat("\nOne or more non-critical errors occurred during the R verification script. Check messages above.\n", file=stderr())
    q("no", status=1, runLast=FALSE) 
}

cat("\n--- Verification Script Finished ---\n")
if (!crossprod_result) { 
    q("no", status = 3, runLast = FALSE) 
}
EOF

    _log "INFO" "Executing R verification script: ${r_check_script_file}"
    local r_script_rc=0
    ( Rscript "$r_check_script_file" >> "$LOG_FILE" 2>&1 ) || r_script_rc=$?

    if [[ $r_script_rc -eq 0 ]]; then
        _log "INFO" "OpenBLAS/OpenMP R verification script completed successfully."
    else
        _log "ERROR" "OpenBLAS/OpenMP R verification script FAILED (Rscript Exit Code: ${r_script_rc})."
        _log "ERROR" "Check the main log file (${LOG_FILE}) for detailed R output and error messages."
        if [[ $r_script_rc -eq 132 || $r_script_rc -eq 2 || $r_script_rc -eq 3 ]]; then 
            _log "ERROR" "Exit code ${r_script_rc} (often indicates 'Illegal Instruction' if 132) can occur in VMs/QEMU due to CPU feature incompatibility with the compiled BLAS library."
            _log "ERROR" "See R script output in the log for recommendations (e.g., QEMU CPU model, or using update-alternatives to switch to a reference BLAS)."
        elif [[ $r_script_rc -eq 10 || $r_script_rc -eq 11 ]]; then
             _log "ERROR" "R verification script failed due to missing base/recommended packages (utils/parallel). This indicates a severely broken R installation."
        fi
        rm -f "$r_check_script_file" Rplots.pdf .RData last.dump.rda
        return 1 
    fi

    rm -f "$r_check_script_file" Rplots.pdf .RData last.dump.rda
    _log "INFO" "OpenBLAS and OpenMP verification step finished."
    return 0
}

fn_setup_bspm() {
    _log "INFO" "Setting up bspm (Binary R Package Manager from R2U)..."
    _get_r_profile_site_path 

    if [[ ! -f "$R_PROFILE_SITE_PATH" ]]; then 
        _log "WARN" "Rprofile.site '${R_PROFILE_SITE_PATH}' does not exist. Attempting to create."
        mkdir -p "$(dirname "$R_PROFILE_SITE_PATH")" 
        if ! touch "$R_PROFILE_SITE_PATH"; then
            _log "ERROR" "Failed to create Rprofile.site at '${R_PROFILE_SITE_PATH}'. Cannot proceed with bspm config."
            return 1
        fi
    fi
    _backup_file "$R_PROFILE_SITE_PATH" 


    if ! _is_vm_or_ci_env; then
        _log "INFO" "Not detected as root or a CI/VM environment. Skipping bspm setup for safety (bspm modifies system Rprofile)."
        return 0
    fi

    if [[ -z "${UBUNTU_CODENAME:-}" ]] && [[ -f "$R_ENV_STATE_FILE" ]]; then
        _log "DEBUG" "fn_setup_bspm: Sourcing state file."
        # shellcheck source=/dev/null
        source "$R_ENV_STATE_FILE"
    fi
    if [[ -z "$UBUNTU_CODENAME" ]]; then 
       _log "ERROR" "FATAL: UBUNTU_CODENAME is empty in fn_setup_bspm. Run 'fn_pre_flight_checks' first. Aborting."
       return 1
    fi


    local r_profile_dir
    r_profile_dir=$(dirname "$R_PROFILE_SITE_PATH")
    if [[ ! -d "$r_profile_dir" ]]; then
        _run_command "Create directory for Rprofile.site: ${r_profile_dir}" mkdir -p "$r_profile_dir"
    fi


    if ! command -v sudo &>/dev/null; then
        _log "WARN" "'sudo' command is not installed. bspm may require it. Attempting to install sudo..."
        if [[ $EUID -ne 0 ]]; then 
            _log "ERROR" "'sudo' is not installed and script is not running as root. Cannot install sudo."
            return 1
        fi
        _run_command "Install sudo package" apt-get install -y sudo
        if ! command -v sudo &>/dev/null; then
            _log "ERROR" "Failed to install 'sudo'. bspm setup might fail or be incomplete."
            return 1
        fi
        _log "INFO" "'sudo' package successfully installed."
    else
        _log "INFO" "'sudo' command is already available."
    fi

    _log "INFO" "Configuring R2U repository (provides bspm and binary R packages)..."
    if [[ -f "$R2U_APT_SOURCES_LIST_D_FILE" ]] && grep -q "r2u.stat.illinois.edu/ubuntu" "$R2U_APT_SOURCES_LIST_D_FILE"; then
        _log "INFO" "R2U repository file '${R2U_APT_SOURCES_LIST_D_FILE}' seems to be already configured."
    else
        local r2u_setup_script_url="${R2U_REPO_URL_BASE}/add_cranapt_jammy.sh" 
        if [[ "$UBUNTU_CODENAME" == "noble" ]]; then
             r2u_setup_script_url="${R2U_REPO_URL_BASE}/add_cranapt_noble.sh" 
        elif [[ "$UBUNTU_CODENAME" == "focal" ]]; then
             r2u_setup_script_url="${R2U_REPO_URL_BASE}/add_cranapt_focal.sh"
        fi
        _log "INFO" "Downloading R2U setup script from: ${r2u_setup_script_url}"
        _run_command "Download R2U setup script" curl -fsSL "${r2u_setup_script_url}" -o "/tmp/add_r2u_repo.sh"
        
        _log "INFO" "Executing R2U repository setup script (/tmp/add_r2u_repo.sh)..."
        if ! bash "/tmp/add_r2u_repo.sh" >> "$LOG_FILE" 2>&1; then
            _log "ERROR" "Failed to execute R2U repository setup script. Check log for details."
            rm -f "/tmp/add_r2u_repo.sh"
            return 1
        fi
        _log "INFO" "R2U repository setup script executed. Apt cache likely updated by the script."
        rm -f "/tmp/add_r2u_repo.sh"
    fi

    if _safe_systemctl list-units --type=service --all | grep -q 'dbus.service'; then
        _log "INFO" "dbus.service found. Ensuring it is active/restarted."
        _run_command "Restart dbus service via systemctl" _safe_systemctl restart dbus.service
    elif command -v service &>/dev/null && service --status-all 2>&1 | grep -q 'dbus'; then
        _log "INFO" "dbus found via 'service'. Attempting restart."
        _run_command "Restart dbus service via service" service dbus restart
    else
        _log "WARN" "dbus service manager not detected or dbus not listed. If R package system dependency installation fails, ensure dbus is running."
    fi

    _log "INFO" "Installing bspm R package and its system dependencies (python3-dbus, python3-gi, python3-apt) via apt from R2U..."
    local bspm_system_pkgs=("r-cran-bspm" "python3-dbus" "python3-gi" "python3-apt")
    _run_command "Install r-cran-bspm and Python deps" apt-get install -y "${bspm_system_pkgs[@]}"

    _log "INFO" "Configuring bspm options in Rprofile.site: ${R_PROFILE_SITE_PATH}"
    local bspm_rprofile_config
    read -r -d '' bspm_rprofile_config << EOF
# Added by setup_r_env.sh for bspm configuration
if (nzchar(Sys.getenv("RSTUDIO_USER_IDENTITY"))) {
    # Consider if bspm should be disabled by default in RStudio Server sessions
    # options(bspm.enabled = FALSE) 
} else if (interactive()) {
    # For interactive non-RStudio, decide if auto-enable is desired
} else {
    # Enable bspm for non-interactive sessions (like this script's R calls)
    if (requireNamespace("bspm", quietly = TRUE)) {
        options(bspm.sudo = TRUE)
        options(bspm.allow.sysreqs = TRUE)
        bspm::enable()
    }
}
# End of bspm configuration
EOF

    local temp_rprofile
    temp_rprofile=$(mktemp)
    if [[ -z "$temp_rprofile" || ! -e "$temp_rprofile" ]]; then 
        _log "ERROR" "Failed to create temporary file for Rprofile.site update. mktemp output: '${temp_rprofile}'"
        return 1
    fi
    _log "DEBUG" "Temporary file for Rprofile.site update: ${temp_rprofile}"

    if [[ ! -f "$R_PROFILE_SITE_PATH" ]]; then
        _log "ERROR" "Rprofile.site '${R_PROFILE_SITE_PATH}' is not a regular file or does not exist before sed. Cannot update."
        rm -f "$temp_rprofile"
        return 1
    fi
    if [[ ! -w "$R_PROFILE_SITE_PATH" ]]; then 
        _log "ERROR" "Rprofile.site '${R_PROFILE_SITE_PATH}' is not writable. Cannot update."
        rm -f "$temp_rprofile"
        return 1
    fi

    _log "DEBUG" "Attempting sed command: sed '/# Added by setup_r_env.sh for bspm configuration/,/# End of bspm configuration/d' '${R_PROFILE_SITE_PATH}' > '${temp_rprofile}'"
    if sed '/# Added by setup_r_env.sh for bspm configuration/,/# End of bspm configuration/d' "$R_PROFILE_SITE_PATH" > "$temp_rprofile"; then
        _log "DEBUG" "sed command successfully wrote to ${temp_rprofile}"
    else
        local sed_rc=$?
        _log "ERROR" "sed command failed (RC: $sed_rc) to process ${R_PROFILE_SITE_PATH} into ${temp_rprofile}"
        rm -f "$temp_rprofile"
        return 1
    fi
    
    _log "DEBUG" "Attempting printf command to append to ${temp_rprofile}"
    if printf "\n%s\n" "$bspm_rprofile_config" >> "$temp_rprofile"; then
        _log "DEBUG" "printf successfully appended bspm config to ${temp_rprofile}"
    else
        local printf_rc=$?
        _log "ERROR" "printf command failed (RC: $printf_rc) to append bspm config to ${temp_rprofile}"
        rm -f "$temp_rprofile"
        return 1
    fi
    
    _log "DEBUG" "Contents of temporary Rprofile (${temp_rprofile}) before mv:"
    head -c 1024 "$temp_rprofile" >> "$LOG_FILE" 
    echo "..." >> "$LOG_FILE" 

    _log "INFO" "Attempting to directly move ${temp_rprofile} to ${R_PROFILE_SITE_PATH}"
    if mv -f "$temp_rprofile" "$R_PROFILE_SITE_PATH" >> "$LOG_FILE" 2>&1; then
        _log "INFO" "Successfully updated Rprofile.site with bspm configuration using direct mv."
    else
        local mv_rc=$?
        _log "ERROR" "Direct mv command FAILED (RC: ${mv_rc}) to update Rprofile.site from ${temp_rprofile} to ${R_PROFILE_SITE_PATH}."
        _log "ERROR" "Rprofile.site may not be updated or may be in an inconsistent state. Check permissions and paths. Last few lines of log might show mv error."
        tail -n 5 "$LOG_FILE" 
        rm -f "$temp_rprofile" 
        return 1 
    fi

    _log "INFO" "Content of Rprofile.site (${R_PROFILE_SITE_PATH}) after bspm configuration attempt:"
    cat "$R_PROFILE_SITE_PATH" >> "$LOG_FILE" 

    _log "INFO" "Verifying bspm activation status..."
    local bspm_check_script="
    if (!requireNamespace('bspm', quietly=TRUE)) {
      cat('BSPM_NOT_INSTALLED\n'); quit(save='no', status=1)
    }
    options(bspm.sudo = TRUE, bspm.allow.sysreqs = TRUE)
    if (requireNamespace('bspm', quietly=TRUE)) bspm::enable()

    is_managing <- tryCatch(getOption('bspm.MANAGES', FALSE), error = function(e) FALSE)
    if (is_managing) {
      cat('BSPM_MANAGING\n')
      quit(save='no', status=0)
    } else {
      cat('BSPM_NOT_MANAGING\n')
      cat('bspm::can_load():\n')
      try(print(bspm::can_load()))
      cat('bspm:::.backend:\n') 
      try(print(bspm:::.backend))
      quit(save='no', status=2)
    }
    "
    local bspm_status_output
    local bspm_status_rc=0
    bspm_status_output=$(Rscript -e "$bspm_check_script" 2>>"$LOG_FILE") || bspm_status_rc=$?

    if [[ $bspm_status_rc -eq 0 && "$bspm_status_output" == *BSPM_MANAGING* ]]; then
        _log "INFO" "bspm is installed and appears to be managing packages."
    elif [[ "$bspm_status_output" == *BSPM_NOT_INSTALLED* ]]; then
        _log "ERROR" "bspm R package is NOT installed properly, though apt reported success."
        return 2
    elif [[ "$bspm_status_output" == *BSPM_NOT_MANAGING* ]]; then
        _log "ERROR" "bspm is installed but reports IT IS NOT MANAGING packages."
        _log "ERROR" "bspm verification output: $bspm_status_output"
        _log "ERROR" "This could be due to issues with dbus, python dependencies, or Rprofile.site settings. Check logs."
        return 3
    else
        _log "ERROR" "Unknown bspm status or Rscript error during verification."
        _log "ERROR" "Rscript exit code: $bspm_status_rc. Output: $bspm_status_output"
        return 4
    fi

    _log "INFO" "bspm setup and basic verification completed."
    export BSPM_ALLOW_SYSREQS=TRUE 
}

fn_install_r_build_deps() {
    _log "INFO" "Installing common system dependencies for building R packages from source (e.g., for devtools)..."
    local build_deps=(
        build-essential libcurl4-openssl-dev libssl-dev libxml2-dev libgit2-dev 
        libfontconfig1-dev libcairo2-dev libharfbuzz-dev libfribidi-dev libfreetype6-dev 
        libpng-dev libtiff5-dev libjpeg-dev zlib1g-dev libbz2-dev liblzma-dev 
        libreadline-dev libicu-dev libxt-dev cargo libgdal-dev libproj-dev 
        libgeos-dev libudunits2-dev
    )
    _run_command "Update apt cache before installing build deps" apt-get update -y
    _run_command "Install R package build dependencies" apt-get install -y "${build_deps[@]}"
    _log "INFO" "System dependencies for R package building installed."
}

_install_r_pkg_list() {
    local pkg_type="$1"; shift
    local r_packages_list=("$@")

    if [[ ${#r_packages_list[@]} -eq 0 ]]; then
        _log "INFO" "No ${pkg_type} R packages specified in the list to install."
        return
    fi

    _log "INFO" "Processing ${pkg_type} R packages for installation: ${r_packages_list[*]}"

    local pkg_install_script_path="/tmp/install_r_pkg_script.R"
    local github_pat_warning_shown=false

    for pkg_name_full in "${r_packages_list[@]}"; do
        local pkg_name_short 
        local r_install_cmd

        if [[ "$pkg_type" == "CRAN" ]]; then
            pkg_name_short="$pkg_name_full" 
            r_install_cmd="
            pkg_short_name <- '${pkg_name_short}'
            n_cpus <- max(1, parallel::detectCores(logical=FALSE) %/% 2)

            if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                message(paste0('R package ', pkg_short_name, ' not found, attempting installation...'))
                installed_successfully <- FALSE
                if (requireNamespace('bspm', quietly = TRUE) && isTRUE(getOption('bspm.MANAGES', FALSE))) {
                    message(paste0('Attempting to install ', pkg_short_name, ' via bspm (binary)...'))
                    tryCatch({
                        bspm::install.packages(pkg_short_name, quiet = FALSE, Ncpus = n_cpus)
                        if (requireNamespace(pkg_short_name, quietly = TRUE)) {
                            installed_successfully <- TRUE
                            message(paste0('Successfully installed ', pkg_short_name, ' via bspm.'))
                        } else {
                            message(paste0('bspm::install.packages completed but ', pkg_short_name, ' still not loadable. Will try source install.'))
                        }
                    }, error = function(e) {
                        message(paste0('bspm installation failed for ', pkg_short_name, ': ', conditionMessage(e)))
                        message(paste0('Falling back to source installation for ', pkg_short_name, '...'))
                    })
                } else {
                    message(paste0('bspm not managing or not available. Attempting source installation for ', pkg_short_name, ' from CRAN.'))
                }

                if (!installed_successfully) {
                    install.packages(pkg_short_name, repos = '${CRAN_REPO_URL_SRC}', Ncpus = n_cpus)
                }

                if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                    stop(paste0('Failed to install R package: ', pkg_short_name, ' after all attempts.'))
                } else {
                    message(paste0('Successfully installed/verified R package: ', pkg_short_name))
                }
            } else {
                message(paste0('R package ', pkg_short_name, ' is already installed. Version: ', packageVersion(pkg_short_name)))
            }
            "
        elif [[ "$pkg_type" == "GitHub" ]]; then
            pkg_name_short=$(basename "${pkg_name_full%.git}") 
            
            if [[ -z "${GITHUB_PAT:-}" ]] && [[ "$github_pat_warning_shown" == "false" ]]; then
                _log "WARN" "GITHUB_PAT environment variable is not set. GitHub API rate limits may be encountered for installing packages like '${pkg_name_full}'. See script comments for GITHUB_PAT setup."
                github_pat_warning_shown=true 
            fi

            r_install_cmd="
            pkg_short_name <- '${pkg_name_short}'
            pkg_full_name <- '${pkg_name_full}'
            n_cpus <- max(1, parallel::detectCores(logical=FALSE) %/% 2)

            if (!requireNamespace('remotes', quietly = TRUE)) {
                message('remotes package not found, installing it first...')
                install.packages('remotes', repos = '${CRAN_REPO_URL_SRC}', Ncpus = n_cpus)
                if (!requireNamespace('remotes', quietly = TRUE)) stop('Failed to install remotes package.')
            }
            if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                message(paste0('R package ', pkg_short_name, ' (from GitHub: ', pkg_full_name, ') not found, attempting installation...'))
                remotes::install_github(pkg_full_name, Ncpus = n_cpus, force = TRUE, dependencies = TRUE)
                if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                    stop(paste0('Failed to install R package ', pkg_short_name, ' from GitHub: ', pkg_full_name))
                } else {
                    message(paste0('Successfully installed/verified R package: ', pkg_short_name, ' from GitHub: ', pkg_full_name))
                }
            } else {
                message(paste0('R package ', pkg_short_name, ' (from GitHub: ', pkg_full_name, ') is already installed. Version: ', packageVersion(pkg_short_name)))
            }
            "
        else
            _log "WARN" "Unknown package type '${pkg_type}' for package '${pkg_name_full}'. Skipping."
            continue 
        fi

        echo "$r_install_cmd" > "$pkg_install_script_path"
        if ! _run_command "Install/Verify R pkg ($pkg_type): $pkg_name_full" Rscript "$pkg_install_script_path"; then
            _log "ERROR" "Failed to install R package '${pkg_name_full}'. See R output in the log above."
        fi
    done
    rm -f "$pkg_install_script_path" 
    _log "INFO" "${pkg_type} R packages installation process completed."
}


fn_install_r_packages() {
    _log "INFO" "Starting R package installation process..."
    fn_install_r_build_deps 

    _log "INFO" "Ensuring 'devtools' and 'remotes' R packages are installed..."
    local core_r_dev_pkgs=("devtools" "remotes")
    
    local r_pkgs_to_ensure_str="c("
    local first_pkg=true
    for pkg_name in "${core_r_dev_pkgs[@]}"; do
        if [[ "$first_pkg" == "true" ]]; then
            r_pkgs_to_ensure_str+="\"${pkg_name}\""
            first_pkg=false
        else
            r_pkgs_to_ensure_str+=", \"${pkg_name}\""
        fi
    done
    r_pkgs_to_ensure_str+=")"
    
    set +o pipefail
    Rscript_out_err=$(mktemp)
    Rscript -e "
        n_cpus <- max(1, parallel::detectCores(logical=FALSE) %/% 2)
        pkgs_to_ensure <- ${r_pkgs_to_ensure_str}; 
        if (requireNamespace('bspm', quietly = TRUE)) {
          options(bspm.sudo = TRUE, bspm.allow.sysreqs = TRUE)
          bspm::enable()
        }
        
        for (pkg in pkgs_to_ensure) {
            if (!requireNamespace(pkg, quietly = TRUE)) {
                message(paste('Installing core dev R package:', pkg))
                installed_ok <- FALSE
                if (requireNamespace('bspm', quietly = TRUE) && isTRUE(getOption('bspm.MANAGES', FALSE))) {
                    message(paste('Attempting', pkg, 'via bspm...'))
                    tryCatch({
                        bspm::install.packages(pkg, quiet = FALSE, Ncpus = n_cpus)
                        if(requireNamespace(pkg, quietly=TRUE)) installed_ok <- TRUE
                    }, error = function(e) {
                        message(paste('bspm failed for', pkg, ':', conditionMessage(e), '. Fallback to source.'))
                    })
                }
                if (!installed_ok) {
                    message(paste('Attempting', pkg, 'via install.packages (source)...'))
                    install.packages(pkg, repos = '${CRAN_REPO_URL_SRC}', Ncpus = n_cpus)
                }
                if (!requireNamespace(pkg, quietly = TRUE)) {
                    stop(paste('Failed to install essential R package:', pkg))
                }
                message(paste(pkg, 'is now installed.'))
            } else {
                message(paste(pkg, 'is already installed.'))
            }
        }
    " > "$Rscript_out_err" 2>&1
    local r_script_rc=$?
    cat "$Rscript_out_err" >> "$LOG_FILE"
    rm -f "$Rscript_out_err"
    set -o pipefail

    if [[ $r_script_rc -ne 0 ]]; then
        _log "ERROR" "Failed to install one or more core R development packages (devtools/remotes). RC: $r_script_rc. Check log."
    else
        _log "INFO" "Core R development packages (devtools/remotes) are installed/verified."
    fi

    _install_r_pkg_list "CRAN" "${R_PACKAGES_CRAN[@]}"

    if [[ ${#R_PACKAGES_GITHUB[@]} -gt 0 ]]; then
        _log "INFO" "Installing GitHub R packages using remotes/devtools..."
        [[ -n "${GITHUB_PAT:-}" ]] && export GITHUB_PAT
        _install_r_pkg_list "GitHub" "${R_PACKAGES_GITHUB[@]}"
    else
        _log "INFO" "No GitHub R packages listed for installation."
    fi

    _log "INFO" "Listing installed R packages and their installation type (bspm/binary or source)..."
    local r_list_pkgs_cmd_file="/tmp/list_installed_pkgs.R"
cat > "$r_list_pkgs_cmd_file" <<'EOF'
get_install_type <- function(pkg_name, installed_pkgs_df) {
    install_type <- "source/unknown"
    if (!is.na(installed_pkgs_df[pkg_name, "Priority"]) &&
        installed_pkgs_df[pkg_name, "Priority"] %in% c("base", "recommended")) {
        return("base/recommended")
    }
    if (requireNamespace("bspm", quietly = TRUE) && isTRUE(getOption("bspm.MANAGES", FALSE))) {
        bspm_pkg_info <- tryCatch(
            suppressMessages(bspm::info(pkg_name)),
            error = function(e) NULL
        )
        if (!is.null(bspm_pkg_info) && isTRUE(bspm_pkg_info$binary)) {
            install_type <- "bspm/binary"
        } else if (!is.null(bspm_pkg_info) && !is.null(bspm_pkg_info$source_available) && nzchar(bspm_pkg_info$source_available)) {
            install_type <- "bspm/source_or_other"
        }
        if (install_type != "source/unknown" && install_type != "bspm/source_or_other") return(install_type)
    }
    built_info <- installed_pkgs_df[pkg_name, "Built"]
    if (!is.na(built_info)) {
        if (grepl("; source$", built_info, ignore.case = TRUE)) {
            install_type <- "source"
        } else if (grepl("; unix$", built_info, ignore.case = TRUE) || grepl("; windows$", built_info, ignore.case = TRUE)) {
             if (install_type == "bspm/source_or_other") {
                install_type <- "binary/pre-compiled"
             } else if (install_type == "source/unknown") {
                install_type <- "binary/pre-compiled"
             }
        }
    }
    return(install_type)
}
if (requireNamespace("bspm", quietly = TRUE)) {
  options(bspm.sudo = TRUE, bspm.allow.sysreqs = TRUE) 
}
ip_fields <- c("Package", "Version", "LibPath", "Priority", "Built")
installed_pkgs_df <- as.data.frame(installed.packages(fields = ip_fields, noCache=TRUE), stringsAsFactors = FALSE) 
if (nrow(installed_pkgs_df) == 0) {
    cat("No R packages appear to be installed.\n")
} else {
    installed_pkgs_df$InstallType <- "pending"
    rownames(installed_pkgs_df) <- installed_pkgs_df$Package 
    for (i in seq_len(nrow(installed_pkgs_df))) {
        pkg_name <- installed_pkgs_df[i, "Package"]
        installed_pkgs_df[i, "InstallType"] <- tryCatch(
            get_install_type(pkg_name, installed_pkgs_df),
            error = function(e) "error_determining"
        )
    }
    cat(sprintf("%-30s %-16s %-20s %s\n", "Package", "Version", "InstallType", "LibPath"))
    cat(paste(rep("-", 90), collapse=""), "\n") 
    for (i in seq_len(nrow(installed_pkgs_df))) {
        cat(sprintf("%-30s %-16s %-20s %s\n",
                    installed_pkgs_df[i, "Package"],
                    installed_pkgs_df[i, "Version"],
                    installed_pkgs_df[i, "InstallType"],
                    installed_pkgs_df[i, "LibPath"]))
    }
}
EOF
    if ! _run_command "List installed R packages with types" Rscript "$r_list_pkgs_cmd_file"; then
        _log "WARN" "R script for listing packages encountered an error. List may be incomplete or missing."
    fi
    rm -f "$r_list_pkgs_cmd_file"
    _log "INFO" "R package installation and listing process finished."
}


fn_install_rstudio_server() {
    _log "INFO" "Installing RStudio Server v${RSTUDIO_VERSION}..."
    if [[ -z "${UBUNTU_CODENAME:-}" || -z "${RSTUDIO_ARCH:-}" || -z "${RSTUDIO_VERSION:-}" ]] && [[ -f "$R_ENV_STATE_FILE" ]]; then
        _log "DEBUG" "fn_install_rstudio_server: Sourcing state file."
        # shellcheck source=/dev/null
        source "$R_ENV_STATE_FILE"
    fi
    
    if [[ -z "$UBUNTU_CODENAME" || -z "$RSTUDIO_ARCH" || -z "$RSTUDIO_VERSION" ]]; then
        _log "INFO" "Key RStudio variables still missing. Re-running fn_get_latest_rstudio_info to define URLs."
        fn_get_latest_rstudio_info 
    fi
    if [[ -z "$RSTUDIO_DEB_URL" || -z "$RSTUDIO_DEB_FILENAME" ]]; then
        _log "ERROR" "FATAL: RStudio download details (URL/filename) could not be determined even after attempting to re-run info gathering. Aborting RStudio Server install."
        return 1
    fi


    if dpkg -s rstudio-server &>/dev/null; then
        current_rstudio_version=$(rstudio-server version 2>/dev/null | awk '{print $1}')
        if [[ "$current_rstudio_version" == "$RSTUDIO_VERSION" ]]; then
            _log "INFO" "RStudio Server v${RSTUDIO_VERSION} is already installed."
            if ! _safe_systemctl is-active --quiet rstudio-server; then
                _log "INFO" "RStudio Server is installed but not active. Attempting to start..."
                _run_command "Start RStudio Server" _safe_systemctl start rstudio-server
            fi
            return 0 
        else
            _log "INFO" "A different version of RStudio Server ('${current_rstudio_version:-unknown}') is installed. It will be removed to install v${RSTUDIO_VERSION}."
            _run_command "Stop existing RStudio Server" _safe_systemctl stop rstudio-server 
            _run_command "Purge existing RStudio Server" apt-get purge -y rstudio-server
        fi
    fi

    local rstudio_deb_tmp_path="/tmp/${RSTUDIO_DEB_FILENAME}"
    if [[ ! -f "$rstudio_deb_tmp_path" ]]; then
        _log "INFO" "Downloading RStudio Server .deb from ${RSTUDIO_DEB_URL} to ${rstudio_deb_tmp_path}"
        _run_command "Download RStudio Server .deb" wget -O "$rstudio_deb_tmp_path" "$RSTUDIO_DEB_URL"
    else
        _log "INFO" "RStudio Server .deb already found at ${rstudio_deb_tmp_path}. Using existing file."
    fi

    _log "INFO" "Installing RStudio Server from ${rstudio_deb_tmp_path} using gdebi..."
    if ! _run_command "Install RStudio Server via gdebi" gdebi -n "$rstudio_deb_tmp_path"; then
        _log "ERROR" "Failed to install RStudio Server using gdebi. Check log for details."
        return 1
    fi

    _log "INFO" "Verifying RStudio Server installation and status..."
    if _safe_systemctl is-active --quiet rstudio-server; then
        _log "INFO" "RStudio Server is active after installation."
    else
        _log "WARN" "RStudio Server is not active immediately after installation. Attempting to start it..."
        if ! _run_command "Start RStudio Server (post-install)" _safe_systemctl start rstudio-server; then
            _log "ERROR" "Failed to start RStudio Server after installation. Service may be misconfigured or conflicting."
            return 1
        fi
        if ! _safe_systemctl is-active --quiet rstudio-server; then
            _log "ERROR" "RStudio Server failed to become active even after an explicit start command."
            return 1
        fi
        _log "INFO" "RStudio Server successfully started."
    fi

    _run_command "Enable RStudio Server to start on boot" _safe_systemctl enable rstudio-server
    local final_rstudio_version
    final_rstudio_version=$(rstudio-server version 2>/dev/null || echo "N/A (could not query version)")
    _log "INFO" "RStudio Server installed. Version: ${final_rstudio_version}"
    _log "INFO" "RStudio Server should be accessible at http://<SERVER_IP>:8787 (if not firewalled)."
}


# --- Uninstall Functions ---
fn_uninstall_r_packages() {
    _log "INFO" "Attempting to uninstall R packages specified by this script..."
    if ! command -v Rscript &>/dev/null; then
        _log "INFO" "Rscript command not found. Skipping R package removal."
        return
    fi

    local all_pkgs_to_remove_short_names=("${R_PACKAGES_CRAN[@]}") 
    for gh_pkg_full_name in "${R_PACKAGES_GITHUB[@]}"; do
        all_pkgs_to_remove_short_names+=("$(basename "${gh_pkg_full_name%.git}")")
    done

    local unique_pkgs_to_remove_list=()
    mapfile -t unique_pkgs_to_remove_list < <(printf "%s\n" "${all_pkgs_to_remove_short_names[@]}" | sort -u)

    if [[ ${#unique_pkgs_to_remove_list[@]} -eq 0 ]]; then
        _log "INFO" "No R packages found in script lists to attempt removal after unique sort."
        return
    fi

    _log "INFO" "Will attempt to remove these R packages: ${unique_pkgs_to_remove_list[*]}"
    
    local r_vector_pkgs_str
    local r_vector_build="c("
    if [[ ${#unique_pkgs_to_remove_list[@]} -gt 0 ]]; then
        local first_pkg_in_vector=true 
        for pkg_name in "${unique_pkgs_to_remove_list[@]}"; do
            if [[ -z "$pkg_name" ]]; then continue; fi 
            if [[ "$first_pkg_in_vector" == "true" ]]; then
                r_vector_build+="\"${pkg_name}\""
                first_pkg_in_vector=false
            else
                r_vector_build+=", \"${pkg_name}\""
            fi
        done
    fi
    r_vector_build+=")"
    r_vector_pkgs_str="$r_vector_build"

    if [[ "$r_vector_pkgs_str" == "c()" ]]; then
        _log "INFO" "Package list for R removal script is empty after processing. Skipping."
        return
    fi

    local r_pkg_removal_script_file="/tmp/uninstall_r_pkgs.R"
cat > "$r_pkg_removal_script_file" <<EOF
pkgs_to_attempt_removal <- ${r_vector_pkgs_str}
installed_pkgs_matrix <- installed.packages(noCache=TRUE) 

if (is.null(installed_pkgs_matrix) || nrow(installed_pkgs_matrix) == 0) {
    cat("No R packages are currently installed according to installed.packages().\n")
} else {
    current_installed_pkgs_vec <- installed_pkgs_matrix[, "Package"]
    pkgs_that_exist_and_targeted_for_removal <- intersect(pkgs_to_attempt_removal, current_installed_pkgs_vec)
    
    if (length(pkgs_that_exist_and_targeted_for_removal) > 0) {
        cat("The following R packages will be targeted for removal:\n", paste(pkgs_that_exist_and_targeted_for_removal, collapse = ", "), "\n")
        suppressWarnings(remove.packages(pkgs_that_exist_and_targeted_for_removal))
        cat("Attempted removal of specified R packages finished.\n")
        
        still_installed_pkgs_matrix <- installed.packages(noCache=TRUE)
        still_installed_pkgs_vec <- if(nrow(still_installed_pkgs_matrix)>0) still_installed_pkgs_matrix[,"Package"] else character(0)
        
        actually_removed <- setdiff(pkgs_that_exist_and_targeted_for_removal, still_installed_pkgs_vec)
        failed_to_remove <- intersect(pkgs_that_exist_and_targeted_for_removal, still_installed_pkgs_vec)

        if(length(actually_removed)>0) cat("Successfully removed: ", paste(actually_removed, collapse=", "), "\n")
        if(length(failed_to_remove)>0) cat("Failed to remove (or still present): ", paste(failed_to_remove, collapse=", "), "\n Check for dependencies or permission issues.\n")

    } else {
        cat("None of the R packages specified for removal (", paste(pkgs_to_attempt_removal, collapse=", "), ") were found among currently installed packages.\n")
    }
}
EOF
    _log "INFO" "R script for package removal prepared at ${r_pkg_removal_script_file}"
    
    local r_removal_rc=0
    ( Rscript "$r_pkg_removal_script_file" >>"$LOG_FILE" 2>&1 ) || r_removal_rc=$?
    rm -f "$r_pkg_removal_script_file" 

    if [[ $r_removal_rc -eq 0 ]]; then
        _log "INFO" "R package uninstallation script completed successfully."
    else
        _log "WARN" "R package uninstallation script finished with errors (Rscript Exit Code: $r_removal_rc). Check log for details."
    fi
    _log "INFO" "R package uninstallation attempt finished."
}


fn_remove_bspm_config() {
    _log "INFO" "Removing bspm configuration from Rprofile.site and R2U apt repository..."
    _get_r_profile_site_path 

    if [[ -n "$R_PROFILE_SITE_PATH" && (-f "$R_PROFILE_SITE_PATH" || -L "$R_PROFILE_SITE_PATH") ]]; then
        _log "INFO" "Removing bspm configuration lines from '${R_PROFILE_SITE_PATH}'."
        _backup_file "$R_PROFILE_SITE_PATH" 

        local temp_rprofile_cleaned
        temp_rprofile_cleaned=$(mktemp)

        sed '/# Added by setup_r_env.sh for bspm configuration/,/# End of bspm configuration/d' "$R_PROFILE_SITE_PATH" > "$temp_rprofile_cleaned"
        
        if ! cmp -s "$R_PROFILE_SITE_PATH" "$temp_rprofile_cleaned"; then
            if _run_command "Update Rprofile.site (remove bspm block)" mv "$temp_rprofile_cleaned" "$R_PROFILE_SITE_PATH"; then
                 _log "INFO" "Removed bspm configuration block from '${R_PROFILE_SITE_PATH}'."
            else
                _log "ERROR" "Failed to update Rprofile.site after attempting to remove bspm block. Restoring backup."
                _restore_latest_backup "$R_PROFILE_SITE_PATH"
                rm -f "$temp_rprofile_cleaned"
            fi
        else
            _log "INFO" "No bspm configuration block (matching markers) found in '${R_PROFILE_SITE_PATH}', or file was unchanged. Cleaning up temporary file."
            rm -f "$temp_rprofile_cleaned"
        fi
    else
        _log "INFO" "Rprofile.site ('${R_PROFILE_SITE_PATH:-not set or found}') not found or path not determined. Skipping bspm configuration removal from it."
    fi

    _log "INFO" "Removing R2U apt repository configuration..."
    local r2u_apt_pattern="r2u.stat.illinois.edu" 

    if [[ -f "$R2U_APT_SOURCES_LIST_D_FILE" ]]; then
        _log "INFO" "Removing R2U repository file: '${R2U_APT_SOURCES_LIST_D_FILE}'."
        _run_command "Remove R2U sources file '${R2U_APT_SOURCES_LIST_D_FILE}'" rm -f "$R2U_APT_SOURCES_LIST_D_FILE"
    fi

    find /etc/apt/sources.list /etc/apt/sources.list.d/ -type f -name '*.list' -print0 | \
    while IFS= read -r -d $'\0' apt_list_file; do
        if grep -q "$r2u_apt_pattern" "$apt_list_file"; then
            _log "INFO" "R2U entry found in '${apt_list_file}'. Backing up and removing entry."
            _backup_file "$apt_list_file" 
            _run_command "Remove R2U entry from '${apt_list_file}'" sed -i.r2u_removed_bak "/${r2u_apt_pattern}/d" "$apt_list_file"
        fi
    done
    local r2u_keyring_pattern="r2u-cran-archive-keyring.gpg" 
    find /etc/apt/keyrings/ -name "$r2u_keyring_pattern" -type f -print0 | while IFS= read -r -d $'\0' key_file; do
        _log "INFO" "Removing R2U GPG keyring file: '$key_file'"
        _run_command "Remove R2U GPG keyring '$key_file'" rm -f "$key_file"
    done

    _log "INFO" "R2U apt repository configuration removal process finished."
    _log "INFO" "Consider running 'apt-get update' after these changes."
}


fn_remove_cran_repo() {
    _log "INFO" "Removing this script's CRAN apt repository configuration..."
    if [[ -z "${UBUNTU_CODENAME:-}" || -z "${CRAN_REPO_LINE:-}" || -z "${CRAN_APT_KEYRING_FILE:-}" ]] && [[ -f "$R_ENV_STATE_FILE" ]]; then
        _log "DEBUG" "fn_remove_cran_repo: Sourcing state file."
        # shellcheck source=/dev/null
        source "$R_ENV_STATE_FILE"
    fi
    if [[ -z "$UBUNTU_CODENAME" || -z "$CRAN_REPO_LINE" || -z "$CRAN_APT_KEYRING_FILE" ]]; then
       _log "ERROR" "FATAL: UBUNTU_CODENAME, CRAN_REPO_LINE or CRAN_APT_KEYRING_FILE is empty in fn_remove_cran_repo. Aborting."
       return 1
    fi
    
    local cran_line_pattern_to_remove_escaped
    cran_line_pattern_to_remove_escaped=$(printf '%s' "$CRAN_REPO_LINE" | sed 's|[&/\]|\\&|g') 

    find /etc/apt/sources.list /etc/apt/sources.list.d/ -type f -name '*.list' -print0 | \
    while IFS= read -r -d $'\0' apt_list_file; do
        if grep -qF "${CRAN_REPO_LINE}" "$apt_list_file"; then 
            _log "INFO" "CRAN repository entry (matching simple format) found in '${apt_list_file}'. Backing up and removing."
            _backup_file "$apt_list_file"
            _run_command "Remove CRAN entry from '${apt_list_file}'" sed -i.cran_removed_bak "\#${cran_line_pattern_to_remove_escaped}#d" "$apt_list_file"
        fi
    done

    _log "INFO" "Removing CRAN GPG key file '${CRAN_APT_KEYRING_FILE}'..."
    if [[ -f "$CRAN_APT_KEYRING_FILE" ]]; then
        _run_command "Remove CRAN GPG key file '${CRAN_APT_KEYRING_FILE}'" rm -f "$CRAN_APT_KEYRING_FILE"
    else
        _log "INFO" "CRAN GPG key file '${CRAN_APT_KEYRING_FILE}' not found."
    fi
    
    _log "INFO" "CRAN apt repository configuration removal finished."
    _log "INFO" "Consider running 'apt-get update' after these changes."
}


fn_uninstall_system_packages() {
    _log "INFO" "Uninstalling system packages installed by this script (RStudio Server, R, OpenBLAS, OpenMP, bspm)..."

    if dpkg -s rstudio-server &>/dev/null; then
        _log "INFO" "Stopping and purging RStudio Server..."
        _run_command "Stop RStudio Server" _safe_systemctl stop rstudio-server 
        _run_command "Disable RStudio Server from boot" _safe_systemctl disable rstudio-server 
        _run_command "Purge RStudio Server package" apt-get purge -y rstudio-server
    else
        _log "INFO" "RStudio Server package (rstudio-server) not found, or already removed."
    fi

    local pkgs_to_purge=(
        "r-base" "r-base-dev" "r-base-core"            
        "r-cran-bspm"                                 
        "python3-dbus" "python3-gi" "python3-apt"     
        "libopenblas-dev" "libomp-dev"                
        "gdebi-core" "software-properties-common" "dirmngr"   
    )
    local actual_pkgs_to_purge=()
    for pkg_name in "${pkgs_to_purge[@]}"; do
        if dpkg -s "$pkg_name" &>/dev/null; then
            actual_pkgs_to_purge+=("$pkg_name")
        fi
    done

    if [[ ${#actual_pkgs_to_purge[@]} -gt 0 ]]; then
        _log "INFO" "The following system packages will be purged: ${actual_pkgs_to_purge[*]}"
        _run_command "Purge specified system packages" apt-get purge -y "${actual_pkgs_to_purge[@]}"
    else
        _log "INFO" "None of the targeted system packages (R, bspm, OpenBLAS, etc.) are currently installed, or they were already removed."
    fi

    _log "INFO" "Running apt autoremove and autoclean to remove unused dependencies and clean cache..."
    _run_command "Run apt autoremove" apt-get autoremove -y
    _run_command "Run apt autoclean" apt-get autoclean -y

    _log "INFO" "Updating apt cache after removals..."
    _run_command "Update apt cache" apt-get update -y
    _log "INFO" "System package uninstallation process finished."
}


fn_remove_leftover_files() {
    _log "INFO" "Removing leftover R and RStudio Server related files and directories..."
    if [[ -z "${RSTUDIO_DEB_FILENAME:-}" ]] && [[ -f "$R_ENV_STATE_FILE" ]]; then
        _log "DEBUG" "fn_remove_leftover_files: Sourcing state file for RSTUDIO_DEB_FILENAME."
        # shellcheck source=/dev/null
        source "$R_ENV_STATE_FILE"
    fi


    declare -a paths_to_remove=(
        "/usr/local/lib/R"         
        "/usr/local/bin/R"         
        "/usr/local/bin/Rscript"   
        "/var/lib/rstudio-server"  
        "/var/run/rstudio-server"  
        "/etc/rstudio"             
    )

    if [[ -d "/etc/R" ]]; then
        if dpkg-query -S "/etc/R" >/dev/null 2>&1 || dpkg-query -S "/etc/R/*" >/dev/null 2>&1; then
            _log "INFO" "Directory '/etc/R' or its contents appear to be owned by an installed package. Skipping its direct removal."
        else
            _log "INFO" "Directory '/etc/R' seems unowned by any package. Adding it to the removal list."
            paths_to_remove+=("/etc/R")
        fi
    fi
    
    for path_item in "${paths_to_remove[@]}"; do
        if [[ -d "$path_item" ]]; then
            _log "INFO" "Attempting to remove directory: '${path_item}'"
            _run_command "Remove directory '${path_item}'" rm -rf "$path_item"
        elif [[ -f "$path_item" || -L "$path_item" ]]; then
            _log "INFO" "Attempting to remove file/symlink: '${path_item}'"
            _run_command "Remove file/symlink '${path_item}'" rm -f "$path_item"
        else
            _log "INFO" "Path '${path_item}' not found, or already removed. Skipping."
        fi
    done

    if [[ -n "${RSTUDIO_DEB_FILENAME:-}" && -f "/tmp/${RSTUDIO_DEB_FILENAME}" ]]; then
        _log "INFO" "Removing downloaded RStudio Server .deb file: '/tmp/${RSTUDIO_DEB_FILENAME}'"
        rm -f "/tmp/${RSTUDIO_DEB_FILENAME}"
    else
        _log "INFO" "No RStudio .deb file matching known filename ('${RSTUDIO_DEB_FILENAME:-not set}') found in /tmp."
    fi

    local is_interactive_shell=false
    if [[ -t 0 && -t 1 ]]; then 
        is_interactive_shell=true
    fi
    local prompt_for_aggressive_cleanup="${PROMPT_AGGRESSIVE_CLEANUP_ENV:-yes}" 

    if [[ "${FORCE_USER_CLEANUP:-no}" == "yes" ]] || \
       [[ "$is_interactive_shell" == "true" && "$prompt_for_aggressive_cleanup" == "yes" ]]; then
        
        local perform_aggressive_user_cleanup=false
        if [[ "${FORCE_USER_CLEANUP:-no}" == "yes" ]]; then
            _log "INFO" "FORCE_USER_CLEANUP is 'yes'. Proceeding with aggressive user-level R data removal."
            perform_aggressive_user_cleanup=true
        elif $is_interactive_shell; then 
            _log "WARN" "PROMPT: You are about to perform an AGGRESSIVE cleanup of R-related data from user home directories."
            _log "WARN" "This includes ~/.R, ~/R, ~/.config/R*, ~/.cache/R*, ~/.rstudio, etc., for ALL users with UID >= 1000."
            _log "WARN" "THIS IS DESTRUCTIVE AND CANNOT BE UNDONE."
            read -r -p "Are you sure you want to remove these user-level R files and directories? (Type 'yes' to proceed, anything else to skip): " aggressive_confirm_response
            if [[ "$aggressive_confirm_response" == "yes" ]]; then
                perform_aggressive_user_cleanup=true
            else
                _log "INFO" "Skipping aggressive user-level R cleanup based on user response."
            fi
        fi

        if [[ "$perform_aggressive_user_cleanup" == "true" ]]; then
            _log "INFO" "Starting aggressive user-level R configuration and library cleanup..."
            awk -F: '$3 >= 1000 && $3 < 60000 && $6 != "" && $6 != "/nonexistent" && $6 != "/" {print $6}' /etc/passwd | while IFS= read -r user_home_dir; do
                if [[ -d "$user_home_dir" ]]; then 
                    _log "INFO" "Scanning user home directory for R data: '${user_home_dir}'"
                    declare -a user_r_data_paths=(
                        "${user_home_dir}/.R"
                        "${user_home_dir}/.RData"
                        "${user_home_dir}/.Rhistory"
                        "${user_home_dir}/.Rprofile"
                        "${user_home_dir}/.Renviron"
                        "${user_home_dir}/R" 
                        "${user_home_dir}/.config/R"
                        "${user_home_dir}/.config/rstudio"
                        "${user_home_dir}/.cache/R"
                        "${user_home_dir}/.cache/rstudio"
                        "${user_home_dir}/.local/share/rstudio"
                        "${user_home_dir}/.local/share/renv" 
                    )
                    for r_path_to_check in "${user_r_data_paths[@]}"; do
                        if [[ -e "$r_path_to_check" ]]; then 
                            _log "WARN" "Aggressive Cleanup: Removing '${r_path_to_check}'"
                            if [[ "$r_path_to_check" != "$user_home_dir" && "$r_path_to_check" == "$user_home_dir/"* ]]; then
                                _run_command "Aggressively remove user R path '${r_path_to_check}'" rm -rf "$r_path_to_check"
                            else
                                _log "ERROR" "Safety break: Skipped removing suspicious path '${r_path_to_check}'."
                            fi
                        fi
                    done
                else
                     _log "INFO" "User home directory '${user_home_dir}' listed in /etc/passwd does not exist. Skipping."
                fi
            done
            _log "INFO" "Aggressive user-level R data cleanup attempt finished."
        fi
    else
        _log "INFO" "Skipping aggressive user-level R data cleanup."
    fi
    _log "INFO" "Leftover file and directory removal process finished."
}


# --- Main Execution ---
install_all() {
    _log "INFO" "--- Starting Full R Environment Installation ---"
    fn_pre_flight_checks
    _log "DEBUG" "After fn_pre_flight_checks in install_all: UBUNTU_CODENAME='${UBUNTU_CODENAME:-}', CRAN_REPO_LINE='${CRAN_REPO_LINE:-}'"
    fn_add_cran_repo
    _log "DEBUG" "After fn_add_cran_repo in install_all: UBUNTU_CODENAME='${UBUNTU_CODENAME:-}', CRAN_REPO_LINE='${CRAN_REPO_LINE:-}'"
    fn_install_r
    fn_install_openblas_openmp
    
    if ! fn_verify_openblas_openmp; then 
        _log "WARN" "OpenBLAS/OpenMP verification encountered issues or failed. Installation will continue, but performance or stability might be affected. Review logs carefully."
    else
        _log "INFO" "OpenBLAS/OpenMP verification passed."
    fi
    
    if ! fn_setup_bspm; then 
        _log "ERROR" "BSPM (R2U Binary Package Manager) setup failed. Subsequent R package installations might not use bspm correctly."
    else
        _log "INFO" "BSPM setup appears successful."
    fi
    
    fn_install_r_packages 
    fn_install_rstudio_server
    
    _log "INFO" "--- Full R Environment Installation Completed ---"
    _log "INFO" "Summary:"
    _log "INFO" "- R version: $(R --version | head -n 1 || echo 'Not found')"
    _log "INFO" "- RStudio Server version: $(rstudio-server version 2>/dev/null || echo 'Not found/not running')"
    _log "INFO" "- RStudio Server URL: http://<YOUR_SERVER_IP>:8787 (if not firewalled)"
    _log "INFO" "- BSPM status: Check logs from fn_setup_bspm and fn_install_r_packages."
    _log "INFO" "- Main log file for this session: ${LOG_FILE}"
    _log "INFO" "- State file (for individual function calls): ${R_ENV_STATE_FILE}"
}

uninstall_all() {
    _log "INFO" "--- Starting Full R Environment Uninstallation ---"
    _ensure_root 

    _get_r_profile_site_path 

    if [[ -f "$R_ENV_STATE_FILE" ]]; then
        _log "INFO" "Uninstall: Sourcing state from ${R_ENV_STATE_FILE}"
        # shellcheck source=/dev/null
        source "$R_ENV_STATE_FILE"
    fi

    fn_uninstall_r_packages      
    fn_remove_bspm_config        
    fn_uninstall_system_packages 
    fn_remove_cran_repo          
    fn_remove_leftover_files     

    _log "INFO" "--- Verification of Uninstallation ---"
    local verification_issues_found=0
    
    if command -v R &>/dev/null; then _log "WARN" "VERIFICATION FAIL: 'R' command still found."; ((verification_issues_found++)); else _log "INFO" "VERIFICATION OK: 'R' command not found."; fi
    if command -v Rscript &>/dev/null; then _log "WARN" "VERIFICATION FAIL: 'Rscript' command still found."; ((verification_issues_found++)); else _log "INFO" "VERIFICATION OK: 'Rscript' command not found."; fi
    if command -v rstudio-server &>/dev/null; then _log "WARN" "VERIFICATION FAIL: 'rstudio-server' command still found."; ((verification_issues_found++)); fi

    local pkgs_to_check_absent=("rstudio-server" "r-base" "r-cran-bspm" "libopenblas-dev" "libomp-dev")
    for pkg_check in "${pkgs_to_check_absent[@]}"; do
        if dpkg -s "$pkg_check" &>/dev/null; then
            _log "WARN" "VERIFICATION FAIL: Package '$pkg_check' is still installed."
            ((verification_issues_found++))
        else
            _log "INFO" "VERIFICATION OK: Package '$pkg_check' is not installed."
        fi
    done

    _log "INFO" "VERIFICATION: Check logs from 'fn_remove_bspm_config' and 'fn_remove_cran_repo' to confirm apt sources were removed."

    if [[ $verification_issues_found -eq 0 ]]; then
        _log "INFO" "--- Full R Environment Uninstallation Completed Successfully (based on checks) ---"
    else
        _log "ERROR" "--- Full R Environment Uninstallation Completed with ${verification_issues_found} verification issue(s). ---"
        _log "ERROR" "Manual inspection of the system and the log file ('${LOG_FILE}') is recommended to ensure complete removal."
    fi
    # rm -f "$R_ENV_STATE_FILE" 
}


# --- Menu / Argument Parsing ---
usage() {
    echo "Usage: $0 [ACTION]"
    echo "Manages a comprehensive R environment including R, RStudio Server, OpenBLAS, BSPM, and R packages."
    echo ""
    echo "Global Options (can be set as environment variables):"
    echo "  GITHUB_PAT: Your GitHub Personal Access Token for installing R packages from GitHub."
    echo "  CUSTOM_R_PROFILE_SITE_PATH_ENV: Override auto-detection of Rprofile.site path."
    echo "  FORCE_USER_CLEANUP: 'yes' or 'no'. If 'yes', aggressively removes user-level R data during uninstall without prompting."
    echo "  PROMPT_AGGRESSIVE_CLEANUP_ENV: 'yes' or 'no'. If 'no' and interactive, skips prompting for aggressive cleanup during uninstall."
    echo ""
    echo "Actions:"
    echo "  install_all                 Run all installation steps to set up the R environment."
    echo "  uninstall_all               Uninstall all components managed or installed by this script."
    echo "  interactive                 Show an interactive menu to run individual steps (default if no action)."
    echo ""
    echo "Individual functions (primarily for development/debugging - use with caution):"
    echo "  fn_pre_flight_checks        (Writes state to ${R_ENV_STATE_FILE})"
    echo "  fn_add_cran_repo            (May source state from ${R_ENV_STATE_FILE} if needed)"
    echo "  fn_install_r, fn_install_openblas_openmp, fn_verify_openblas_openmp"
    echo "  fn_setup_bspm, fn_install_r_packages, fn_install_rstudio_server"
    echo ""
    echo "Log file for this session will be in: ${LOG_DIR}/r_setup_YYYYMMDD_HHMMSS.log"
    exit 1
}

interactive_menu() {
    _ensure_root
    if [[ -f "$R_ENV_STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$R_ENV_STATE_FILE"
    fi
    _get_r_profile_site_path


    while true; do
        local display_rstudio_version="$RSTUDIO_VERSION_FALLBACK" 
        if [[ -n "${UBUNTU_CODENAME:-}" && -n "${RSTUDIO_ARCH:-}" ]]; then
            if [[ -f "$R_ENV_STATE_FILE" ]]; then 
                # shellcheck source=/dev/null
                source "$R_ENV_STATE_FILE"
            fi
            if [[ -n "$RSTUDIO_VERSION" && "$RSTUDIO_VERSION" != "$RSTUDIO_VERSION_FALLBACK" ]]; then
                display_rstudio_version="$RSTUDIO_VERSION (From State/Fallback)"
            elif [[ -n "${RSTUDIO_DEB_FILENAME:-}" ]] ; then 
                 display_rstudio_version="${RSTUDIO_VERSION} (Current Target)"
            fi
        else
            display_rstudio_version="$RSTUDIO_VERSION_FALLBACK (Run Pre-flight to update)"
        fi


        echo ""
        echo "================ R Environment Setup Menu ================"
        echo "Log File: ${LOG_FILE}"
        echo "State File: ${R_ENV_STATE_FILE} (used for individual step calls)"
        echo "Ubuntu Codename: ${UBUNTU_CODENAME:-Not yet detected (Run Pre-flight)}"
        echo "System Architecture: ${RSTUDIO_ARCH:-Not yet detected (Run Pre-flight)}"
        echo "Rprofile.site for bspm: ${R_PROFILE_SITE_PATH:-Not yet determined/set}"
        echo "RStudio Server version (target): ${display_rstudio_version}"
        echo "------------------------------------------------------------"
        echo " Installation Steps:"
        echo "  1. Full Installation (all steps below)"
        echo "  2. Pre-flight Checks (detect OS, arch, install script deps, write state file)"
        echo "  3. Add CRAN Repo & Install R"
        echo "  4. Install OpenBLAS & OpenMP"
        echo "  5. Verify OpenBLAS/OpenMP with R"
        echo "  6. Setup BSPM (R2U Binary Package Manager)"
        echo "  7. Install R Packages (CRAN & GitHub)"
        echo "  8. Install RStudio Server"
        echo "------------------------------------------------------------"
        echo " Uninstallation:"
        echo "  9. Uninstall All Components"
        echo "  F. Toggle Aggressive User Data Cleanup for Uninstall (Current: ${FORCE_USER_CLEANUP})"
        echo "------------------------------------------------------------"
        echo "  0. Exit Menu"
        echo "============================================================"
        read -r -p "Choose an option: " option
        
        case "$option" in
            1) install_all ;;
            2) fn_pre_flight_checks ;;
            3) fn_pre_flight_checks; fn_add_cran_repo; fn_install_r ;; 
            4) fn_pre_flight_checks; fn_install_openblas_openmp ;; 
            5) fn_pre_flight_checks; fn_install_r; fn_install_openblas_openmp; fn_verify_openblas_openmp ;; 
            6) fn_pre_flight_checks; fn_install_r; fn_setup_bspm ;; 
            7) fn_pre_flight_checks; fn_install_r; fn_setup_bspm; fn_install_r_packages ;; 
            8) fn_pre_flight_checks; fn_install_r; fn_install_rstudio_server ;; 
            
            9) uninstall_all ;;
            
            F|f) 
                if [[ "$FORCE_USER_CLEANUP" == "yes" ]]; then
                    FORCE_USER_CLEANUP="no"
                    _log "INFO" "Aggressive user data cleanup during uninstall TOGGLED OFF."
                else
                    FORCE_USER_CLEANUP="yes"
                    _log "INFO" "Aggressive user data cleanup during uninstall TOGGLED ON."
                fi
                ;;
            0) _log "INFO" "Exiting interactive menu."; exit 0 ;;
            *) _log "WARN" "Invalid option: '$option'. Please try again." ;;
        esac
        echo ""
        read -r -p "Action finished or selected. Press Enter to return to menu..."
    done
}

main() {
    _log "INFO" "Script execution started. Logging to: ${LOG_FILE}"
    if [[ $# -gt 0 && "$1" != "install_all" && "$1" != "uninstall_all" && "$1" != "interactive" ]]; then
        if [[ -f "$R_ENV_STATE_FILE" ]]; then
            _log "INFO" "Individual function call detected. Sourcing existing state file: ${R_ENV_STATE_FILE}"
            # shellcheck source=/dev/null
            source "$R_ENV_STATE_FILE"
        else
            _log "WARN" "Individual function call detected, but no state file (${R_ENV_STATE_FILE}) found. Variables might not be set."
        fi
    fi


    _get_r_profile_site_path 

    if [[ $# -eq 0 ]]; then
        _log "INFO" "No action specified, entering interactive menu."
        interactive_menu
    else
        _ensure_root 
        local action_arg="$1"
        shift 
        
        local target_function_name=""
        case "$action_arg" in
            install_all|uninstall_all)
                target_function_name="$action_arg"
                ;;
            interactive)
                _log "INFO" "Action 'interactive' called directly. Starting menu."
                interactive_menu
                _log "INFO" "Script finished after interactive session via direct call."
                exit 0
                ;;
            fn_pre_flight_checks|fn_add_cran_repo|fn_install_r|fn_install_openblas_openmp|\
            fn_verify_openblas_openmp|fn_setup_bspm|fn_install_r_packages|fn_install_rstudio_server|\
            fn_uninstall_r_packages|fn_remove_bspm_config|fn_uninstall_system_packages|fn_remove_cran_repo|fn_remove_leftover_files)
                target_function_name="$action_arg"
                _log "INFO" "Directly invoking function: ${target_function_name}"
                ;;
            toggle_aggressive_cleanup)
                if [[ "$FORCE_USER_CLEANUP" == "yes" ]]; then
                    FORCE_USER_CLEANUP="no"
                    _log "INFO" "Aggressive user data cleanup (FORCE_USER_CLEANUP) set to 'no'."
                else
                    FORCE_USER_CLEANUP="yes"
                    _log "INFO" "Aggressive user data cleanup (FORCE_USER_CLEANUP) set to 'yes'."
                fi
                echo "FORCE_USER_CLEANUP is now: $FORCE_USER_CLEANUP" 
                _log "INFO" "Script finished after toggling FORCE_USER_CLEANUP."
                exit 0
                ;;
            *)
                _log "ERROR" "Unknown direct action: '$action_arg'."
                _log "ERROR" "Run without arguments for interactive menu, or use a valid action like 'install_all' or 'uninstall_all'."
                usage 
                ;;
        esac
        
        if declare -f "$target_function_name" >/dev/null; then
            "$target_function_name" "$@" 
        else 
            _log "ERROR" "Internal script error: Target function '${target_function_name}' for action '${action_arg}' is not defined or not callable."
            usage
        fi
    fi
    _log "INFO" "Script execution finished."
}

main "$@"
