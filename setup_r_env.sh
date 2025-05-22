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

LOG_DIR="/var/log/r_setup"
LOG_FILE="${LOG_DIR}/r_setup_$(date +'%Y%m%d_%H%M%S').log"
mkdir -p "$LOG_DIR"; touch "$LOG_FILE"; chmod 640 "$LOG_FILE"
BACKUP_DIR="/opt/r_setup_backups"; mkdir -p "$BACKUP_DIR"

UBUNTU_CODENAME_DETECTED=$(lsb_release -cs 2>/dev/null || echo "unknown")
UBUNTU_CODENAME="$UBUNTU_CODENAME_DETECTED"
R_PROFILE_SITE_PATH=""
USER_SPECIFIED_R_PROFILE_SITE_PATH=""
FORCE_USER_CLEANUP="no"

RSTUDIO_VERSION_FALLBACK="2023.12.1-402"
RSTUDIO_ARCH_FALLBACK="amd64"
RSTUDIO_ARCH="${RSTUDIO_ARCH_FALLBACK}"
RSTUDIO_VERSION="$RSTUDIO_VERSION_FALLBACK"
RSTUDIO_DEB_URL="https://download2.rstudio.org/server/${UBUNTU_CODENAME_DETECTED:-bionic}/${RSTUDIO_ARCH}/rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
RSTUDIO_DEB_FILENAME="rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"

CRAN_REPO_URL_BASE="https://cloud.r-project.org"
CRAN_REPO_PATH_BIN="/bin/linux/ubuntu"
CRAN_REPO_PATH_SRC="/src/contrib"
CRAN_REPO_URL_BIN="${CRAN_REPO_URL_BASE}${CRAN_REPO_PATH_BIN}"
CRAN_REPO_URL_SRC="${CRAN_REPO_URL_BASE}${CRAN_REPO_PATH_SRC}"
CRAN_REPO_LINE="deb ${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME_DETECTED:-bionic}-cran40/"
CRAN_APT_KEY_ID="E298A3A825C0D65DFD57CBB651716619E084DAB9"

R2U_REPO_URL_BASE="https://raw.githubusercontent.com/eddelbuettel/r2u/master/inst/scripts"
R2U_APT_SOURCES_LIST_D_FILE="/etc/apt/sources.list.d/r2u.list"

R_PACKAGES_CRAN=(
    "terra" "raster" "sf" "enmSdmX" "dismo" "spThin" "rnaturalearth" "furrr"
    "doParallel" "future" "caret" "CoordinateCleaner" "tictoc" "devtools"
    "tidyverse" "dplyr" "spatstat" "ggplot2" "iNEXT" "DHARMa" "lme4" "glmmTMB"
    "geodata" "osmdata" "parallel" "doSNOW" "progress" "nngeo" "wdpar" "rgee" "tidyrgee"
    "data.table"
)
R_PACKAGES_GITHUB=(
    "SantanderMetGroup/transformeR"
    "SantanderMetGroup/mopa"
    "HelgeJentsch/ClimDatDownloadR"
)

if [[ -n "${CUSTOM_R_PROFILE_SITE_PATH_ENV:-}" ]]; then
    USER_SPECIFIED_R_PROFILE_SITE_PATH="${CUSTOM_R_PROFILE_SITE_PATH_ENV}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Rprofile.site path from env: ${USER_SPECIFIED_R_PROFILE_SITE_PATH}" | tee -a "$LOG_FILE"
fi

_log() { local type="$1"; local message="$2"; echo "$(date '+%Y-%m-%d %H:%M:%S') [${type}] ${message}" | tee -a "$LOG_FILE";}
_ensure_root() { if [[ "${EUID}" -ne 0 ]]; then _log "ERROR" "Run as root/sudo."; exit 1; fi; }


# Wrapper for systemctl that ignores errors in CI/container
_safe_systemctl() {
    if command -v systemctl >/dev/null 2>&1; then
        # Avoid --global (not supported in most containers)
        systemctl "$@" 2>&1 | tee -a "$LOG_FILE" || return 0
    fi
    return 0
}

_run_command() {
    local cmd_desc="$1"; shift
    _log "INFO" "Start: $cmd_desc"
    if ( "$@" >>"$LOG_FILE" 2>&1 ); then
        _log "INFO" "OK: $cmd_desc"; return 0
    else
        local exit_code=$?
        _log "ERROR" "FAIL: $cmd_desc (RC:$exit_code). See log: $LOG_FILE"
        if [ -f "$LOG_FILE" ]; then tail -n 7 "$LOG_FILE" | sed 's/^/    /'; fi
        return $exit_code
    fi
}

_backup_file() { local fp="$1"; if [[ -f "$fp" || -L "$fp" ]]; then local bn; bn="$(basename "$fp")_$(date +'%Y%m%d%H%M%S').bak"; cp -a "$fp" "${BACKUP_DIR}/${bn}"; fi; }
_restore_latest_backup() { local orig_fp="$1"; local fn_pat; local latest_bkp; fn_pat="$(basename "$orig_fp")_*.bak"; latest_bkp=$(find "$BACKUP_DIR" -name "$fn_pat" -print0|xargs -0 ls -1tr 2>/dev/null | tail -n 1); if [[ -n "$latest_bkp" && -f "$latest_bkp" ]]; then cp -a "$latest_bkp" "$orig_fp"; fi; }

_get_r_profile_site_path() {
    if [[ -n "$USER_SPECIFIED_R_PROFILE_SITE_PATH" ]]; then
        R_PROFILE_SITE_PATH="$USER_SPECIFIED_R_PROFILE_SITE_PATH"
        return
    fi
    if command -v R &>/dev/null; then
        local r_h_o; r_h_o=$(R RHOME 2>/dev/null||echo ""); if [[ -n "$r_h_o" && -d "$r_h_o" ]]; then R_PROFILE_SITE_PATH="${r_h_o}/etc/Rprofile.site"; return; fi
    fi
    [[ -f "/usr/lib/R/etc/Rprofile.site" ]] && R_PROFILE_SITE_PATH="/usr/lib/R/etc/Rprofile.site" && return
    [[ -f "/usr/local/lib/R/etc/Rprofile.site" ]] && R_PROFILE_SITE_PATH="/usr/local/lib/R/etc/Rprofile.site" && return
    R_PROFILE_SITE_PATH="/usr/lib/R/etc/Rprofile.site"
}

fn_get_latest_rstudio_info() {
    _log "INFO" "Attempting to detect latest RStudio Server for ${UBUNTU_CODENAME} ${RSTUDIO_ARCH}..."
    local download_page_content="" latest_url="" temp_version=""

    local current_rstudio_version="$RSTUDIO_VERSION"
    local current_rstudio_deb_url="$RSTUDIO_DEB_URL"
    local current_rstudio_deb_filename="$RSTUDIO_DEB_FILENAME"

    if [[ -z "$UBUNTU_CODENAME" || "$UBUNTU_CODENAME" == "unknown" ]]; then
        _log "WARN" "UBUNTU_CODENAME invalid for RStudio detection. Using fallback version: ${current_rstudio_version}"
        RSTUDIO_VERSION="$current_rstudio_version"
        RSTUDIO_DEB_URL="$current_rstudio_deb_url"
        RSTUDIO_DEB_FILENAME="$current_rstudio_deb_filename"
        return
    fi
    if [[ -z "$RSTUDIO_ARCH" ]]; then
        _log "WARN" "RSTUDIO_ARCH invalid. Using fallback version: ${current_rstudio_version}"
        RSTUDIO_VERSION="$current_rstudio_version"
        RSTUDIO_DEB_URL="$current_rstudio_deb_url"
        RSTUDIO_DEB_FILENAME="$current_rstudio_deb_filename"
        return
    fi

    _log "INFO" "Fetching RStudio download page..."
    download_page_content=$(curl --fail --location --connect-timeout 15 -sS "https://posit.co/download/rstudio-server/")
    if [[ -z "$download_page_content" ]]; then
        _log "WARN" "RStudio download page empty. Using fallback version: ${current_rstudio_version}"
        RSTUDIO_VERSION="$current_rstudio_version"
        RSTUDIO_DEB_URL="$current_rstudio_deb_url"
        RSTUDIO_DEB_FILENAME="$current_rstudio_deb_filename"
        return
    fi

    grep_output=$(echo "$download_page_content" | grep -Eo "https://download[0-9]*\.rstudio\.org/server/${UBUNTU_CODENAME}/${RSTUDIO_ARCH}/rstudio-server-([0-9A-Za-z._-]+)-${RSTUDIO_ARCH}\.deb" | head -n 1)

    if [[ -z "$grep_output" ]]; then
        _log "WARN" "Could not find a RStudio Server .deb URL for ${UBUNTU_CODENAME}/${RSTUDIO_ARCH} on the download page. Falling back to default version."
        _log "DEBUG" "First 20 lines of RStudio download page for debugging:"
        echo "$download_page_content" | head -20 | tee -a "$LOG_FILE"
        RSTUDIO_VERSION="$current_rstudio_version"
        RSTUDIO_DEB_URL="$current_rstudio_deb_url"
        RSTUDIO_DEB_FILENAME="$current_rstudio_deb_filename"
        return
    fi

    latest_url="$grep_output"
    if [[ -n "$latest_url" ]]; then
        _log "INFO" "Found RStudio Server URL: ${latest_url}"
        local RSTUDIO_DEB_URL_DETECTED="$latest_url"
        local RSTUDIO_DEB_FILENAME_DETECTED; RSTUDIO_DEB_FILENAME_DETECTED=$(basename "$RSTUDIO_DEB_URL_DETECTED")
        temp_version=${RSTUDIO_DEB_FILENAME_DETECTED#"rstudio-server-"}
        local RSTUDIO_VERSION_DETECTED; RSTUDIO_VERSION_DETECTED=${temp_version%"-${RSTUDIO_ARCH}.deb"}

        if [[ -n "$RSTUDIO_VERSION_DETECTED" ]]; then
            _log "INFO" "Auto-detected RStudio Server version: ${RSTUDIO_VERSION_DETECTED}"
            RSTUDIO_VERSION="$RSTUDIO_VERSION_DETECTED"
            RSTUDIO_DEB_URL="$RSTUDIO_DEB_URL_DETECTED"
            RSTUDIO_DEB_FILENAME="$RSTUDIO_DEB_FILENAME_DETECTED"
            return
        else
            _log "WARN" "Could not parse version from detected URL '${latest_url}'. Using fallback version: ${current_rstudio_version}"
        fi
    else
        _log "WARN" "Could not auto-detect RStudio URL for ${UBUNTU_CODENAME} ${RSTUDIO_ARCH}. Using fallback version: ${current_rstudio_version}"
    fi

    # Fallback in all error cases
    RSTUDIO_VERSION="$current_rstudio_version"
    RSTUDIO_DEB_URL="$current_rstudio_deb_url"
    RSTUDIO_DEB_FILENAME="$current_rstudio_deb_filename"
}

# --- Core Functions ---
fn_pre_flight_checks() {
    _log "INFO" "Performing pre-flight checks..."; _ensure_root
    # Finalize global UBUNTU_CODENAME
    if [[ "$UBUNTU_CODENAME" == "unknown" ]]; then 
        if command -v lsb_release &>/dev/null; then UBUNTU_CODENAME=$(lsb_release -cs)
        else 
            _log "WARN" "lsb_release not found. Installing..."
            apt-get update -y >>"$LOG_FILE" 2>&1 || _log "WARN" "apt update fail during lsb_release install."
            apt-get install -y lsb-release >>"$LOG_FILE" 2>&1 || (_log "ERROR" "Fail lsb-release install." && exit 1)
            if command -v lsb_release &>/dev/null; then UBUNTU_CODENAME=$(lsb_release -cs)
            else _log "ERROR" "No Ubuntu codename after lsb_release install. Exit."; exit 1; fi
        fi
    fi; _log "INFO" "Ubuntu codename: ${UBUNTU_CODENAME}"
    if [[ -z "$UBUNTU_CODENAME" || "$UBUNTU_CODENAME" == "unknown" ]]; then _log "ERROR" "No Ubuntu codename. Exit."; exit 1; fi

    if command -v dpkg &> /dev/null; then
        RSTUDIO_ARCH=$(dpkg --print-architecture)
        _log "INFO" "System architecture: ${RSTUDIO_ARCH}"
        if [[ "$RSTUDIO_ARCH" != "amd64" && "$RSTUDIO_ARCH" != "arm64" ]]; then
            _log "WARN" "Arch '${RSTUDIO_ARCH}' not amd64/arm64. Defaulting to '${RSTUDIO_ARCH_FALLBACK}' for RStudio."
            RSTUDIO_ARCH="$RSTUDIO_ARCH_FALLBACK"
        fi
    else _log "WARN" "dpkg not found. Using fallback RSTUDIO_ARCH: ${RSTUDIO_ARCH_FALLBACK}"; RSTUDIO_ARCH="$RSTUDIO_ARCH_FALLBACK"; fi
    
    # Re-initialize RStudio fallback URLs with the finalized UBUNTU_CODENAME and RSTUDIO_ARCH
    RSTUDIO_VERSION="$RSTUDIO_VERSION_FALLBACK" 
    RSTUDIO_DEB_URL="https://download2.rstudio.org/server/${UBUNTU_CODENAME}/${RSTUDIO_ARCH}/rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
    RSTUDIO_DEB_FILENAME="rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
    
    #doen't work the parser
    #fn_get_latest_rstudio_info # Attempt to update RSTUDIO_VERSION, _DEB_URL, _DEB_FILENAME
    
    CRAN_REPO_LINE="deb ${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME}-cran40/" # Finalize CRAN repo line
    _log "INFO" "RStudio version to use: ${RSTUDIO_VERSION} (URL: ${RSTUDIO_DEB_URL})"
    
    mkdir -p "$LOG_DIR" "$BACKUP_DIR"
    local deps=("wget" "gpg" "apt-transport-https" "ca-certificates" "curl" "gdebi-core"); local missing_deps=(); for d in "${deps[@]}"; do if ! command -v "$d" &>/dev/null; then missing_deps+=("$d"); fi; done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then _log "INFO" "Installing missing deps: ${missing_deps[*]}"; _run_command "Update apt for deps" apt-get update -y; _run_command "Install deps: ${missing_deps[*]}" apt-get install -y "${missing_deps[@]}"; fi
    _log "INFO" "Pre-flight checks done."
}

fn_add_cran_repo() {
    _log "INFO" "Adding CRAN repository..."

    # Ensure add-apt-repository is available
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        _log "INFO" "add-apt-repository not found. Installing software-properties-common."
        apt-get update -y
        apt-get install -y software-properties-common
    fi

    if grep -qrE "^deb .*${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME}-cran40/" /etc/apt/sources.list /etc/apt/sources.list.d/; then
        _log "INFO" "CRAN repository '${CRAN_REPO_LINE}' already configured."
    else
        _run_command "Add CRAN GPG key ${CRAN_APT_KEY_ID}" apt-key adv --keyserver keyserver.ubuntu.com --recv-keys "${CRAN_APT_KEY_ID}"
        _run_command "Add CRAN repository entry" add-apt-repository -y "${CRAN_REPO_LINE}"
        _run_command "Update apt cache" apt-get update -y
        _log "INFO" "CRAN repository added."
    fi
}

fn_install_r() {
    _log "INFO" "Installing R..."
    if dpkg -s r-base &> /dev/null; then _log "INFO" "R (r-base) already installed."
    else _run_command "Install R (r-base, r-base-dev, r-base-core)" apt-get install -y r-base r-base-dev r-base-core; _log "INFO" "R installed."; fi
    _get_r_profile_site_path 
}

fn_install_openblas_openmp() {
    _log "INFO" "Installing OpenBLAS and OpenMP..."
    local pkgs=("libopenblas-dev" "libomp-dev"); local to_install=()
    for pkg in "${pkgs[@]}"; do if ! dpkg -s "$pkg" &> /dev/null; then to_install+=("$pkg"); else _log "INFO" "Package $pkg already installed."; fi; done
    if [[ ${#to_install[@]} -gt 0 ]]; then _run_command "Install OpenBLAS/OpenMP: ${to_install[*]}" apt-get install -y "${to_install[@]}"; _log "INFO" "OpenBLAS/OpenMP pkgs installed/checked."
    else _log "INFO" "All OpenBLAS/OpenMP pkgs already installed."; fi
}

fn_verify_openblas_openmp() {
    _log "INFO" "Verifying OpenBLAS and OpenMP with R..."
    if ! command -v Rscript &> /dev/null; then _log "ERROR" "Rscript not found. Install R first."; return 1; fi
    _log "INFO" "Checking system BLAS/LAPACK alternatives..."
    local arch_suffix=""; 
    if [ -e /usr/lib/x86_64-linux-gnu/libblas.so.3 ]; then arch_suffix="-x86_64-linux-gnu"; 
    elif [ -e /usr/lib/aarch64-linux-gnu/libblas.so.3 ]; then arch_suffix="-aarch64-linux-gnu"; fi

    if ! _run_command_allow_no_alternatives "Display libblas.so.3 (generic)" update-alternatives --display libblas.so.3; then
        _run_command_allow_no_alternatives "Display libblas.so.3${arch_suffix}" update-alternatives --display "libblas.so.3${arch_suffix}" || true; fi
    if ! _run_command_allow_no_alternatives "Display liblapack.so.3 (generic)" update-alternatives --display liblapack.so.3; then
        _run_command_allow_no_alternatives "Display liblapack.so.3${arch_suffix}" update-alternatives --display "liblapack.so.3${arch_suffix}" || true; fi
    
    if command -v openblas_get_config &> /dev/null; then
        _log "INFO" "Getting OpenBLAS compile-time config..."
        local openblas_config_rc=0; ( _run_command "OpenBLAS Get Config" openblas_get_config ) || openblas_config_rc=$?
        if [[ $openblas_config_rc -ne 0 ]]; then _log "WARN" "openblas_get_config failed (RC: $openblas_config_rc). Continuing."; fi
    else _log "INFO" "openblas_get_config not found. Skipping."; fi

    local r_check_script_file="check_r_blas_openmp.R"
    read -r -d '' r_check_script_content << 'EOF'
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
if (exists("extSoftVersion") && is.function(extSoftVersion)) { print(extSoftVersion()) } else { cat("extSoftVersion() not available.\n") }
cat("\nChecking R's LD_LIBRARY_PATH:\n"); print(Sys.getenv("LD_LIBRARY_PATH"))
cat("\nLoaded DLLs/shared objects for BLAS/LAPACK:\n")
if (exists("getLoadedDLLs") && is.function(getLoadedDLLs)) {
  loaded_dlls_obj <- getLoadedDLLs()
  if (is.list(loaded_dlls_obj) && length(loaded_dlls_obj) > 0) {
    dll_names <- vapply(loaded_dlls_obj, function(dll) as.character(dll[["name"]]), FUN.VALUE = character(1))
    dll_paths <- vapply(loaded_dlls_obj, function(dll) as.character(dll[["path"]]), FUN.VALUE = character(1))
    dll_info_df <- data.frame(Name = dll_names, Path = dll_paths, stringsAsFactors = FALSE)
    blas_lapack_pattern <- "blas|lapack|openblas|mkl|atlas|accelerate" 
    blas_lapack_indices <- grepl(blas_lapack_pattern, dll_info_df$Name, ignore.case = TRUE) | grepl(blas_lapack_pattern, dll_info_df$Path, ignore.case = TRUE)
    blas_lapack_dlls_found <- dll_info_df[blas_lapack_indices, , drop = FALSE] 
    if (nrow(blas_lapack_dlls_found) > 0) { cat("Potential BLAS/LAPACK DLLs:\n"); print(blas_lapack_dlls_found) } else { cat("No DLLs matching BLAS/LAPACK patterns found via getLoadedDLLs().\n") }
  } else { cat("getLoadedDLLs() returned empty list.\n") }
} else { cat("getLoadedDLLs() not found.\n") }
cat("\n--- BLAS Performance Benchmark (crossprod) ---\n")
N <- 1000; m <- matrix(rnorm(N*N), ncol=N)
cat("Attempting matrix multiplication (crossprod(m)) for ", N, "x", N, " matrix...\n")
blas_benchmark_status <- "NOT_RUN"; blas_error_message <- ""
crossprod_result <- tryCatch({
    time_taken <- system.time(crossprod(m)); cat("SUCCESS: crossprod(m) completed.\n"); print(time_taken); blas_benchmark_status <- "SUCCESS"; TRUE 
}, error = function(e) {
    blas_benchmark_status <<- "FAILED"; blas_error_message <<- conditionMessage(e)
    cat("ERROR during crossprod(m):\n", file = stderr()); cat("Msg: ", blas_error_message, "\n", file = stderr())
    if (grepl("illegal operation|illegal operand|illegal instruction", blas_error_message, ignore.case = TRUE)) {
        cat("\n--- IMPORTANT QEMU/VM CPU Incompatibility INFO ---\n", file = stderr())
        cat("Error suggests BLAS lib uses CPU instructions (AVX, AVX2) NOT supported by QEMU CPU.\n", file = stderr())
        cat("Solutions: 1. QEMU: Use '-cpu host' or specific model like '-cpu Haswell'.\n", file = stderr())
        cat("           2. VM: Switch to reference BLAS ('sudo update-alternatives --config libblas.so.3...').\n", file = stderr())
        cat("--------------------------------------------------\n\n", file = stderr())
    } else { cat("Unexpected error during BLAS benchmark.\n", file=stderr()) }
    FALSE 
})
if (!crossprod_result) { cat("\nBLAS benchmark FAILED. Status:", blas_benchmark_status, "\n"); q("no", status = 2, runLast = FALSE) } else { cat("\nBLAS benchmark OK.\n") }
cat("\n--- OpenMP Support Check ---\n")
omp_test <- function() {
    num_cores <- tryCatch(parallel::detectCores(logical=T),error=function(e){cat("Warn: detectCores() failed:",conditionMessage(e),"\n");1})
    if(!is.numeric(num_cores)||num_cores<1)num_cores<-1;cat("Logical cores:",num_cores,"\n")
    if (.Platform$OS.type == "unix") {
        test_cores <- min(num_cores,2);cat("mclapply test (cores:",test_cores,")...\n")
        res <- tryCatch(parallel::mclapply(1:test_cores,function(x)Sys.getpid(),mc.cores=test_cores),error=function(e){cat("mclapply err:",conditionMessage(e),"\n",file=stderr());NULL})
        if(!is.null(res)&&length(res)>0){cat("Unique PIDs:",length(unique(unlist(res))),"\n")}else{cat("mclapply failed/no results.\n")}
    }else{cat("mclapply test skipped (non-unix).\n")}
    cat("Note: True OpenMP in BLAS depends on its compilation.\n")
}
omp_test()
cat("\n--- Verification Script Finished ---\n")
if (!crossprod_result) { q("no", status = 3, runLast = FALSE) }
EOF
    echo "$r_check_script_content" > "$r_check_script_file"
    
    local r_script_rc=0
    ( Rscript "$r_check_script_file" >> "$LOG_FILE" 2>&1 ) || r_script_rc=$? 

    if [[ $r_script_rc -eq 0 ]]; then
        _log "INFO" "OpenBLAS/OpenMP verification R script completed successfully."
    else
        _log "ERROR" "OpenBLAS/OpenMP verification R script FAILED (Rscript Exit Code: ${r_script_rc})."
        _log "ERROR" "Log (${LOG_FILE}) may contain R script error details."
        if [[ $r_script_rc -eq 132 || $r_script_rc -eq 2 ]]; then 
            _log "ERROR" "Exit code ${r_script_rc} (often 'Illegal Instruction') in VMs/QEMU: CPU incompatibility with BLAS."
            _log "ERROR" "See R script output in log for QEMU CPU recommendations or switch to reference BLAS."
        fi
        rm -f "$r_check_script_file" Rplots.pdf .RData
        return 1 
    fi
    rm -f "$r_check_script_file" Rplots.pdf .RData 
    _log "INFO" "OpenBLAS and OpenMP verification step finished."; return 0
}


fn_setup_bspm() {
    _log "INFO" "Setting up bspm (Binary R Package Manager)..."
    _get_r_profile_site_path 

    if [[ -z "$R_PROFILE_SITE_PATH" ]]; then 
         _log "ERROR" "R_PROFILE_SITE_PATH is not set. Cannot setup bspm."; return 1
    fi
    
    local r_profile_dir; r_profile_dir=$(dirname "$R_PROFILE_SITE_PATH")
    if [[ ! -d "$r_profile_dir" ]]; then _run_command "Create Rprofile.site dir ${r_profile_dir}" mkdir -p "$r_profile_dir"; fi
    if [[ ! -f "$R_PROFILE_SITE_PATH" && ! -L "$R_PROFILE_SITE_PATH" ]]; then _run_command "Touch Rprofile.site: ${R_PROFILE_SITE_PATH}" touch "$R_PROFILE_SITE_PATH"; fi

    _log "INFO" "Adding R2U repository..."
    if [[ -f "$R2U_APT_SOURCES_LIST_D_FILE" ]] || grep -qrE "r2u\.stat\.illinois\.edu/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d/; then
        _log "INFO" "R2U repository already configured."
    else
        local r2u_add_script_url="${R2U_REPO_URL_BASE}/add_cranapt_${UBUNTU_CODENAME}.sh"
        _log "INFO" "Downloading R2U setup script: ${r2u_add_script_url}"
        _run_command "Download R2U setup script" curl -sSLf "${r2u_add_script_url}" -o /tmp/add_cranapt.sh
        _log "INFO" "Executing R2U repository setup script..."
        _run_command "Execute R2U repository setup script" bash /tmp/add_cranapt.sh
        rm -f /tmp/add_cranapt.sh
    fi

    _log "INFO" "Installing bspm R package..."
    local bspm_check_cmd='if(requireNamespace("bspm", quietly=TRUE)) "installed" else "not_installed"'
    if [[ $(Rscript -e "$bspm_check_cmd" 2>/dev/null) == "installed" ]]; then
        _log "INFO" "bspm R package already installed."
    else
        _run_command "Install bspm R package" Rscript -e "install.packages('bspm', repos='${CRAN_REPO_URL_SRC}')"
    fi

    _backup_file "$R_PROFILE_SITE_PATH"
    _log "INFO" "Enabling bspm in ${R_PROFILE_SITE_PATH}..."
    # FIX: Allow bspm to manage packages for non-root by setting option before enabling
    local bspm_enable_line='options(bspm.allow.sysreqs=TRUE);suppressMessages(bspm::enable())'
    if grep -qF -- "suppressMessages(bspm::enable())" "$R_PROFILE_SITE_PATH"; then
        _log "INFO" "bspm enable line already present in Rprofile.site."
    else
        _run_command "Append bspm enable to ${R_PROFILE_SITE_PATH}" sh -c "echo '$bspm_enable_line' | tee -a '$R_PROFILE_SITE_PATH'"
        _log "INFO" "bspm enabled in Rprofile.site."
    fi
    
    _log "INFO" "Debug: Content of Rprofile.site (${R_PROFILE_SITE_PATH}):"
    ( cat "$R_PROFILE_SITE_PATH" >> "$LOG_FILE" 2>&1 ) || _log "WARN" "Could not display Rprofile.site content."

    _log "INFO" "Checking bspm status and activation as per official documentation..."
    set +e
    bspm_status_output=$(Rscript --vanilla -e '
if (!requireNamespace("bspm", quietly=TRUE)) {
  cat("BSPM_NOT_INSTALLED\n"); quit(status=1)
}
options(bspm.allow.sysreqs=TRUE)
suppressMessages(bspm::enable())
if (isTRUE(getOption("bspm.MANAGES"))) {
  cat("BSPM_WORKING\n")
} else {
  cat("BSPM_NOT_MANAGING\n")
  quit(status=2)
}
')
    bspm_status_rc=$?
    set -e

    if [[ $bspm_status_rc -eq 0 && "$bspm_status_output" == *BSPM_WORKING* ]]; then
        _log "INFO" "bspm is installed and managing packages (bspm.MANAGES==TRUE)."
    elif [[ "$bspm_status_output" == *BSPM_NOT_INSTALLED* ]]; then
        _log "ERROR" "bspm is NOT installed properly."
        return 2
    elif [[ "$bspm_status_output" == *BSPM_NOT_MANAGING* ]]; then
        _log "ERROR" "bspm is installed but NOT managing packages (bspm.MANAGES!=TRUE)."
        return 3
    else
        _log "ERROR" "Unknown bspm status: $bspm_status_output"
        return 4
    fi

    _log "INFO" "bspm setup and verification completed."
}

_install_r_pkg_list() {
    local pkg_type="$1"; shift; local r_packages_list=("${@}")
    if [[ ${#r_packages_list[@]} -eq 0 ]]; then _log "INFO" "No ${pkg_type} R pkgs in list."; return; fi
    _log "INFO" "Installing ${pkg_type} R packages: ${r_packages_list[*]}"
    for pkg_name_full in "${r_packages_list[@]}"; do
        local pkg_name_short; local install_script=""
        if [[ "$pkg_type" == "CRAN" ]]; then
            pkg_name_short="$pkg_name_full" 
            install_script="
            if (!requireNamespace('$pkg_name_short', quietly=T)) {
                cat('Pkg $pkg_name_short not found, installing...\\n')
                if (requireNamespace('bspm',quietly=T) && getOption('bspm.MANAGES',F)) { 
                    cat('Installing $pkg_name_short via bspm...\\n')
                    tryCatch(bspm::install.packages('$pkg_name_short',quiet=F),
                        error=function(e){cat('bspm fail for $pkg_name_short:',conditionMessage(e),'\\nFallback...\\n');install.packages('$pkg_name_short',repos='${CRAN_REPO_URL_SRC}')})
                } else { cat('bspm not managing. Using install.packages for $pkg_name_short...\\n');install.packages('$pkg_name_short',repos='${CRAN_REPO_URL_SRC}')}
                if (!requireNamespace('$pkg_name_short',quietly=T)) stop(paste('Failed to install R pkg:', '$pkg_name_short'))
                else cat('OK R pkg: $pkg_name_short\\n')
            } else cat('R pkg $pkg_name_short already installed.\\n')"
        elif [[ "$pkg_type" == "GitHub" ]]; then
            pkg_name_short=$(basename "${pkg_name_full%.git}") 
            if [[ "$pkg_name_full" == *"://"* ]]; then 
                 install_script="if(!requireNamespace('$pkg_name_short',q=T))devtools::install_git('$pkg_name_full')else cat('R pkg $pkg_name_short (git) installed.\\n')"
            else install_script="if(!requireNamespace('$pkg_name_short',q=T))devtools::install_github('$pkg_name_full')else cat('R pkg $pkg_name_short (GitHub) installed.\\n')";fi
        else _log "WARN" "Unknown pkg type: $pkg_type for $pkg_name_full. Skipping."; continue; fi
        _run_command "Install/Verify R pkg: $pkg_name_full" Rscript -e "$install_script"
    done; _log "INFO" "${pkg_type} R pkgs install process done."
}

fn_install_r_packages() {
    _install_r_pkg_list "CRAN" "${R_PACKAGES_CRAN[@]}"
    if [[ ${#R_PACKAGES_GITHUB[@]} -gt 0 ]]; then
        _log "INFO" "Ensuring devtools for GitHub packages..."
        local r_cmd_devtools; r_cmd_devtools="if(!requireNamespace('devtools',q=T)){install.packages('devtools',repos='${CRAN_REPO_URL_SRC}');if(!requireNamespace('devtools',q=T))stop('Fail devtools install')}"
        _run_command "Ensure devtools R pkg installed" Rscript -e "${r_cmd_devtools}"
        _install_r_pkg_list "GitHub" "${R_PACKAGES_GITHUB[@]}"
    else _log "INFO" "No GitHub R packages in list."; fi
}

fn_install_rstudio_server() {
    _log "INFO" "Installing RStudio Server v${RSTUDIO_VERSION}..."
    if dpkg -s rstudio-server &>/dev/null && rstudio-server version 2>/dev/null | grep -q "^${RSTUDIO_VERSION}"; then
        _log "INFO" "RStudio Server v${RSTUDIO_VERSION} already installed."
        if ! _safe_systemctl is-active --quiet rstudio-server; then _log "INFO" "RStudio Server inactive. Starting...";_run_command "Start RStudio" _safe_systemctl start rstudio-server;fi;return
    elif dpkg -s rstudio-server &>/dev/null; then
        local inst_ver; inst_ver=$(rstudio-server version 2>/dev/null||echo "unknown")
        _log "INFO" "Other RStudio Server (${inst_ver}) installed. Removing for target version."
        _run_command "Stop RStudio" _safe_systemctl stop rstudio-server ||true
        _run_command "Purge RStudio" apt-get purge -y rstudio-server
    fi
    if [[ ! -f "/tmp/${RSTUDIO_DEB_FILENAME}" ]]; then _log "INFO" "Downloading RStudio .deb from ${RSTUDIO_DEB_URL}";_run_command "Download RStudio .deb" wget -O "/tmp/${RSTUDIO_DEB_FILENAME}" "${RSTUDIO_DEB_URL}"
    else _log "INFO" "RStudio .deb already downloaded: /tmp/${RSTUDIO_DEB_FILENAME}";fi
    _run_command "Install RStudio ${RSTUDIO_DEB_FILENAME} via gdebi" gdebi -n "/tmp/${RSTUDIO_DEB_FILENAME}"
    _log "INFO" "Verifying RStudio Server..."
    if _run_command "Check RStudio status" _safe_systemctl is-active --quiet rstudio-server; then _log "INFO" "RStudio Server active."
    else _log "WARN" "RStudio inactive post-install. Starting...";_run_command "Start RStudio" _safe_systemctl start rstudio-server
        if ! _run_command "Re-check RStudio status" _safe_systemctl is-active --quiet rstudio-server; then _log "ERROR" "Failed to start RStudio."; return 1;fi;fi
    _run_command "Enable RStudio on boot" _safe_systemctl enable rstudio-server
    _log "INFO" "RStudio Server version: $(rstudio-server version 2>/dev/null||echo 'N/A')"; _log "INFO" "RStudio Server installed & verified."
}

# --- Uninstall Functions ---
fn_uninstall_r_packages() {
    _log "INFO" "Uninstalling script-specified R packages..."
    if ! command -v Rscript &>/dev/null; then _log "INFO" "Rscript not found. Skipping R pkg removal."; return; fi
    local all_pkgs_rm_short=("${R_PACKAGES_CRAN[@]}" "bspm"); for gh_pkg in "${R_PACKAGES_GITHUB[@]}"; do all_pkgs_rm_short+=("$(basename "${gh_pkg%.git}")"); done
    local unique_pkgs_rm_str; unique_pkgs_rm_str=$(printf "%s\n" "${all_pkgs_rm_short[@]}"|sort -u|tr '\n' ' ')
    if [[ -n "$unique_pkgs_rm_str" ]]; then
        local r_vec_str; r_vec_str="c($(echo "$unique_pkgs_rm_str"|sed "s/ /', '/g;s/^/'/;s/, '$//"))"
        local r_pkg_rm_script_file="uninstall_pkgs.R"
        # Using 'EOF' (quoted heredoc)
        read -r -d '' r_pkg_rm_script_content <<EOF
        pkgs_to_remove <- ${r_vec_str}
        inst_pkgs_df <- installed.packages()
        if(is.null(inst_pkgs_df)||nrow(inst_pkgs_df)==0){cat('No R pkgs currently installed.\n')}
        else{ inst_pkgs_vec<-inst_pkgs_df[,'Package'];pkgs_exist_rm<-intersect(pkgs_to_remove,inst_pkgs_vec)
        if(length(pkgs_exist_rm)>0){cat('Removing R pkgs:',paste(pkgs_exist_rm,collapse=', '),'\n');suppressWarnings(remove.packages(pkgs_exist_rm));cat('Done R pkg removal attempt.\n')}
        else{cat('None of specified R pkgs found to remove.\n')}}
EOF
        echo "$r_pkg_rm_script_content" > "$r_pkg_rm_script_file"
        _log "INFO" "R script for pkg removal written to ${r_pkg_rm_script_file}"
        local r_rm_rc=0; (Rscript "$r_pkg_rm_script_file" >>"$LOG_FILE" 2>&1) || r_rm_rc=$?
        rm -f "$r_pkg_rm_script_file"
        if [[ $r_rm_rc -eq 0 ]]; then _log "INFO" "R pkg uninstall script done."; else _log "WARN" "R pkg uninstall script errors (RC:$r_rm_rc)."; fi
    else _log "INFO" "No R pkgs in script lists for removal."; fi
}

fn_remove_bspm_config() {
    _log "INFO" "Removing bspm config..."
    _get_r_profile_site_path
    if [[ -n "$R_PROFILE_SITE_PATH" && (-f "$R_PROFILE_SITE_PATH"||-L "$R_PROFILE_SITE_PATH") ]]; then
        _log "INFO" "Removing bspm line from ${R_PROFILE_SITE_PATH}"
        _backup_file "$R_PROFILE_SITE_PATH"
        if sed -i.bspm_removed_bak '/suppressMessages(bspm::enable())/d' "$R_PROFILE_SITE_PATH"; then _log "INFO" "Removed bspm line (backup ${R_PROFILE_SITE_PATH}.bspm_removed_bak)."
        else _log "WARN" "sed failed for bspm line in ${R_PROFILE_SITE_PATH}.";fi
        _restore_latest_backup "$R_PROFILE_SITE_PATH"
    else _log "INFO" "Rprofile.site not found/set. Skipping bspm line removal.";fi
    _log "INFO" "Removing R2U apt repo config..."
    local r2u_repo_fpath="$R2U_APT_SOURCES_LIST_D_FILE"; local r2u_pattern="r2u.stat.illinois.edu"
    if [[ -f "$r2u_repo_fpath" ]]; then _log "INFO" "Removing R2U repo file: ${r2u_repo_fpath}";_run_command "Rm R2U file ${r2u_repo_fpath}" rm -f "$r2u_repo_fpath"
    else _log "INFO" "Specific R2U file ${r2u_repo_fpath} not found. Generic check...";fi
    find /etc/apt/sources.list /etc/apt/sources.list.d/ -type f -name '*.list' -print0 | \
    while IFS= read -r -d $'\0' f; do if grep -q "$r2u_pattern" "$f"; then
        _log "INFO" "R2U entry in $f. Backing up & removing."
        _backup_file "$f"; _run_command "Rm R2U entry from $f" sed -i.r2u_removed_bak "/${r2u_pattern}/d" "$f";fi;done
    _log "INFO" "R2U apt repo removal done."
}

fn_remove_cran_repo() {
    _log "INFO" "Removing CRAN apt repo config..."
    local cran_pattern_esc; cran_pattern_esc=$(echo "${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME}-cran40/"|sed 's|[&/\]|\\&|g')
    find /etc/apt/sources.list /etc/apt/sources.list.d/ -type f -name '*.list' -print0 | \
    while IFS= read -r -d $'\0' f; do if grep -qE "^\s*deb\s+.*${cran_pattern_esc}" "$f"; then
        _log "INFO" "CRAN entry in $f. Backing up & removing."
        _backup_file "$f"; _run_command "Rm CRAN entry from $f" sed -i.cran_removed_bak "\|^\s*deb\s+.*${cran_pattern_esc}|d" "$f";fi;done
    _log "INFO" "Removing CRAN GPG key ${CRAN_APT_KEY_ID}..."
    local key_short; key_short=$(apt-key list 2>/dev/null|grep -B 1 "${CRAN_APT_KEY_ID}"|head -n1|awk '{print $2}'|cut -d'/' -f2)
    if [[ -n "$key_short" ]]; then _run_command "Rm CRAN GPG key ${key_short}" apt-key del "$key_short"
    else _log "INFO" "CRAN GPG key ${CRAN_APT_KEY_ID} not found.";fi
    _log "INFO" "CRAN apt repo removal done."
}

fn_uninstall_system_packages() {
    _log "INFO" "Uninstalling system pkgs (RStudio, R, OpenBLAS, OpenMP...)..."
    if dpkg -s rstudio-server &>/dev/null; then _log "INFO" "Stopping & purging RStudio Server...";
        _run_command "Stop RStudio" _safe_systemctl stop rstudio-server||true
        _run_command "Disable RStudio" _safe_systemctl disable rstudio-server||true
        _run_command "Purge RStudio" apt-get purge -y rstudio-server
    else _log "INFO" "RStudio Server pkg not found.";fi
    local pkgs_purge=("r-base" "r-base-dev" "r-base-core" "libopenblas-dev" "libomp-dev" "gdebi-core")
    local actual_pkgs_purge=(); for pkg in "${pkgs_purge[@]}";do if dpkg -s "$pkg" &>/dev/null;then actual_pkgs_purge+=("$pkg");fi;done
    if [[ ${#actual_pkgs_purge[@]} -gt 0 ]]; then _log "INFO" "Purging system pkgs: ${actual_pkgs_purge[*]}"
        _run_command "Purge system pkgs" apt-get purge -y "${actual_pkgs_purge[@]}"
    else _log "INFO" "Target system pkgs (R, OpenBLAS, etc.) not installed.";fi
    _log "INFO" "Running apt autoremove & autoclean..."
    _run_command "apt autoremove" apt-get autoremove -y
    _run_command "apt autoclean" apt-get autoclean -y
    _log "INFO" "Updating apt cache post-removals..."; _run_command "apt update" apt-get update -y
    _log "INFO" "System pkg uninstall done."
}

fn_remove_leftover_files() {
    _log "INFO" "Removing leftover R & RStudio files/dirs..."
    declare -a paths_rm=(
        "/usr/local/lib/R"       
        "/usr/local/bin/R"       
        "/usr/local/bin/Rscript" 
        "/var/lib/rstudio-server" 
        "/var/run/rstudio-server" 
    )
    
    if [[ -d "/etc/R" ]]; then
        # Check if any file inside /etc/R is still claimed by a dpkg package
        # This is a heuristic; a file might exist without being owned if package was removed without purge
        if dpkg-query -S /etc/R/* >/dev/null 2>&1; then
            _log "INFO" "/etc/R or its contents still appear to be owned by a system package. Skipping its direct removal."
        else
            _log "INFO" "/etc/R seems unowned by packages. Adding to removal list."
            paths_rm+=("/etc/R")
        fi
    fi
    
    for p in "${paths_rm[@]}"; do
        if [[ -d "$p" ]]; then _log "INFO" "Removing dir: ${p}";_run_command "Rm dir ${p}" rm -rf "$p"
        elif [[ -f "$p" || -L "$p" ]]; then _log "INFO" "Removing file/link: ${p}";_run_command "Rm file/link ${p}" rm -f "$p"
        else _log "INFO" "Path not found, skip rm: ${p}";fi
    done

    if [[ -f "/tmp/${RSTUDIO_DEB_FILENAME}" ]]; then _log "INFO" "Removing RStudio .deb: /tmp/${RSTUDIO_DEB_FILENAME}";rm -f "/tmp/${RSTUDIO_DEB_FILENAME}";fi

    local IS_INTERACTIVE=false; if [[ -t 0 && -t 1 ]]; then IS_INTERACTIVE=true; fi
    local PROMPT_AGGRESSIVE_CLEANUP="${PROMPT_AGGRESSIVE_CLEANUP:-yes}" 

    if [[ "${FORCE_USER_CLEANUP:-no}" == "yes" || ( "$IS_INTERACTIVE" == "true" && "$PROMPT_AGGRESSIVE_CLEANUP" == "yes" )  ]]; then
        local perform_aggressive_cleanup=false
        if [[ "${FORCE_USER_CLEANUP:-no}" == "yes" ]]; then
            _log "INFO" "FORCE_USER_CLEANUP=yes. Aggressive user data removal."
            perform_aggressive_cleanup=true
        elif $IS_INTERACTIVE; then
            _log "WARN" "PROMPT: Aggressive user-level R config/library cleanup."
            read -r -p "Also remove R data from ALL user homes (~/.R*, ~/R, ~/.config/R*, ...)? THIS IS DESTRUCTIVE. (yes/NO): " aggressive_confirm
            if [[ "$aggressive_confirm" =~ ^[Yy][Ee][Ss]$ ]]; then perform_aggressive_cleanup=true
            else _log "INFO" "Skipping aggressive user-level R cleanup (user declined).";fi
        fi

        if [[ "$perform_aggressive_cleanup" == "true" ]]; then
            _log "INFO" "Attempting aggressive user-level R cleanup..."
            awk -F: '$3 >= 1000 && $6 != "" && $6 != "/nonexistent" && $6 != "/" {print $6}' /etc/passwd | while IFS= read -r user_home; do
                if [[ -d "$user_home" ]]; then 
                    _log "INFO" "Checking user home: $user_home"
                    declare -a user_r_paths=( "${user_home}/.R" "${user_home}/R" "${user_home}/.config/R" "${user_home}/.cache/R" "${user_home}/.rstudio" "${user_home}/.config/rstudio" "${user_home}/.local/share/rstudio" "${user_home}/.local/share/renv" )
                    for user_r_path in "${user_r_paths[@]}"; do
                        if [[ -e "$user_r_path" ]]; then 
                            _log "WARN" "Aggressive: Removing ${user_r_path}"
                            if [[ "$user_r_path" != "$user_home" && "$user_r_path" == "$user_home/"* ]]; then _run_command "Aggressive Rm ${user_r_path}" rm -rf "$user_r_path"
                            else _log "ERROR" "Safety break: Skipped removing suspicious path '${user_r_path}' for home '${user_home}'.";fi
                        fi
                    done
                fi
            done; _log "INFO" "Aggressive user-level R cleanup attempt finished."
        fi
    else _log "INFO" "Skipping aggressive user-level cleanup (FORCE_USER_CLEANUP not 'yes' or not interactive/prompted)."; fi
    _log "INFO" "Leftover file removal done."
}

# --- Main Execution ---
install_all() {
    _log "INFO" "--- Starting Full Installation ---"
    fn_pre_flight_checks; fn_add_cran_repo; fn_install_r; fn_install_openblas_openmp
    if ! fn_verify_openblas_openmp; then _log "WARN" "OpenBLAS/OpenMP verification failed. Continue, but review logs.";fi
    fn_setup_bspm; fn_install_r_packages; fn_install_rstudio_server
    _log "INFO" "--- Full Installation Completed ---"
    _log "INFO" "RStudio Server at http://<SERVER_IP>:8787 (if not firewalled). Log: ${LOG_FILE}"
}

uninstall_all() {
    _log "INFO" "--- Starting Full Uninstallation ---"
    _ensure_root; _get_r_profile_site_path
    fn_uninstall_r_packages; fn_remove_bspm_config; fn_uninstall_system_packages; fn_remove_cran_repo; fn_remove_leftover_files
    _log "INFO" "Verifying uninstallation..."
    local fail_verify_count=0
    if command -v R &>/dev/null;then _log "WARN" "VERIFY FAIL: R cmd found.";((fail_verify_count++));else _log "INFO" "VERIFY OK: R cmd not found.";fi
    if command -v Rscript &>/dev/null;then _log "WARN" "VERIFY FAIL: Rscript cmd found.";((fail_verify_count++));else _log "INFO" "VERIFY OK: Rscript cmd not found.";fi
    if command -v rstudio-server &>/dev/null||dpkg -s rstudio-server &>/dev/null;then _log "WARN" "VERIFY FAIL: rstudio-server found.";((fail_verify_count++));else _log "INFO" "VERIFY OK: rstudio-server not found.";fi
    for pkg_chk in r-base libopenblas-dev;do if dpkg -s "$pkg_chk" &>/dev/null;then _log "WARN" "VERIFY FAIL: Pkg $pkg_chk found.";((fail_verify_count++));else _log "INFO" "VERIFY OK: Pkg $pkg_chk not found.";fi;done
    if [[ $fail_verify_count -eq 0 ]]; then _log "INFO" "--- Full Uninstallation Completed Successfully ---"
    else _log "ERROR" "--- Full Uninstallation Done with ${fail_verify_count} Issues. Manual check needed. Log: ${LOG_FILE} ---";fi
}

# --- Menu / Argument Parsing ---
usage() {
    echo "Usage: $0 [ACTION]";echo "Manages R, RStudio, OpenBLAS, BSPM, R packages.";echo "";echo "Actions:"
    echo "  install_all                 Run all installation steps.";echo "  uninstall_all                 Uninstall all components by this script."
    echo "  interactive                 Show interactive menu (default if no action).";echo "";echo "Individual functions (mostly for dev/debug - use with caution):"
    echo "  fn_pre_flight_checks, fn_add_cran_repo, fn_install_r, fn_install_openblas_openmp"
    echo "  fn_verify_openblas_openmp, fn_setup_bspm, fn_install_r_packages, fn_install_rstudio_server"
    echo "  fn_set_r_profile_path_interactive, toggle_aggressive_cleanup"; echo ""; echo "Log file: ${LOG_FILE}";exit 1
}

interactive_menu() {
    _ensure_root
    while true; do
        _get_r_profile_site_path 
        echo "";echo "R Environment Setup Menu (Log: ${LOG_FILE})";
        echo "Effective Rprofile.site for bspm: ${R_PROFILE_SITE_PATH:-Not yet determined/set}"
        echo "RStudio Server version to install: ${RSTUDIO_VERSION} (Fallback: ${RSTUDIO_VERSION_FALLBACK})"
        echo "------------------------------------------------------------"
        echo " Installation Steps:";echo "  1. Full Installation";echo "  2. Pre-flight Checks";echo "  3. Add CRAN Repo & Install R"
        echo "  4. Install OpenBLAS & OpenMP";echo "  5. Verify OpenBLAS/OpenMP";echo "  6. Setup BSPM"
        echo "  7. Install R Packages";echo "  8. Install RStudio Server";echo "------------------------------------------------------------"
        echo " Configuration:"; echo "  C. Configure Rprofile.site Path (for bspm)"
        echo "------------------------------------------------------------"
        echo " Uninstallation:";echo "  9. Uninstall All Components"
        echo "  F. Toggle Aggressive User Data Cleanup for Uninstall (Current: ${FORCE_USER_CLEANUP})"
        echo "------------------------------------------------------------"
        echo "  0. Exit";echo "------------------------------------------------------------";read -r -p "Choose an option: " option; clear
        case $option in
            1) install_all;; 2) fn_pre_flight_checks;; 3) fn_pre_flight_checks;fn_add_cran_repo;fn_install_r;;
            4) fn_pre_flight_checks;fn_install_openblas_openmp;; 5) fn_pre_flight_checks;fn_install_r;fn_install_openblas_openmp;fn_verify_openblas_openmp;;
            6) fn_pre_flight_checks;fn_install_r;fn_setup_bspm;; 7) fn_pre_flight_checks;fn_install_r;fn_install_r_packages;;
            8) fn_pre_flight_checks;fn_install_r;fn_install_rstudio_server;; 
            C|c) fn_set_r_profile_path_interactive ;;
            F|f) 
                if [[ "$FORCE_USER_CLEANUP" == "yes" ]]; then FORCE_USER_CLEANUP="no"; _log "INFO" "Aggressive user data cleanup TOGGLED OFF."
                else FORCE_USER_CLEANUP="yes"; _log "INFO" "Aggressive user data cleanup TOGGLED ON.";fi;;
            9) uninstall_all;; 0) _log "INFO" "Exiting menu.";exit 0;;
            *) _log "WARN" "Invalid option: '$option'.";;
        esac; echo ""; echo "Action done. Enter to menu..."; read -r; clear
    done
}

main() {
    _log "INFO" "Script started. Log: ${LOG_FILE}"
    _get_r_profile_site_path # Initial call to set R_PROFILE_SITE_PATH

    if [[ $# -eq 0 ]]; then 
        interactive_menu
    else
        _ensure_root 
        local action_arg="$1"
        shift 
        
        local target_function=""
        case "$action_arg" in
            install_all|uninstall_all) target_function="$action_arg";;
            interactive) interactive_menu; _log "INFO" "Script finished after interactive session."; exit 0;;
            fn_pre_flight_checks|fn_add_cran_repo|fn_install_r|fn_install_openblas_openmp) target_function="$action_arg";;
            fn_verify_openblas_openmp|fn_setup_bspm|fn_install_r_packages|fn_install_rstudio_server) target_function="$action_arg";;
            fn_set_r_profile_path_interactive) target_function="$action_arg";;
            toggle_aggressive_cleanup)
                if [[ "$FORCE_USER_CLEANUP" == "yes" ]]; then FORCE_USER_CLEANUP="no"; _log "INFO" "Aggressive cleanup OFF."
                else FORCE_USER_CLEANUP="yes"; _log "INFO" "Aggressive cleanup ON.";fi
                _log "INFO" "Script finished."; exit 0;;
            *) _log "ERROR" "Unknown direct action: $action_arg. For menu, run without arguments."; usage;;
        esac
        
        if declare -f "$target_function" >/dev/null; then
            "$target_function" "$@" 
        else 
            _log "ERROR" "Internal error: Target function for action '$action_arg' not found or not callable."
            usage
        fi
    fi
    _log "INFO" "Script finished."
}

# UBUNTU_CODENAME is set to the detected value from UBUNTU_CODENAME_DETECTED before main actions start
# (or remains "unknown" if lsb_release fails, to be handled in fn_pre_flight_checks).
# fn_pre_flight_checks will ensure it's fully resolved.
main "$@"
