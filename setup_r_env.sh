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
set -euo pipefail # -e: exit on error, -u: treat unset variables as error, -o pipefail: causes a pipeline to fail if any command fails

export DEBIAN_FRONTEND=noninteractive

# Logging
LOG_DIR="/var/log/r_setup"
LOG_FILE="${LOG_DIR}/r_setup_$(date +'%Y%m%d_%H%M%S').log"
# Ensure log directory and file are writable by the script runner (root)
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE" # Group rwx, Other r-- (adjust if needed)

# Backup
BACKUP_DIR="/opt/r_setup_backups"; mkdir -p "$BACKUP_DIR"

# System
UBUNTU_CODENAME_DETECTED="" # Will be detected in pre_flight_checks
R_PROFILE_SITE_PATH=""
USER_SPECIFIED_R_PROFILE_SITE_PATH=""
FORCE_USER_CLEANUP="no"

# RStudio - Fallback Version
RSTUDIO_VERSION_FALLBACK="2023.12.1-402" # Specify a known good recent version
RSTUDIO_ARCH_FALLBACK="amd64"
RSTUDIO_ARCH="${RSTUDIO_ARCH_FALLBACK}" # Will be detected or fallback

RSTUDIO_VERSION="$RSTUDIO_VERSION_FALLBACK"
# RSTUDIO_DEB_URL will be constructed after UBUNTU_CODENAME and RSTUDIO_ARCH are finalized
RSTUDIO_DEB_URL=""
RSTUDIO_DEB_FILENAME=""


# CRAN Repository
CRAN_REPO_URL_BASE="https://cloud.r-project.org"
CRAN_REPO_PATH_BIN="/bin/linux/ubuntu"
CRAN_REPO_PATH_SRC="/src/contrib" # Used for source package fallbacks
CRAN_REPO_URL_BIN="${CRAN_REPO_URL_BASE}${CRAN_REPO_PATH_BIN}"
CRAN_REPO_URL_SRC="${CRAN_REPO_URL_BASE}${CRAN_REPO_PATH_SRC}" # For install.packages fallback
# CRAN_REPO_LINE will be constructed after UBUNTU_CODENAME is finalized
CRAN_REPO_LINE=""
CRAN_APT_KEY_ID="E298A3A825C0D65DFD57CBB651716619E084DAB9"
CRAN_APT_KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${CRAN_APT_KEY_ID}"
CRAN_APT_KEYRING_FILE="/etc/apt/keyrings/cran-${CRAN_APT_KEY_ID}.gpg"


# R2U/BSP Repository (Binary System Package Manager for R)
R2U_REPO_URL_BASE="https://raw.githubusercontent.com/eddelbuettel/r2u/master/inst/scripts"
R2U_APT_SOURCES_LIST_D_FILE="/etc/apt/sources.list.d/r2u.list" # Standard file name by r2u script

# R Packages
R_PACKAGES_CRAN=(
    "terra" "raster" "sf" "enmSdmX" "dismo" "spThin" "rnaturalearth" "furrr"
    "doParallel" "future" "caret" "CoordinateCleaner" "tictoc" "devtools"
    "tidyverse" "dplyr" "spatstat" "ggplot2" "iNEXT" "DHARMa" "lme4" "glmmTMB"
    "geodata" "osmdata" "parallel" "doSNOW" "progress" "nngeo" "wdpar" "rgee" "tidyrgee"
    "data.table" "jsonlite" "httr" # Added jsonlite and httr as common devtools deps
)
R_PACKAGES_GITHUB=(
    "SantanderMetGroup/transformeR"
    "SantanderMetGroup/mopa"
    "HelgeJentsch/ClimDatDownloadR"
)

UBUNTU_CODENAME="" # Will be set by fn_pre_flight_checks

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
    # Execute command, redirecting stdout and stderr to log file
    if "$@" >>"$LOG_FILE" 2>&1; then
        _log "INFO" "OK: $cmd_desc"
        return 0
    else
        local exit_code=$?
        _log "ERROR" "FAIL: $cmd_desc (RC:$exit_code). See log: $LOG_FILE"
        # Show last few lines of log for context, prefixing with spaces for readability
        if [ -f "$LOG_FILE" ]; then
            tail -n 10 "$LOG_FILE" | sed 's/^/    /' # Show more lines
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
    # Find the latest backup file for the original file path
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
    # Log details if R_PROFILE_SITE_PATH is currently empty and no user-specified path is given
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
        r_home_output=$(R RHOME 2>/dev/null || echo "") # Ensure it doesn't fail script if R not fully there
        if [[ -n "$r_home_output" && -d "$r_home_output" ]]; then
            local detected_path="${r_home_output}/etc/Rprofile.site"
            if [[ "$R_PROFILE_SITE_PATH" != "$detected_path" ]]; then
                _log "INFO" "Auto-detected R_PROFILE_SITE_PATH (from R RHOME): ${detected_path}"
            fi
            R_PROFILE_SITE_PATH="$detected_path"
            return
        fi
    fi

    # Fallback paths if R RHOME fails or R is not yet installed
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
        # If neither exists, default to the apt path for creation
        new_detected_path="$default_apt_path"
        if $log_details || [[ "$R_PROFILE_SITE_PATH" != "$new_detected_path" ]]; then
            _log "INFO" "No Rprofile.site found. Defaulting to standard location for creation: ${new_detected_path}"
        fi
    fi
    R_PROFILE_SITE_PATH="$new_detected_path"
}


_safe_systemctl() {
    if command -v systemctl >/dev/null 2>&1; then
        # Try to execute systemctl command
        if systemctl "$@" >> "$LOG_FILE" 2>&1; then
            return 0 # Success
        else
            local exit_code=$?
            # In CI or non-systemd environments, systemctl might fail or not be fully functional.
            # We log a warning but don't let it stop the script.
            if [[ "${CI:-false}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
                _log "WARN" "systemctl command '$*' failed (RC:$exit_code). Ignoring in CI context."
                return 0 # Treat as non-fatal in CI
            else
                _log "ERROR" "systemctl command '$*' failed (RC:$exit_code)."
                return "$exit_code" # Propagate error in non-CI
            fi
        fi
    else
        _log "INFO" "systemctl command not found, skipping systemctl action: $*"
        return 0 # Command not found is not an error for this wrapper
    fi
}


_is_vm_or_ci_env() {
    # Detect GitHub CI, GitLab CI, Travis, or root user on VM
    if [[ "${CI:-false}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]] || [[ -n "${TRAVIS:-}" ]]; then
        return 0 # True, is a CI environment
    elif [[ "$EUID" -eq 0 ]]; then # Also consider root on a VM as a managed environment
        return 0 # True, is root (likely a VM being provisioned)
    else
        return 1 # False
    fi
}

# --- Core Functions ---
fn_get_latest_rstudio_info() {
    _log "INFO" "Attempting to detect latest RStudio Server for ${UBUNTU_CODENAME} ${RSTUDIO_ARCH}..."
    _log "WARN" "RStudio Server auto-detection is fragile and currently disabled. Using fallback version: ${RSTUDIO_VERSION_FALLBACK}"
    # The original auto-detection logic is commented out due to its unreliability.
    # If you wish to re-enable it, ensure the grep pattern is up-to-date with Posit's website.
    # For now, we directly use the fallback.
    RSTUDIO_VERSION="$RSTUDIO_VERSION_FALLBACK"
    RSTUDIO_DEB_URL="https://download2.rstudio.org/server/${UBUNTU_CODENAME}/${RSTUDIO_ARCH}/rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
    RSTUDIO_DEB_FILENAME="rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
    _log "INFO" "Using RStudio Server: ${RSTUDIO_VERSION} from ${RSTUDIO_DEB_URL}"

    # --- Original auto-detection logic (commented out) ---
    # local download_page_content="" latest_url="" temp_version=""
    # ... (rest of the original fn_get_latest_rstudio_info logic) ...
    # if [[ -z "$grep_output" ]]; then
    #     _log "WARN" "Could not find an RStudio Server .deb URL for ${UBUNTU_CODENAME}/${RSTUDIO_ARCH}. Using fallback."
    # ...
    # fi
}


fn_pre_flight_checks() {
    _log "INFO" "Performing pre-flight checks..."
    _ensure_root # Script must run as root

    # Determine Ubuntu Codename
    if command -v lsb_release &>/dev/null; then
        UBUNTU_CODENAME_DETECTED=$(lsb_release -cs)
    else
        _log "WARN" "lsb_release command not found. Attempting to install lsb-release."
        apt-get update -y >>"$LOG_FILE" 2>&1 || _log "WARN" "apt update failed during lsb-release prerequisite."
        apt-get install -y lsb-release >>"$LOG_FILE" 2>&1 || {
            _log "ERROR" "Failed to install lsb-release. Cannot determine Ubuntu codename."
            exit 1
        }
        if command -v lsb_release &>/dev/null; then
            UBUNTU_CODENAME_DETECTED=$(lsb_release -cs)
        else
            _log "ERROR" "lsb_release installed but still not found or codename undetectable. Exiting."
            exit 1
        fi
    fi
    UBUNTU_CODENAME="$UBUNTU_CODENAME_DETECTED" # Set the global variable
    _log "INFO" "Detected Ubuntu codename: ${UBUNTU_CODENAME}"
    if [[ -z "$UBUNTU_CODENAME" || "$UBUNTU_CODENAME" == "unknown" ]]; then
        _log "ERROR" "Ubuntu codename is invalid ('$UBUNTU_CODENAME'). Exiting."
        exit 1
    fi

    # Determine System Architecture
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

    # Finalize RStudio URLs and CRAN repo line based on detected codename and arch
    # Call fn_get_latest_rstudio_info to set RSTUDIO_VERSION, RSTUDIO_DEB_URL, RSTUDIO_DEB_FILENAME
    fn_get_latest_rstudio_info # This will use fallback due to commented out auto-detection

    CRAN_REPO_LINE="deb [signed-by=${CRAN_APT_KEYRING_FILE}] ${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME}-cran40/"
    _log "INFO" "CRAN repository line to be used: ${CRAN_REPO_LINE}"
    _log "INFO" "RStudio Server version to be used: ${RSTUDIO_VERSION} (URL: ${RSTUDIO_DEB_URL})"

    # Ensure essential directories exist
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "/etc/apt/keyrings"

    # Install missing essential dependencies for the script itself
    local essential_deps=("wget" "gpg" "apt-transport-https" "ca-certificates" "curl" "gdebi-core" "software-properties-common")
    local missing_deps=()
    for dep in "${essential_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        _log "INFO" "Installing missing essential script dependencies: ${missing_deps[*]}"
        _run_command "Update apt cache for dependencies" apt-get update -y
        _run_command "Install essential dependencies: ${missing_deps[*]}" apt-get install -y "${missing_deps[@]}"
    fi
    _log "INFO" "Pre-flight checks completed."
}

fn_add_cran_repo() {
    _log "INFO" "Adding CRAN repository..."

    # Check if software-properties-common is installed (for add-apt-repository)
    if ! command -v add-apt-repository &>/dev/null; then
        _log "INFO" "'add-apt-repository' not found. Installing 'software-properties-common'."
        _run_command "Install software-properties-common" apt-get install -y software-properties-common
    fi
    
    # Add CRAN GPG key using the new method
    if [[ ! -f "$CRAN_APT_KEYRING_FILE" ]]; then
        _log "INFO" "Adding CRAN GPG key ${CRAN_APT_KEY_ID} to ${CRAN_APT_KEYRING_FILE}"
        _run_command "Download CRAN GPG key" curl -fsSL "${CRAN_APT_KEY_URL}" -o "/tmp/cran_key.asc"
        _run_command "Import CRAN GPG key" gpg --dearmor -o "${CRAN_APT_KEYRING_FILE}" "/tmp/cran_key.asc"
        rm -f "/tmp/cran_key.asc"
    else
        _log "INFO" "CRAN GPG key ${CRAN_APT_KEYRING_FILE} already exists."
    fi
    
    # Check if CRAN repository line already exists
    # Note: grep -E pattern for CRAN_REPO_LINE needs to be crafted carefully if it contains special chars.
    # For simplicity, we'll use a known part of the URL.
    if grep -qrE "${CRAN_REPO_URL_BIN}.*${UBUNTU_CODENAME}-cran40" /etc/apt/sources.list /etc/apt/sources.list.d/; then
        _log "INFO" "CRAN repository for '${UBUNTU_CODENAME}-cran40' seems to be already configured."
    else
        _run_command "Add CRAN repository entry" add-apt-repository -y -n "${CRAN_REPO_LINE}" # -n to avoid auto apt update
        _run_command "Update apt cache after adding CRAN repo" apt-get update -y
        _log "INFO" "CRAN repository added and apt cache updated."
    fi
}

fn_install_r() {
    _log "INFO" "Installing R..."
    if dpkg -s r-base &>/dev/null; then
        _log "INFO" "R (r-base) is already installed. Version: $(dpkg-query -W -f='${Version}\n' r-base 2>/dev/null || echo 'N/A')"
    else
        _run_command "Install R (r-base, r-base-dev, r-base-core)" apt-get install -y r-base r-base-dev r-base-core
        _log "INFO" "R installed. Version: $(R --version | head -n 1)"
    fi
    _get_r_profile_site_path # Determine Rprofile.site path after R is installed
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
    # Detect common architecture suffixes for BLAS libraries
    if [ -e "/usr/lib/x86_64-linux-gnu/libblas.so.3" ]; then
        arch_suffix="-x86_64-linux-gnu"
    elif [ -e "/usr/lib/aarch64-linux-gnu/libblas.so.3" ]; then
        arch_suffix="-aarch64-linux-gnu"
    fi

    _log "INFO" "Displaying BLAS/LAPACK alternatives (if configured):"
    # update-alternatives --display can return non-zero if the alternative is not configured.
    # We capture output and log it, but don't fail the script.
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
    _display_blas_alternatives # Call the helper to display alternatives

    if command -v openblas_get_config &>/dev/null; then
        _log "INFO" "Attempting to get OpenBLAS compile-time configuration..."
        # This command might not always succeed or be relevant, so don't let it fail the script.
        ( openblas_get_config >> "$LOG_FILE" 2>&1 ) || _log "WARN" "openblas_get_config command executed with a non-zero exit code. Output (if any) is in the log."
    else
        _log "INFO" "openblas_get_config command not found. Skipping."
    fi

    local r_check_script_file="/tmp/check_r_blas_openmp.R"
    # Using 'EOF' to prevent variable expansion inside the R script heredoc
cat > "$r_check_script_file" << 'EOF'
options(error = quote({
    cat("Unhandled R Error: ", geterrmessage(), "\n", file = stderr())
    cat("Dumping frames to .RData and Rplots.pdf for debugging (if permissions allow).\n", file=stderr())
    dump.frames(to.file = TRUE, include.GlobalEnv = TRUE) 
    q("no", status = 1, runLast = FALSE) 
}))
cat("--- R Environment Details ---\n")
cat("R version and platform:\n"); print(R.version)
cat("\nSession Info (BLAS/LAPACK linkage by R):\n"); print(sessionInfo())
cat("\nExtended Software Version (BLAS/LAPACK versions used by R):\n")
if (exists("extSoftVersion", where = "package:utils") && is.function(utils::extSoftVersion)) { print(utils::extSoftVersion()) } else { cat("utils::extSoftVersion() not available (requires utils package loaded, typically by default).\n") }
cat("\nChecking R's LD_LIBRARY_PATH:\n"); print(Sys.getenv("LD_LIBRARY_PATH"))
cat("\nLoaded DLLs/shared objects for BLAS/LAPACK:\n")
if (exists("getLoadedDLLs", where="package:base") && is.function(getLoadedDLLs)) {
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
} else { cat("getLoadedDLLs() not found in base package.\n") }

cat("\n--- BLAS Performance Benchmark (crossprod) ---\n")
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
omp_test <- function() {
    num_cores <- tryCatch(parallel::detectCores(logical=TRUE), error=function(e){cat("Warning: detectCores() failed:",conditionMessage(e),"\n");1L})
    if(!is.numeric(num_cores) || num_cores < 1L) num_cores <- 1L
    cat("Logical cores detected by R:", num_cores, "\n")
    if (.Platform$OS.type == "unix") {
        test_cores <- min(num_cores, 2L); # Test with a small number of cores
        cat("Attempting parallel::mclapply test with", test_cores, "core(s)...\n")
        # mclapply relies on fork, which can be problematic in some contexts (like RStudio GUI)
        # but should be fine in a script.
        res <- tryCatch(parallel::mclapply(1:test_cores, function(x) Sys.getpid(), mc.cores=test_cores), 
                        error=function(e){cat("Error during mclapply:",conditionMessage(e),"\n",file=stderr());NULL})
        if(!is.null(res) && length(res) > 0){
             cat("mclapply call successful. Unique PIDs from workers:",length(unique(unlist(res))),"\n")
             if (length(unique(unlist(res))) > 1) {
                cat("Multiple PIDs suggest mclapply is using multiple processes (good sign for OpenMP if R was built with it).\n")
             } else if (test_cores > 1) {
                cat("Single PID returned by mclapply with multiple cores requested. This might indicate a problem with forking or OpenMP setup in R's parallel capabilities.\n")
             }
        } else {
            cat("mclapply failed or returned no results.\n")
        }
    } else {
        cat("mclapply test skipped (not on a Unix-like OS).\n")
    }
    cat("Note: True OpenMP usage in BLAS/LAPACK operations (like matrix multiplication) depends on how those libraries were compiled (e.g., OpenBLAS with USE_OPENMP=1).\n")
    cat("The sessionInfo() output can sometimes indicate OpenMP linkage if R itself was compiled with OpenMP support.\n")
}
omp_test()

cat("\n--- Verification Script Finished ---\n")
if (!crossprod_result) { 
    q("no", status = 3, runLast = FALSE) # Exit with status 3 if BLAS benchmark failed earlier
}
EOF

    _log "INFO" "Executing R verification script: ${r_check_script_file}"
    local r_script_rc=0
    # Run Rscript, capturing its exit code
    ( Rscript "$r_check_script_file" >> "$LOG_FILE" 2>&1 ) || r_script_rc=$?

    if [[ $r_script_rc -eq 0 ]]; then
        _log "INFO" "OpenBLAS/OpenMP R verification script completed successfully."
    else
        _log "ERROR" "OpenBLAS/OpenMP R verification script FAILED (Rscript Exit Code: ${r_script_rc})."
        _log "ERROR" "Check the main log file (${LOG_FILE}) for detailed R output and error messages."
        if [[ $r_script_rc -eq 132 || $r_script_rc -eq 2 || $r_script_rc -eq 3 ]]; then # 132 is often SIGILL (Illegal Instruction)
            _log "ERROR" "Exit code ${r_script_rc} (often indicates 'Illegal Instruction' if 132) can occur in VMs/QEMU due to CPU feature incompatibility with the compiled BLAS library."
            _log "ERROR" "See R script output in the log for recommendations (e.g., QEMU CPU model, or using update-alternatives to switch to a reference BLAS)."
        fi
        # Clean up temporary files and R dump files if they were created
        rm -f "$r_check_script_file" Rplots.pdf .RData last.dump.rda
        return 1 # Indicate failure
    fi

    # Clean up temporary files
    rm -f "$r_check_script_file" Rplots.pdf .RData last.dump.rda
    _log "INFO" "OpenBLAS and OpenMP verification step finished."
    return 0
}

fn_setup_bspm() {
    _log "INFO" "Setting up bspm (Binary R Package Manager from R2U)..."
    _get_r_profile_site_path # Ensure R_PROFILE_SITE_PATH is set

    if [[ -z "$R_PROFILE_SITE_PATH" ]]; then
        _log "ERROR" "R_PROFILE_SITE_PATH is not set. Cannot reliably setup bspm. Ensure R is installed or path is specified."
        return 1
    fi

    if ! _is_vm_or_ci_env; then
        _log "INFO" "Not detected as root or a CI/VM environment. Skipping bspm setup for safety (bspm modifies system Rprofile)."
        return 0
    fi

    local r_profile_dir
    r_profile_dir=$(dirname "$R_PROFILE_SITE_PATH")
    if [[ ! -d "$r_profile_dir" ]]; then
        _run_command "Create directory for Rprofile.site: ${r_profile_dir}" mkdir -p "$r_profile_dir"
    fi

    if [[ ! -f "$R_PROFILE_SITE_PATH" && ! -L "$R_PROFILE_SITE_PATH" ]]; then
        _log "INFO" "Rprofile.site ('${R_PROFILE_SITE_PATH}') does not exist. Creating it..."
        _run_command "Create Rprofile.site: ${R_PROFILE_SITE_PATH}" touch "$R_PROFILE_SITE_PATH"
    fi
    _backup_file "$R_PROFILE_SITE_PATH"


    # Check if sudo is installed (bspm might use it internally via options(bspm.sudo=TRUE))
    if ! command -v sudo &>/dev/null; then
        _log "WARN" "'sudo' command is not installed. bspm may require it. Attempting to install sudo..."
        if [[ $EUID -ne 0 ]]; then # Should not happen due to _ensure_root
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

    # Add R2U repository using Dirk's script
    _log "INFO" "Configuring R2U repository (provides bspm and binary R packages)..."
    # Check if R2U repo is already configured (based on r2u.list or content)
    if [[ -f "$R2U_APT_SOURCES_LIST_D_FILE" ]] && grep -q "r2u.stat.illinois.edu/ubuntu" "$R2U_APT_SOURCES_LIST_D_FILE"; then
        _log "INFO" "R2U repository file '${R2U_APT_SOURCES_LIST_D_FILE}' seems to be already configured."
    else
        local r2u_setup_script_url="${R2U_REPO_URL_BASE}/add_cranapt_jammy.sh" # Defaulting to jammy for wider compatibility, adjust if needed for noble specifically
        if [[ "$UBUNTU_CODENAME" == "noble" ]]; then
             r2u_setup_script_url="${R2U_REPO_URL_BASE}/add_cranapt_noble.sh" # Use noble if detected
        elif [[ "$UBUNTU_CODENAME" == "focal" ]]; then
             r2u_setup_script_url="${R2U_REPO_URL_BASE}/add_cranapt_focal.sh"
        fi
        _log "INFO" "Downloading R2U setup script from: ${r2u_setup_script_url}"
        _run_command "Download R2U setup script" curl -fsSL "${r2u_setup_script_url}" -o "/tmp/add_r2u_repo.sh"
        
        _log "INFO" "Executing R2U repository setup script (/tmp/add_r2u_repo.sh)..."
        # The R2U script itself uses sudo internally if needed. Running as root should be fine.
        if ! bash "/tmp/add_r2u_repo.sh" >> "$LOG_FILE" 2>&1; then
            _log "ERROR" "Failed to execute R2U repository setup script. Check log for details."
            rm -f "/tmp/add_r2u_repo.sh"
            return 1
        fi
        _log "INFO" "R2U repository setup script executed. Apt cache likely updated by the script."
        rm -f "/tmp/add_r2u_repo.sh"
    fi
    # R2U script should handle apt update. If issues, add: _run_command "Update apt cache after R2U setup" apt-get update -y

    # Ensure dbus is running, as bspm/apt might need it
    # Using _safe_systemctl for broader compatibility
    if _safe_systemctl list-units --type=service --all | grep -q 'dbus.service'; then
        _log "INFO" "dbus.service found. Ensuring it is active/restarted."
        _run_command "Restart dbus service via systemctl" _safe_systemctl restart dbus.service
    elif command -v service &>/dev/null && service --status-all 2>&1 | grep -q 'dbus'; then
        _log "INFO" "dbus found via 'service'. Attempting restart."
        _run_command "Restart dbus service via service" service dbus restart
    else
        _log "WARN" "dbus service manager not detected or dbus not listed. If R package system dependency installation fails, ensure dbus is running."
    fi

    # Install bspm and its Python dependencies (which are system packages)
    _log "INFO" "Installing bspm R package and its system dependencies (python3-dbus, python3-gi, python3-apt) via apt from R2U..."
    # These are usually pulled in as recommends/depends of r-cran-bspm from R2U
    local bspm_system_pkgs=("r-cran-bspm" "python3-dbus" "python3-gi" "python3-apt")
    _run_command "Install r-cran-bspm and Python deps" apt-get install -y "${bspm_system_pkgs[@]}"

    # Configure Rprofile.site for bspm
    _log "INFO" "Configuring bspm options in Rprofile.site: ${R_PROFILE_SITE_PATH}"
    # Lines to add/ensure in Rprofile.site for bspm
    local bspm_rprofile_config
    # bspm.sudo = TRUE is important for bspm to be able to call 'apt' for system dependencies.
    # bspm.allow.sysreqs = TRUE allows bspm to manage system requirements.
    read -r -d '' bspm_rprofile_config << EOF
# Added by setup_r_env.sh for bspm configuration
if (nzchar(Sys.getenv("RSTUDIO_USER_IDENTITY"))) {
    # Do not run bspm::enable() in RStudio Server sessions initially,
    # as it can interfere with RStudio's own package management if not careful.
    # Users can enable it manually in their ~/.Rprofile if desired for RStudio.
    # options(bspm.enabled = FALSE) # Alternative: disable bspm in RStudio
} else if (interactive()) {
    # Potentially skip for interactive non-RStudio sessions too, or prompt.
    # For automated scripts, we want it enabled.
} else {
    # Enable bspm for non-interactive sessions (like this script's R calls)
    # and potentially for console R sessions if not RStudio.
    if (requireNamespace("bspm", quietly = TRUE)) {
        options(bspm.sudo = TRUE)
        options(bspm.allow.sysreqs = TRUE)
        bspm::enable()
        # options(bspm.MANAGES = "FALSE") # to check if it manages
    }
}
# End of bspm configuration
EOF

    # Remove existing bspm block to prevent duplication, then add the new one
    local temp_rprofile
    temp_rprofile=$(mktemp)
    # Use sed to delete the block between markers. Using a unique marker.
    sed '/# Added by setup_r_env.sh for bspm configuration/,/# End of bspm configuration/d' "$R_PROFILE_SITE_PATH" > "$temp_rprofile"
    # Append the new configuration block
    printf "\n%s\n" "$bspm_rprofile_config" >> "$temp_rprofile"
    _run_command "Update Rprofile.site with bspm configuration" mv "$temp_rprofile" "$R_PROFILE_SITE_PATH"

    _log "INFO" "Content of Rprofile.site (${R_PROFILE_SITE_PATH}) after bspm configuration:"
    cat "$R_PROFILE_SITE_PATH" >> "$LOG_FILE" # Log the content for debugging

    # Verify bspm activation
    _log "INFO" "Verifying bspm activation status..."
    local bspm_check_script="
    if (!requireNamespace('bspm', quietly=TRUE)) {
      cat('BSPM_NOT_INSTALLED\n'); quit(save='no', status=1)
    }
    # Explicitly enable for this check, mimicking non-interactive script context
    options(bspm.sudo = TRUE, bspm.allow.sysreqs = TRUE)
    if (requireNamespace('bspm', quietly=TRUE)) bspm::enable()

    # Check if bspm is managing packages
    is_managing <- tryCatch(getOption('bspm.MANAGES', FALSE), error = function(e) FALSE)
    if (is_managing) {
      cat('BSPM_MANAGING\n')
      quit(save='no', status=0)
    } else {
      cat('BSPM_NOT_MANAGING\n')
      # Try to get more info if possible
      cat('bspm::can_load():\n')
      try(print(bspm::can_load()))
      cat('bspm:::.backend:\n') # Note: accessing internal, may change
      try(print(bspm:::.backend))
      quit(save='no', status=2)
    }
    "
    local bspm_status_output
    local bspm_status_rc=0
    # Run Rscript with error suppression for the command itself, check rc and output
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
    # Set environment variables for R scripts called later by this bash script
    export BSPM_ALLOW_SYSREQS=TRUE 
    # export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1 # For older apt-key, less relevant now
}

fn_install_r_build_deps() {
    _log "INFO" "Installing common system dependencies for building R packages from source (e.g., for devtools)..."
    # This list is fairly comprehensive for common R package build needs.
    local build_deps=(
        build-essential      # Compilers, make, etc.
        libcurl4-openssl-dev # For packages needing curl (RCurl, httr, devtools)
        libssl-dev           # For SSL/TLS support
        libxml2-dev          # For XML/HTML parsing packages (XML, xml2)
        libgit2-dev          # For git operations within R (gert, devtools)
        libfontconfig1-dev   # For font handling in graphics
        libcairo2-dev        # For Cairo graphics
        libharfbuzz-dev      # For text shaping
        libfribidi-dev       # For bidirectional text
        libfreetype6-dev     # For FreeType font rendering
        libpng-dev           # For PNG image support
        libtiff5-dev         # For TIFF image support
        libjpeg-dev          # For JPEG image support
        zlib1g-dev           # Compression library
        libbz2-dev           # Bzip2 compression
        liblzma-dev          # LZMA compression (used in xz)
        libreadline-dev      # For R's command-line interface
        libicu-dev           # International Components for Unicode
        libxt-dev            # X11 Toolkit Intrinsics
        cargo                # Rust compiler, for R packages with Rust components
        # Geospatial libraries (often needed)
        libgdal-dev          # GDAL for raster/vector data
        libproj-dev          # PROJ for coordinate transformations
        libgeos-dev          # GEOS for geometry operations
        libudunits2-dev      # UDUNITS2 for units conversion (sf, stars)
    )
    # No need for sudo here if script is run as root
    _run_command "Update apt cache before installing build deps" apt-get update -y
    _run_command "Install R package build dependencies" apt-get install -y "${build_deps[@]}"
    _log "INFO" "System dependencies for R package building installed."
}

# Installs a list of R packages (either CRAN or GitHub)
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
        local pkg_name_short # Used for requireNamespace check
        local r_install_cmd

        if [[ "$pkg_type" == "CRAN" ]]; then
            pkg_name_short="$pkg_name_full" # For CRAN, full name is short name
            # R script for installing a CRAN package, trying bspm first
            # Fallback to install.packages if bspm fails or is not managing
            # Note: bspm::enable() should be in Rprofile.site for bspm to take effect
            r_install_cmd="
            pkg_short_name <- '${pkg_name_short}'
            if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                message(paste0('R package ', pkg_short_name, ' not found, attempting installation...'))
                installed_successfully <- FALSE
                if (requireNamespace('bspm', quietly = TRUE) && isTRUE(getOption('bspm.MANAGES', FALSE))) {
                    message(paste0('Attempting to install ', pkg_short_name, ' via bspm (binary)...'))
                    tryCatch({
                        bspm::install.packages(pkg_short_name, quiet = FALSE, Ncpus = parallel::detectCores(logical=FALSE) %/% 2 + 1) # Use half physical cores + 1
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
                    install.packages(pkg_short_name, repos = '${CRAN_REPO_URL_SRC}', Ncpus = parallel::detectCores(logical=FALSE) %/% 2 + 1)
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
            # For GitHub, extract short name (repo name) from "owner/repo"
            pkg_name_short=$(basename "${pkg_name_full%.git}") # Handles "owner/repo" or "owner/repo.git"
            
            if [[ -z "${GITHUB_PAT:-}" ]] && [[ "$github_pat_warning_shown" == "false" ]]; then
                _log "WARN" "GITHUB_PAT environment variable is not set. GitHub API rate limits may be encountered for installing packages like '${pkg_name_full}'. See script comments for GITHUB_PAT setup."
                github_pat_warning_shown=true # Show warning only once
            fi

            # R script for installing a GitHub package using devtools/remotes
            # Assumes devtools (or its lighter alternative remotes) is installed
            r_install_cmd="
            pkg_short_name <- '${pkg_name_short}'
            pkg_full_name <- '${pkg_name_full}'
            if (!requireNamespace('remotes', quietly = TRUE)) {
                message('remotes package not found, installing it first...')
                install.packages('remotes', repos = '${CRAN_REPO_URL_SRC}', Ncpus = parallel::detectCores(logical=FALSE) %/% 2 + 1)
                if (!requireNamespace('remotes', quietly = TRUE)) stop('Failed to install remotes package.')
            }
            if (!requireNamespace(pkg_short_name, quietly = TRUE)) {
                message(paste0('R package ', pkg_short_name, ' (from GitHub: ', pkg_full_name, ') not found, attempting installation...'))
                # Use GITHUB_PAT if set in the environment (remotes::install_github respects this)
                # Force = TRUE can be useful to ensure it tries to build even if a SHA seems current but lib is broken
                remotes::install_github(pkg_full_name, Ncpus = parallel::detectCores(logical=FALSE) %/% 2 + 1, force = TRUE, dependencies = TRUE)
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
            continue # Skip to the next package
        fi

        echo "$r_install_cmd" > "$pkg_install_script_path"
        # Use _run_command for robust execution and logging
        # Pass GITHUB_PAT if set; Rscript will inherit it if exported in bash
        if ! _run_command "Install/Verify R pkg ($pkg_type): $pkg_name_full" Rscript "$pkg_install_script_path"; then
            _log "ERROR" "Failed to install R package '${pkg_name_full}'. See R output in the log above."
            # Decide if this should be a fatal error for the whole script
            # For now, it logs error and _run_command returns non-zero, script might continue or exit based on set -e
        fi
    done
    rm -f "$pkg_install_script_path" # Clean up the temporary R script
    _log "INFO" "${pkg_type} R packages installation process completed."
}


fn_install_r_packages() {
    _log "INFO" "Starting R package installation process..."
    fn_install_r_build_deps # Ensure system build dependencies are present

    _log "INFO" "Ensuring 'devtools' and 'remotes' R packages are installed (needed for GitHub packages and useful generally)..."
    # devtools is large, remotes is a lighter alternative for install_github
    # We install both; bspm should handle them if enabled.
    local core_r_dev_pkgs=("devtools" "remotes") # Add bspm here if not installed via apt as r-cran-bspm
    
    # Temporarily disable pipefail for this Rscript call if we want to check its specific exit code for bspm
    set +o pipefail
    Rscript_out_err=$(mktemp)
    Rscript -e "
        # Use half of physical cores, default to 1 if detection fails or gives less than 2
        n_cpus <- max(1, parallel::detectCores(logical=FALSE) %/% 2)

        pkgs_to_ensure <- c(${core_r_dev_pkgs[@]/#/\"}); # Creates R vector: c(\"pkg1\", \"pkg2\")
        # Explicitly enable bspm for this script part if it's meant to be used
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
        # This could be critical, consider exiting
        # return 1
    else
        _log "INFO" "Core R development packages (devtools/remotes) are installed/verified."
    fi


    # Install CRAN packages
    _install_r_pkg_list "CRAN" "${R_PACKAGES_CRAN[@]}"

    # Install GitHub packages
    if [[ ${#R_PACKAGES_GITHUB[@]} -gt 0 ]]; then
        _log "INFO" "Installing GitHub R packages using remotes/devtools..."
        # Ensure GITHUB_PAT is exported if set, so Rscript inherits it
        [[ -n "${GITHUB_PAT:-}" ]] && export GITHUB_PAT
        _install_r_pkg_list "GitHub" "${R_PACKAGES_GITHUB[@]}"
    else
        _log "INFO" "No GitHub R packages listed for installation."
    fi

    _log "INFO" "Listing installed R packages and their installation type (bspm/binary or source)..."
    # This R script is complex; keeping it as a heredoc for self-containment.
    # Make sure it's robust.
    local r_list_pkgs_cmd_file="/tmp/list_installed_pkgs.R"
cat > "$r_list_pkgs_cmd_file" <<'EOF'
# Script to list installed R packages and attempt to determine install type
# This is heuristic and may not be 100% accurate for all cases.

get_install_type <- function(pkg_name, installed_pkgs_df) {
    # Default type
    install_type <- "source/unknown"

    # Check if it's a base or recommended package (part of R distribution)
    if (!is.na(installed_pkgs_df[pkg_name, "Priority"]) &&
        installed_pkgs_df[pkg_name, "Priority"] %in% c("base", "recommended")) {
        return("base/recommended")
    }

    # Try to get bspm info if bspm is available and managing
    if (requireNamespace("bspm", quietly = TRUE) && isTRUE(getOption("bspm.MANAGES", FALSE))) {
        bspm_pkg_info <- tryCatch(
            suppressMessages(bspm::info(pkg_name)),
            error = function(e) NULL
        )
        if (!is.null(bspm_pkg_info) && isTRUE(bspm_pkg_info$binary)) {
            install_type <- "bspm/binary"
        } else if (!is.null(bspm_pkg_info) && !is.null(bspm_pkg_info$source_available) && nzchar(bspm_pkg_info$source_available)) {
            # If bspm knows about it but says it's not binary, it might be source via bspm context
            install_type <- "bspm/source_or_other"
        }
        # If bspm provided a clear type, return it
        if (install_type != "source/unknown" && install_type != "bspm/source_or_other") return(install_type)
    }
    
    # Heuristic: Check 'Built' field for clues about source compilation vs binary
    # Example format: "R 4.3.1; ; 2023-08-01 10:00:00 UTC; unix" (binary from CRAN-like repo)
    # Example format: "R 4.3.1; x86_64-pc-linux-gnu; 2023-08-01 10:00:00 UTC; source" (compiled from source)
    built_info <- installed_pkgs_df[pkg_name, "Built"]
    if (!is.na(built_info)) {
        if (grepl("; source$", built_info, ignore.case = TRUE)) {
            install_type <- "source"
        } else if (grepl("; unix$", built_info, ignore.case = TRUE) || grepl("; windows$", built_info, ignore.case = TRUE)) {
            # This could be a pre-compiled binary (not necessarily bspm if bspm check failed/returned other)
             if (install_type == "bspm/source_or_other") {
                # If bspm thought it was source but Built field looks binary, prefer binary tag
                install_type <- "binary/pre-compiled"
             } else if (install_type == "source/unknown") {
                install_type <- "binary/pre-compiled"
             }
        }
    }
    return(install_type)
}

# Ensure bspm options are set if it's intended to be active for info() calls
if (requireNamespace("bspm", quietly = TRUE)) {
  options(bspm.sudo = TRUE, bspm.allow.sysreqs = TRUE) # These might not be strictly needed for info()
  # bspm::enable() # Might be too aggressive here, rely on Rprofile.site
}


# Get all installed packages with necessary fields
ip_fields <- c("Package", "Version", "LibPath", "Priority", "Built")
installed_pkgs_df <- as.data.frame(installed.packages(fields = ip_fields, noCache=TRUE), stringsAsFactors = FALSE) # noCache=TRUE for freshness

if (nrow(installed_pkgs_df) == 0) {
    cat("No R packages appear to be installed.\n")
} else {
    # Add an install type column
    installed_pkgs_df$InstallType <- "pending"
    rownames(installed_pkgs_df) <- installed_pkgs_df$Package # Ensure rownames are package names for easy lookup
    
    # Iterate and determine install type for each package
    for (i in seq_len(nrow(installed_pkgs_df))) {
        pkg_name <- installed_pkgs_df[i, "Package"]
        installed_pkgs_df[i, "InstallType"] <- tryCatch(
            get_install_type(pkg_name, installed_pkgs_df),
            error = function(e) "error_determining"
        )
    }
    
    # Print the formatted table
    cat(sprintf("%-30s %-16s %-20s %s\n", "Package", "Version", "InstallType", "LibPath"))
    cat(paste(rep("-", 90), collapse=""), "\n") # Adjusted width
    for (i in seq_len(nrow(installed_pkgs_df))) {
        cat(sprintf("%-30s %-16s %-20s %s\n",
                    installed_pkgs_df[i, "Package"],
                    installed_pkgs_df[i, "Version"],
                    installed_pkgs_df[i, "InstallType"],
                    installed_pkgs_df[i, "LibPath"]))
    }
}
EOF
    _log "INFO" "Executing R script to list installed packages. Output will be in the log."
    # Run the R script; its output goes to LOG_FILE via _run_command
    if ! _run_command "List installed R packages with types" Rscript "$r_list_pkgs_cmd_file"; then
        _log "WARN" "R script for listing packages encountered an error. List may be incomplete or missing."
    fi
    rm -f "$r_list_pkgs_cmd_file"
    _log "INFO" "R package installation and listing process finished."
}


fn_install_rstudio_server() {
    _log "INFO" "Installing RStudio Server v${RSTUDIO_VERSION}..."

    # Check if the correct version of RStudio Server is already installed
    if dpkg -s rstudio-server &>/dev/null; then
        current_rstudio_version=$(rstudio-server version 2>/dev/null | awk '{print $1}')
        if [[ "$current_rstudio_version" == "$RSTUDIO_VERSION" ]]; then
            _log "INFO" "RStudio Server v${RSTUDIO_VERSION} is already installed."
            if ! _safe_systemctl is-active --quiet rstudio-server; then
                _log "INFO" "RStudio Server is installed but not active. Attempting to start..."
                _run_command "Start RStudio Server" _safe_systemctl start rstudio-server
            fi
            return 0 # Already installed and checked/started
        else
            _log "INFO" "A different version of RStudio Server ('${current_rstudio_version:-unknown}') is installed. It will be removed to install v${RSTUDIO_VERSION}."
            _run_command "Stop existing RStudio Server" _safe_systemctl stop rstudio-server # Allow failure if not running
            _run_command "Purge existing RStudio Server" apt-get purge -y rstudio-server
        fi
    fi

    # Download RStudio Server .deb if it doesn't exist or if forced
    local rstudio_deb_tmp_path="/tmp/${RSTUDIO_DEB_FILENAME}"
    if [[ ! -f "$rstudio_deb_tmp_path" ]]; then
        _log "INFO" "Downloading RStudio Server .deb from ${RSTUDIO_DEB_URL} to ${rstudio_deb_tmp_path}"
        _run_command "Download RStudio Server .deb" wget -O "$rstudio_deb_tmp_path" "$RSTUDIO_DEB_URL"
    else
        _log "INFO" "RStudio Server .deb already found at ${rstudio_deb_tmp_path}. Using existing file."
    fi

    # Install RStudio Server using gdebi
    _log "INFO" "Installing RStudio Server from ${rstudio_deb_tmp_path} using gdebi..."
    if ! _run_command "Install RStudio Server via gdebi" gdebi -n "$rstudio_deb_tmp_path"; then
        _log "ERROR" "Failed to install RStudio Server using gdebi. Check log for details."
        # Consider removing the downloaded .deb if install fails and we don't want to retry with it.
        # rm -f "$rstudio_deb_tmp_path"
        return 1
    fi
    # gdebi usually handles dependencies. If not, apt-get -f install might be needed.

    _log "INFO" "Verifying RStudio Server installation and status..."
    if _safe_systemctl is-active --quiet rstudio-server; then
        _log "INFO" "RStudio Server is active after installation."
    else
        _log "WARN" "RStudio Server is not active immediately after installation. Attempting to start it..."
        if ! _run_command "Start RStudio Server (post-install)" _safe_systemctl start rstudio-server; then
            _log "ERROR" "Failed to start RStudio Server after installation. Service may be misconfigured or conflicting."
            return 1
        fi
        # Re-check status after explicit start
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

    # Combine CRAN packages and base names of GitHub packages for removal
    # Add 'bspm' here if it was installed as an R package and not r-cran-bspm
    local all_pkgs_to_remove_short_names=("${R_PACKAGES_CRAN[@]}") 
    # Note: If bspm was installed via apt (r-cran-bspm), R's remove.packages won't touch it effectively.
    # It will be removed by apt purge later.
    # all_pkgs_to_remove_short_names+=("bspm") # Only if bspm was installed via install.packages('bspm')

    for gh_pkg_full_name in "${R_PACKAGES_GITHUB[@]}"; do
        all_pkgs_to_remove_short_names+=("$(basename "${gh_pkg_full_name%.git}")")
    done

    # Get unique package names
    local unique_pkgs_to_remove_str
    unique_pkgs_to_remove_str=$(printf "%s\n" "${all_pkgs_to_remove_short_names[@]}" | sort -u | tr '\n' ' ')
    
    if [[ -z "$unique_pkgs_to_remove_str" ]]; then
        _log "INFO" "No R packages found in script lists to attempt removal."
        return
    fi

    _log "INFO" "Will attempt to remove these R packages: $unique_pkgs_to_remove_str"
    
    # Create R vector string like c("pkg1", "pkg2", "pkg3")
    local r_vector_pkgs_str="c($(echo "$unique_pkgs_to_remove_str" | sed -e "s/ /', '/g" -e "s/^/'/" -e "s/',\$//"))" # Fixed trailing comma issue
    if [[ "$r_vector_pkgs_str" == "c('')" || "$r_vector_pkgs_str" == "c()" ]]; then # Handle case of empty list after processing
        _log "INFO" "Package list for R removal script is empty. Skipping."
        return
    fi


    local r_pkg_removal_script_file="/tmp/uninstall_r_pkgs.R"
    # Quoted heredoc 'EOF' prevents Bash variable expansion inside the R script
cat > "$r_pkg_removal_script_file" <<EOF
pkgs_to_attempt_removal <- ${r_vector_pkgs_str}
installed_pkgs_matrix <- installed.packages(noCache=TRUE) # Use noCache for freshness

if (is.null(installed_pkgs_matrix) || nrow(installed_pkgs_matrix) == 0) {
    cat("No R packages are currently installed according to installed.packages().\n")
} else {
    # Get vector of names of currently installed packages
    current_installed_pkgs_vec <- installed_pkgs_matrix[, "Package"]
    
    # Find which of our target packages are actually installed
    pkgs_that_exist_and_targeted_for_removal <- intersect(pkgs_to_attempt_removal, current_installed_pkgs_vec)
    
    if (length(pkgs_that_exist_and_targeted_for_removal) > 0) {
        cat("The following R packages will be targeted for removal:\n", paste(pkgs_that_exist_and_targeted_for_removal, collapse = ", "), "\n")
        # Suppress warnings during removal, as some might be about dependencies
        # This removes packages from all libraries they are found in.
        suppressWarnings(remove.packages(pkgs_that_exist_and_targeted_for_removal))
        cat("Attempted removal of specified R packages finished.\n")
        
        # Verify removal
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
    # Run the R removal script, logging its output
    ( Rscript "$r_pkg_removal_script_file" >>"$LOG_FILE" 2>&1 ) || r_removal_rc=$?
    rm -f "$r_pkg_removal_script_file" # Clean up

    if [[ $r_removal_rc -eq 0 ]]; then
        _log "INFO" "R package uninstallation script completed successfully."
    else
        _log "WARN" "R package uninstallation script finished with errors (Rscript Exit Code: $r_removal_rc). Check log for details."
        # This is not necessarily fatal for the overall uninstall process.
    fi
    _log "INFO" "R package uninstallation attempt finished."
}


fn_remove_bspm_config() {
    _log "INFO" "Removing bspm configuration from Rprofile.site and R2U apt repository..."
    _get_r_profile_site_path # Ensure R_PROFILE_SITE_PATH is determined

    if [[ -n "$R_PROFILE_SITE_PATH" && (-f "$R_PROFILE_SITE_PATH" || -L "$R_PROFILE_SITE_PATH") ]]; then
        _log "INFO" "Removing bspm configuration lines from '${R_PROFILE_SITE_PATH}'."
        _backup_file "$R_PROFILE_SITE_PATH" # Backup before modifying

        local temp_rprofile_cleaned
        temp_rprofile_cleaned=$(mktemp)

        # Use sed to delete the block between the specific markers used during setup
        # This is more robust than grepping individual lines if the block structure is consistent.
        sed '/# Added by setup_r_env.sh for bspm configuration/,/# End of bspm configuration/d' "$R_PROFILE_SITE_PATH" > "$temp_rprofile_cleaned"
        
        # Check if the file content actually changed to avoid unnecessary mv
        if ! cmp -s "$R_PROFILE_SITE_PATH" "$temp_rprofile_cleaned"; then
            if _run_command "Update Rprofile.site (remove bspm block)" mv "$temp_rprofile_cleaned" "$R_PROFILE_SITE_PATH"; then
                 _log "INFO" "Removed bspm configuration block from '${R_PROFILE_SITE_PATH}'."
            else
                _log "ERROR" "Failed to update Rprofile.site after attempting to remove bspm block. Restoring backup."
                _restore_latest_backup "$R_PROFILE_SITE_PATH" # Attempt to restore if mv failed
                # If mv failed, temp_rprofile_cleaned might still exist; remove it.
                rm -f "$temp_rprofile_cleaned"
            fi
        else
            _log "INFO" "No bspm configuration block (matching markers) found in '${R_PROFILE_SITE_PATH}', or file was unchanged. Cleaning up temporary file."
            rm -f "$temp_rprofile_cleaned"
        fi
        # Optionally, restore the very original Rprofile.site if this script made backups at multiple stages
        # _restore_latest_backup "$R_PROFILE_SITE_PATH" # This would restore the version before *any* of this script's bspm changes
    else
        _log "INFO" "Rprofile.site ('${R_PROFILE_SITE_PATH:-not set or found}') not found or path not determined. Skipping bspm configuration removal from it."
    fi

    _log "INFO" "Removing R2U apt repository configuration..."
    local r2u_apt_pattern="r2u.stat.illinois.edu" # Key part of the R2U repo URL

    # Remove the specific R2U sources list file if it exists
    if [[ -f "$R2U_APT_SOURCES_LIST_D_FILE" ]]; then
        _log "INFO" "Removing R2U repository file: '${R2U_APT_SOURCES_LIST_D_FILE}'."
        _run_command "Remove R2U sources file '${R2U_APT_SOURCES_LIST_D_FILE}'" rm -f "$R2U_APT_SOURCES_LIST_D_FILE"
    fi

    # Search and remove R2U entries from other apt sources files (more general cleanup)
    # Using find -print0 and while read -d for safe filename handling
    find /etc/apt/sources.list /etc/apt/sources.list.d/ -type f -name '*.list' -print0 | \
    while IFS= read -r -d $'\0' apt_list_file; do
        if grep -q "$r2u_apt_pattern" "$apt_list_file"; then
            _log "INFO" "R2U entry found in '${apt_list_file}'. Backing up and removing entry."
            _backup_file "$apt_list_file" # Backup before modifying
            # Use sed to delete lines containing the pattern. Create a .r2u_removed_bak for sed's backup.
            _run_command "Remove R2U entry from '${apt_list_file}'" sed -i.r2u_removed_bak "/${r2u_apt_pattern}/d" "$apt_list_file"
        fi
    done
    # Also remove R2U GPG key if it was added separately (R2U script might handle this)
    # Example: find /etc/apt/keyrings/ -name "*r2u*" -o -name "*eddelbuettel*" -type f -delete
    # For now, rely on apt purge of r-cran-bspm and removal of its source list. The R2U setup script should place its key in /etc/apt/keyrings
    local r2u_keyring_pattern="r2u-cran-archive-keyring.gpg" # Common name for R2U keyring
    find /etc/apt/keyrings/ -name "$r2u_keyring_pattern" -type f -print0 | while IFS= read -r -d $'\0' key_file; do
        _log "INFO" "Removing R2U GPG keyring file: '$key_file'"
        _run_command "Remove R2U GPG keyring '$key_file'" rm -f "$key_file"
    done

    _log "INFO" "R2U apt repository configuration removal process finished."
    _log "INFO" "Consider running 'apt-get update' after these changes."
}


fn_remove_cran_repo() {
    _log "INFO" "Removing this script's CRAN apt repository configuration..."
    
    # Escape special characters in the CRAN repo URL and codename for sed/grep
    # This pattern specifically targets the line added by this script.
    local cran_line_pattern_escaped
    # Example CRAN_REPO_LINE: deb [signed-by=/etc/apt/keyrings/cran-KEYID.gpg] https://url /bin/linux/ubuntu codename-cran40/
    # We need a robust way to identify it. Using the signed-by part and cran40 is a good bet.
    cran_line_pattern_escaped=$(printf '%s' "${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME}-cran40/" | sed 's|[&/\]|\[]|\\&|g')
    local signed_by_pattern_escaped
    signed_by_pattern_escaped=$(printf '%s' "[signed-by=${CRAN_APT_KEYRING_FILE}]" | sed 's|[&/\]|\[]|\\&|g')

    find /etc/apt/sources.list /etc/apt/sources.list.d/ -type f -name '*.list' -print0 | \
    while IFS= read -r -d $'\0' apt_list_file; do
        # Match lines containing both the signed-by attribute and the specific CRAN URL part
        if grep -qE "^\s*deb\s+${signed_by_pattern_escaped}\s+.*${cran_line_pattern_escaped}" "$apt_list_file"; then
            _log "INFO" "CRAN repository entry (matching this script's format) found in '${apt_list_file}'. Backing up and removing."
            _backup_file "$apt_list_file"
            # Create a .cran_removed_bak for sed's backup
            _run_command "Remove CRAN entry from '${apt_list_file}'" sed -i.cran_removed_bak "\#^\s*deb\s+${signed_by_pattern_escaped}\s+.*${cran_line_pattern_escaped}#d" "$apt_list_file"
        fi
    done

    _log "INFO" "Removing CRAN GPG key file '${CRAN_APT_KEYRING_FILE}'..."
    if [[ -f "$CRAN_APT_KEYRING_FILE" ]]; then
        _run_command "Remove CRAN GPG key file '${CRAN_APT_KEYRING_FILE}'" rm -f "$CRAN_APT_KEYRING_FILE"
    else
        _log "INFO" "CRAN GPG key file '${CRAN_APT_KEYRING_FILE}' not found. Already removed or was never added by this script."
    fi
    
    _log "INFO" "CRAN apt repository configuration removal finished."
    _log "INFO" "Consider running 'apt-get update' after these changes."
}


fn_uninstall_system_packages() {
    _log "INFO" "Uninstalling system packages installed by this script (RStudio Server, R, OpenBLAS, OpenMP, bspm)..."

    # RStudio Server
    if dpkg -s rstudio-server &>/dev/null; then
        _log "INFO" "Stopping and purging RStudio Server..."
        _run_command "Stop RStudio Server" _safe_systemctl stop rstudio-server # Allow failure if not running
        _run_command "Disable RStudio Server from boot" _safe_systemctl disable rstudio-server # Allow failure
        _run_command "Purge RStudio Server package" apt-get purge -y rstudio-server
    else
        _log "INFO" "RStudio Server package (rstudio-server) not found, or already removed."
    fi

    # R, OpenBLAS, OpenMP, bspm (via apt), and other script dependencies
    # List packages that this script might have installed directly via apt-get install
    local pkgs_to_purge=(
        "r-base" "r-base-dev" "r-base-core"             # R components
        "r-cran-bspm"                                  # BSPM via apt (from R2U)
        "python3-dbus" "python3-gi" "python3-apt"      # BSPM dependencies
        "libopenblas-dev" "libomp-dev"                 # BLAS/OpenMP
        "gdebi-core" "software-properties-common"       # Script helper tools
        # Add other specific system build deps if they are *only* for this script's purpose
        # This list should mirror build deps installed in fn_install_r_build_deps if they are not expected to be shared
        # For safety, only list those that are highly specific or less common system utilities.
        # Example: "cargo" if only needed for R packages by this script.
        # More common ones like libcurl4-openssl-dev are often used by many things.
        # For a truly clean system, one might list more, but risk breaking other software.
    )
    # Filter the list to only include packages that are actually installed
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

    # Define an array of paths commonly associated with R and RStudio Server installations.
    # Be cautious with system-level directories if R was installed from distro repos initially.
    # Paths here are more for custom/source installs or this script's managed components.
    declare -a paths_to_remove=(
        # R paths (especially if compiled from source or installed to /usr/local)
        "/usr/local/lib/R"          # Common for source installs of R
        "/usr/local/bin/R"          # Symlink or binary for source R
        "/usr/local/bin/Rscript"    # Symlink or binary for source Rscript
        # RStudio Server specific data/run directories
        "/var/lib/rstudio-server"   # RStudio Server data directory
        "/var/run/rstudio-server"   # RStudio Server runtime PID/socket files
        "/etc/rstudio"              # RStudio Server global config (usually removed by purge, but check)
    )

    # /etc/R is tricky. If r-base was from Ubuntu repos, it's owned by that package.
    # If this script installed R from CRAN repo, then purging r-base should handle /usr/lib/R and parts of /etc/R.
    # Only remove /etc/R if we are sure no system package owns it.
    if [[ -d "/etc/R" ]]; then
        # Check if /etc/R or its contents are owned by any installed package
        if dpkg-query -S "/etc/R" >/dev/null 2>&1 || dpkg-query -S "/etc/R/*" >/dev/null 2>&1; then
            _log "INFO" "Directory '/etc/R' or its contents appear to be owned by an installed package. Skipping its direct removal. 'apt purge r-base' should handle it if appropriate."
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

    # Remove downloaded RStudio .deb file from /tmp
    # RSTUDIO_DEB_FILENAME should be set from pre_flight_checks or fn_get_latest_rstudio_info
    if [[ -n "${RSTUDIO_DEB_FILENAME:-}" && -f "/tmp/${RSTUDIO_DEB_FILENAME}" ]]; then
        _log "INFO" "Removing downloaded RStudio Server .deb file: '/tmp/${RSTUDIO_DEB_FILENAME}'"
        rm -f "/tmp/${RSTUDIO_DEB_FILENAME}"
    else
        _log "INFO" "No RStudio .deb file matching known filename found in /tmp, or RSTUDIO_DEB_FILENAME not set."
    fi

    # Aggressive user-level cleanup (optional and interactive by default)
    local is_interactive_shell=false
    if [[ -t 0 && -t 1 ]]; then # Check if stdin and stdout are connected to a terminal
        is_interactive_shell=true
    fi
    # Allow overriding prompt via environment variable (e.g., for automated full cleanup)
    local prompt_for_aggressive_cleanup="${PROMPT_AGGRESSIVE_CLEANUP_ENV:-yes}" 

    if [[ "${FORCE_USER_CLEANUP:-no}" == "yes" ]] || \
       ( "$is_interactive_shell" == "true" && "$prompt_for_aggressive_cleanup" == "yes" ); then
        
        local perform_aggressive_user_cleanup=false
        if [[ "${FORCE_USER_CLEANUP:-no}" == "yes" ]]; then
            _log "INFO" "FORCE_USER_CLEANUP is 'yes'. Proceeding with aggressive user-level R data removal."
            perform_aggressive_user_cleanup=true
        elif $is_interactive_shell; then # Only prompt if truly interactive
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
            # Find user home directories (UID >= 1000, non-system users)
            awk -F: '$3 >= 1000 && $3 < 60000 && $6 != "" && $6 != "/nonexistent" && $6 != "/" {print $6}' /etc/passwd | while IFS= read -r user_home_dir; do
                if [[ -d "$user_home_dir" ]]; then 
                    _log "INFO" "Scanning user home directory for R data: '${user_home_dir}'"
                    # Define patterns of R-related files/dirs in user homes
                    # Be careful not to make these too broad (e.g., avoid simple "R*")
                    declare -a user_r_data_paths=(
                        "${user_home_dir}/.R"
                        "${user_home_dir}/.RData"
                        "${user_home_dir}/.Rhistory"
                        "${user_home_dir}/.Rprofile"
                        "${user_home_dir}/.Renviron"
                        "${user_home_dir}/R" # Common directory for user R libraries (e.g., R/x86_64-pc-linux-gnu-library/version)
                        "${user_home_dir}/.config/R"
                        "${user_home_dir}/.config/rstudio"
                        "${user_home_dir}/.cache/R"
                        "${user_home_dir}/.cache/rstudio"
                        "${user_home_dir}/.local/share/rstudio"
                        "${user_home_dir}/.local/share/renv" # renv project manager
                        # Add other common user-specific R tool paths if known
                    )
                    for r_path_to_check in "${user_r_data_paths[@]}"; do
                        if [[ -e "$r_path_to_check" ]]; then # -e checks for file, dir, or symlink
                            _log "WARN" "Aggressive Cleanup: Removing '${r_path_to_check}'"
                            # Safety check: ensure we are not deleting the home directory itself or a top-level system dir
                            if [[ "$r_path_to_check" != "$user_home_dir" && "$r_path_to_check" == "$user_home_dir/"* ]]; then
                                _run_command "Aggressively remove user R path '${r_path_to_check}'" rm -rf "$r_path_to_check"
                            else
                                _log "ERROR" "Safety break: Skipped removing suspicious path '${r_path_to_check}' (not clearly under user home '${user_home_dir}'). This should not happen with current patterns."
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
        _log "INFO" "Skipping aggressive user-level R data cleanup. (FORCE_USER_CLEANUP not 'yes', or not an interactive shell, or user declined prompt)."
    fi
    _log "INFO" "Leftover file and directory removal process finished."
}


# --- Main Execution ---
install_all() {
    _log "INFO" "--- Starting Full R Environment Installation ---"
    
    fn_pre_flight_checks
    fn_add_cran_repo
    fn_install_r
    fn_install_openblas_openmp
    
    if ! fn_verify_openblas_openmp; then 
        _log "WARN" "OpenBLAS/OpenMP verification encountered issues or failed. Installation will continue, but performance or stability might be affected. Review logs carefully."
        # Depending on policy, you might want to make this fatal: # exit 1
    else
        _log "INFO" "OpenBLAS/OpenMP verification passed."
    fi
    
    if ! fn_setup_bspm; then 
        _log "ERROR" "BSPM (R2U Binary Package Manager) setup failed. Subsequent R package installations might not use bspm correctly (falling back to source builds) or could encounter further issues."
        # This is a significant issue. Consider if it should be fatal.
        # For now, we'll let it continue, but R package installs will be slower (source) and might miss system deps.
        # return 1 # Uncomment to make bspm failure fatal for install_all
    else
        _log "INFO" "BSPM setup appears successful."
    fi
    
    fn_install_r_packages # This will use bspm if successfully set up
    fn_install_rstudio_server
    
    _log "INFO" "--- Full R Environment Installation Completed ---"
    _log "INFO" "Summary:"
    _log "INFO" "- R version: $(R --version | head -n 1 || echo 'Not found')"
    _log "INFO" "- RStudio Server version: $(rstudio-server version 2>/dev/null || echo 'Not found/not running')"
    _log "INFO" "- RStudio Server URL: http://<YOUR_SERVER_IP>:8787 (if not firewalled)"
    _log "INFO" "- BSPM status: Check logs from fn_setup_bspm and fn_install_r_packages."
    _log "INFO" "- Main log file for this session: ${LOG_FILE}"
}

uninstall_all() {
    _log "INFO" "--- Starting Full R Environment Uninstallation ---"
    _ensure_root # Uninstall actions also require root

    # Determine R_PROFILE_SITE_PATH early for bspm config removal, even if R is already gone.
    # This relies on the script's knowledge of where it *would* place/find it.
    _get_r_profile_site_path

    fn_uninstall_r_packages      # Remove R packages installed by this script
    fn_remove_bspm_config        # Remove bspm entries from Rprofile.site and R2U apt sources
    fn_uninstall_system_packages # Purge R, RStudio, OpenBLAS, BSPM apt package, etc.
    fn_remove_cran_repo          # Remove CRAN apt sources added by this script
    fn_remove_leftover_files     # Clean up miscellaneous files/dirs, optionally user data

    _log "INFO" "--- Verification of Uninstallation ---"
    local verification_issues_found=0
    
    # Check for common commands
    if command -v R &>/dev/null; then _log "WARN" "VERIFICATION FAIL: 'R' command still found."; ((verification_issues_found++)); else _log "INFO" "VERIFICATION OK: 'R' command not found."; fi
    if command -v Rscript &>/dev/null; then _log "WARN" "VERIFICATION FAIL: 'Rscript' command still found."; ((verification_issues_found++)); else _log "INFO" "VERIFICATION OK: 'Rscript' command not found."; fi
    if command -v rstudio-server &>/dev/null; then _log "WARN" "VERIFICATION FAIL: 'rstudio-server' command still found."; ((verification_issues_found++)); fi # No else needed if dpkg check is next

    # Check for key packages
    local pkgs_to_check_absent=("rstudio-server" "r-base" "r-cran-bspm" "libopenblas-dev" "libomp-dev")
    for pkg_check in "${pkgs_to_check_absent[@]}"; do
        if dpkg -s "$pkg_check" &>/dev/null; then
            _log "WARN" "VERIFICATION FAIL: Package '$pkg_check' is still installed."
            ((verification_issues_found++))
        else
            _log "INFO" "VERIFICATION OK: Package '$pkg_check' is not installed."
        fi
    done

    # Check for apt sources (visual check of log for fn_remove_bspm_config / fn_remove_cran_repo output)
    _log "INFO" "VERIFICATION: Check logs from 'fn_remove_bspm_config' and 'fn_remove_cran_repo' to confirm apt sources were removed."
    # Add more specific checks if desired, e.g., grep for the repo URLs in /etc/apt/

    if [[ $verification_issues_found -eq 0 ]]; then
        _log "INFO" "--- Full R Environment Uninstallation Completed Successfully (based on checks) ---"
    else
        _log "ERROR" "--- Full R Environment Uninstallation Completed with ${verification_issues_found} verification issue(s). ---"
        _log "ERROR" "Manual inspection of the system and the log file ('${LOG_FILE}') is recommended to ensure complete removal."
    fi
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
    echo "  fn_pre_flight_checks, fn_add_cran_repo, fn_install_r, fn_install_openblas_openmp"
    echo "  fn_verify_openblas_openmp, fn_setup_bspm, fn_install_r_packages, fn_install_rstudio_server"
    # Removed fn_set_r_profile_path_interactive and toggle_aggressive_cleanup as direct callables for simplicity, use env vars or menu.
    echo ""
    echo "Log file for this session will be in: ${LOG_DIR}/r_setup_YYYYMMDD_HHMMSS.log"
    exit 1
}

interactive_menu() {
    _ensure_root
    # Initial call to determine paths for display, will be updated if R is installed.
    # fn_pre_flight_checks might be better here if it sets UBUNTU_CODENAME etc. for RStudio version display.
    # However, pre-flight can be long. For now, just get Rprofile path.
    _get_r_profile_site_path

    while true; do
        # Refresh RStudio version info for menu display, requires UBUNTU_CODENAME and RSTUDIO_ARCH
        # This might be slightly off if pre-flight hasn't run yet to detect them fully.
        local display_rstudio_version="$RSTUDIO_VERSION_FALLBACK" # Default
        if [[ -n "${UBUNTU_CODENAME:-}" && -n "${RSTUDIO_ARCH:-}" ]]; then
            # Construct a temporary RStudio version string for display
            # This doesn't call the full fn_get_latest_rstudio_info to avoid network calls in menu loop
            if [[ -n "$RSTUDIO_VERSION" && "$RSTUDIO_VERSION" != "$RSTUDIO_VERSION_FALLBACK" ]]; then
                display_rstudio_version="$RSTUDIO_VERSION (Detected/Set)"
            fi
        else
            display_rstudio_version="$RSTUDIO_VERSION_FALLBACK (Codename/Arch not yet set by pre-flight)"
        fi


        echo ""
        echo "================ R Environment Setup Menu ================"
        echo "Log File: ${LOG_FILE}"
        echo "Ubuntu Codename: ${UBUNTU_CODENAME:-Not yet detected}"
        echo "System Architecture: ${RSTUDIO_ARCH:-Not yet detected}"
        echo "Rprofile.site for bspm: ${R_PROFILE_SITE_PATH:-Not yet determined/set}"
        echo "RStudio Server version (target): ${display_rstudio_version}"
        echo "------------------------------------------------------------"
        echo " Installation Steps:"
        echo "  1. Full Installation (all steps below)"
        echo "  2. Pre-flight Checks (detect OS, arch, install script deps)"
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
        
        # Optional: `clear` screen after input, or leave history for review
        # clear 

        case "$option" in
            1) install_all ;;
            2) fn_pre_flight_checks ;;
            3) fn_pre_flight_checks; fn_add_cran_repo; fn_install_r ;; # Sensible chain
            4) fn_pre_flight_checks; fn_install_openblas_openmp ;; # Depends on pre-flight for apt
            5) fn_pre_flight_checks; fn_install_r; fn_install_openblas_openmp; fn_verify_openblas_openmp ;; # Full chain for verification
            6) fn_pre_flight_checks; fn_install_r; fn_setup_bspm ;; # BSPM needs R and system info
            7) fn_pre_flight_checks; fn_install_r; fn_setup_bspm; fn_install_r_packages ;; # Pkgs need R, BSPM, build deps
            8) fn_pre_flight_checks; fn_install_r; fn_install_rstudio_server ;; # RStudio needs R
            
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
        # Optional: `clear` screen before showing menu again
        # clear
    done
}

main() {
    # Ensure log file is available from the very start
    # Handled by global variable definitions now

    _log "INFO" "Script execution started. Logging to: ${LOG_FILE}"
    # Initial determination of Rprofile.site path, might be refined later
    _get_r_profile_site_path 

    if [[ $# -eq 0 ]]; then
        # No arguments, show interactive menu
        _log "INFO" "No action specified, entering interactive menu."
        interactive_menu
    else
        # Action argument provided
        _ensure_root # Most direct actions also require root
        local action_arg="$1"
        shift # Remove the action from arguments, pass rest to function if needed
        
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
            # Expose individual functions if truly needed for non-interactive scripting
            # Be cautious, as these might have implicit dependencies on prior steps.
            fn_pre_flight_checks|fn_add_cran_repo|fn_install_r|fn_install_openblas_openmp|\
            fn_verify_openblas_openmp|fn_setup_bspm|fn_install_r_packages|fn_install_rstudio_server|\
            fn_uninstall_r_packages|fn_remove_bspm_config|fn_uninstall_system_packages|fn_remove_cran_repo|fn_remove_leftover_files)
                target_function_name="$action_arg"
                _log "INFO" "Directly invoking function: ${target_function_name}"
                ;;
            # toggle_aggressive_cleanup could be a simple script utility
            toggle_aggressive_cleanup)
                if [[ "$FORCE_USER_CLEANUP" == "yes" ]]; then
                    FORCE_USER_CLEANUP="no"
                    _log "INFO" "Aggressive user data cleanup (FORCE_USER_CLEANUP) set to 'no'."
                else
                    FORCE_USER_CLEANUP="yes"
                    _log "INFO" "Aggressive user data cleanup (FORCE_USER_CLEANUP) set to 'yes'."
                fi
                echo "FORCE_USER_CLEANUP is now: $FORCE_USER_CLEANUP" # Output for scripting
                _log "INFO" "Script finished after toggling FORCE_USER_CLEANUP."
                exit 0
                ;;
            *)
                _log "ERROR" "Unknown direct action: '$action_arg'."
                _log "ERROR" "Run without arguments for interactive menu, or use a valid action like 'install_all' or 'uninstall_all'."
                usage # Display usage information and exit
                ;;
        esac
        
        # Check if the determined target function actually exists
        if declare -f "$target_function_name" >/dev/null; then
            # Call the target function, passing any remaining arguments
            "$target_function_name" "$@" 
        else 
            _log "ERROR" "Internal script error: Target function '${target_function_name}' for action '${action_arg}' is not defined or not callable."
            usage
        fi
    fi
    _log "INFO" "Script execution finished."
}

# Call main function with all script arguments
main "$@"
