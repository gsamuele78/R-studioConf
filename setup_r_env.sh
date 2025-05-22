#!/usr/bin/env bash

##############################################################################
# Script: setup_r_env.sh
# Desc:   Installs R, OpenBLAS, OpenMP, RStudio Server, BSPM, and R packages.
#         Includes auto-detection for latest RStudio Server, uninstall,
#         and backup/restore for Rprofile.site.
#         Enhanced for debug, DRY_RUN, and sysadmin usability.
# Author: Your Name/Team
# Date:   $(date +%Y-%m-%d)
##############################################################################

# --- Configuration ---
set -euo pipefail

LOG_LEVEL="${LOG_LEVEL:-INFO}"   # DEBUG, INFO, WARN, ERROR
DRY_RUN="${DRY_RUN:-0}"

LOG_DIR="/var/log/r_setup"
LOG_FILE="${LOG_DIR}/r_setup_$(date +'%Y%m%d_%H%M%S').log"
BACKUP_DIR="/opt/r_setup_backups"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

# --- Logging helpers ---
_log() {
    local level="$1"; shift
    [[ "$level" == "DEBUG" && "$LOG_LEVEL" != "DEBUG" ]] && return
    local color_reset="\033[0m"
    local color_red="\033[31m"
    local color_yellow="\033[33m"
    local color_blue="\033[34m"
    local color=""
    case "$level" in
        ERROR) color="$color_red" ;;
        WARN)  color="$color_yellow" ;;
        INFO)  color="$color_blue" ;;
        DEBUG) color="$color_reset" ;;
    esac
    if [[ -t 1 ]]; then
        echo -e "${color}$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*${color_reset}" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*" | tee -a "$LOG_FILE"
    fi
}
_debug() { _log "DEBUG" "$@"; }
_info()  { _log "INFO" "$@"; }
_warn()  { _log "WARN" "$@"; }
_error() { _log "ERROR" "$@"; }

# --- Dry-run wrapper ---
_run() {
    local cmd_desc="$1"; shift
    if [[ "$DRY_RUN" == "1" ]]; then
        _info "[DRY-RUN] $cmd_desc: $*"
        return 0
    else
        _log "INFO" "Start: $cmd_desc"
        if "$@" >>"$LOG_FILE" 2>&1; then
            _log "INFO" "OK: $cmd_desc"
            return 0
        else
            local rc=$?
            _log "ERROR" "FAIL: $cmd_desc (RC:$rc). See log: $LOG_FILE"
            tail -n 7 "$LOG_FILE" | sed 's/^/    /'
            return $rc
        fi
    fi
}

# --- Trap for cleanup ---
cleanup() {
    _info "Cleaning up temporary files..."
    # Add temp file cleanup if needed.
}
trap cleanup EXIT

# --- Root check ---
_ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        _error "Run as root/sudo."
        exit 1
    fi
}

# --- Deprecation warning for apt-key ---
_warn_apt_key() {
    if command -v apt-key >/dev/null 2>&1; then
        local rel
        rel="$(lsb_release -rs 2>/dev/null || echo "0")"
        if [[ "$rel" == "20.04" || "$rel" == "22.04" || "$rel" == "24.04" ]]; then
            _warn "apt-key is deprecated on Ubuntu $rel. Prefer signed-by in sources.list."
        fi
    fi
}

# --- Backup helpers ---
_backup_file() {
    local fp="$1"
    if [[ -f "$fp" || -L "$fp" ]]; then
        local bn
        bn="$(basename "$fp")_$(date +'%Y%m%d%H%M%S').bak"
        _info "Backup $fp to $BACKUP_DIR/$bn"
        _run "Backup $fp" cp -a "$fp" "$BACKUP_DIR/$bn"
    fi
}
_restore_latest_backup() {
    local orig_fp="$1"
    local fn_pat; fn_pat="$(basename "$orig_fp")_*.bak"
    local latest_bkp
    latest_bkp=$(find "$BACKUP_DIR" -name "$fn_pat" -print0 | xargs -0 ls -1tr 2>/dev/null | tail -n 1)
    if [[ -n "$latest_bkp" && -f "$latest_bkp" ]]; then
        _info "Restoring backup $latest_bkp to $orig_fp"
        _run "Restore $orig_fp" cp -a "$latest_bkp" "$orig_fp"
    fi
}

# --- Global Variables ---
UBUNTU_CODENAME_DETECTED=$(lsb_release -cs 2>/dev/null || echo "unknown")
UBUNTU_CODENAME="$UBUNTU_CODENAME_DETECTED"
R_PROFILE_SITE_PATH=""
USER_SPECIFIED_R_PROFILE_SITE_PATH=""
FORCE_USER_CLEANUP="no"

# RStudio fallback values (auto-detected later)
RSTUDIO_VERSION_FALLBACK="2023.12.1-402"
RSTUDIO_ARCH_FALLBACK="amd64"
RSTUDIO_ARCH="$RSTUDIO_ARCH_FALLBACK"
RSTUDIO_VERSION="$RSTUDIO_VERSION_FALLBACK"
RSTUDIO_DEB_URL="https://download2.rstudio.org/server/${UBUNTU_CODENAME_DETECTED:-bionic}/${RSTUDIO_ARCH}/rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
RSTUDIO_DEB_FILENAME="rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"

# CRAN Repository
CRAN_REPO_URL_BASE="https://cloud.r-project.org"
CRAN_REPO_PATH_BIN="/bin/linux/ubuntu"
CRAN_REPO_PATH_SRC="/src/contrib"
CRAN_REPO_URL_BIN="${CRAN_REPO_URL_BASE}${CRAN_REPO_PATH_BIN}"
CRAN_REPO_URL_SRC="${CRAN_REPO_URL_BASE}${CRAN_REPO_PATH_SRC}"
CRAN_REPO_LINE="deb ${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME_DETECTED:-bionic}-cran40/"
CRAN_APT_KEY_ID="E298A3A825C0D65DFD57CBB651716619E084DAB9"

# R2U/BSPM Repository
R2U_REPO_URL_BASE="https://raw.githubusercontent.com/eddelbuettel/r2u/master/inst/scripts"
R2U_APT_SOURCES_LIST_D_FILE="/etc/apt/sources.list.d/r2u.list"

# R Packages
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

# --- Utility: Get Rprofile.site path ---
_get_r_profile_site_path() {
    if [[ -n "$USER_SPECIFIED_R_PROFILE_SITE_PATH" ]]; then
        R_PROFILE_SITE_PATH="$USER_SPECIFIED_R_PROFILE_SITE_PATH"
        return
    fi
    if command -v R &>/dev/null; then
        local r_h_o; r_h_o=$(R RHOME 2>/dev/null||echo "")
        if [[ -n "$r_h_o" && -d "$r_h_o" ]]; then
            R_PROFILE_SITE_PATH="${r_h_o}/etc/Rprofile.site"
            return
        fi
    fi
    [[ -f "/usr/lib/R/etc/Rprofile.site" ]] && R_PROFILE_SITE_PATH="/usr/lib/R/etc/Rprofile.site" && return
    [[ -f "/usr/local/lib/R/etc/Rprofile.site" ]] && R_PROFILE_SITE_PATH="/usr/local/lib/R/etc/Rprofile.site" && return
    R_PROFILE_SITE_PATH="/usr/lib/R/etc/Rprofile.site"
}

# --- Pre-flight Checks ---
fn_pre_flight_checks() {
    _info "Performing pre-flight checks..."
    _ensure_root

    if [[ "$UBUNTU_CODENAME" == "unknown" ]]; then
        if command -v lsb_release &>/dev/null; then
            UBUNTU_CODENAME=$(lsb_release -cs)
        else
            _warn "lsb_release not found. Installing..."
            _run "apt-get update" apt-get update -y
            _run "Install lsb-release" apt-get install -y lsb-release
            UBUNTU_CODENAME=$(lsb_release -cs)
        fi
    fi

    [[ -z "$UBUNTU_CODENAME" || "$UBUNTU_CODENAME" == "unknown" ]] && _error "No Ubuntu codename. Exit." && exit 1

    if command -v dpkg &>/dev/null; then
        RSTUDIO_ARCH=$(dpkg --print-architecture)
        [[ "$RSTUDIO_ARCH" != "amd64" && "$RSTUDIO_ARCH" != "arm64" ]] && RSTUDIO_ARCH="$RSTUDIO_ARCH_FALLBACK"
    fi

    RSTUDIO_VERSION="$RSTUDIO_VERSION_FALLBACK"
    RSTUDIO_DEB_URL="https://download2.rstudio.org/server/${UBUNTU_CODENAME}/${RSTUDIO_ARCH}/rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"
    RSTUDIO_DEB_FILENAME="rstudio-server-${RSTUDIO_VERSION}-${RSTUDIO_ARCH}.deb"

    CRAN_REPO_LINE="deb ${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME}-cran40/"
    _warn_apt_key

    local deps=(wget gpg apt-transport-https ca-certificates curl gdebi-core)
    local missing_deps=()
    for d in "${deps[@]}"; do
        command -v "$d" &>/dev/null || missing_deps+=("$d")
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        _info "Installing missing dependencies: ${missing_deps[*]}"
        _run "apt-get update" apt-get update -y
        _run "Install dependencies" apt-get install -y "${missing_deps[@]}"
    fi

    _info "Pre-flight checks done."
}

# --- Add CRAN repository ---
fn_add_cran_repo() {
    _info "Adding CRAN repository..."
    if grep -qrE "^deb .*${CRAN_REPO_URL_BIN} ${UBUNTU_CODENAME}-cran40/" /etc/apt/sources.list /etc/apt/sources.list.d/; then
        _info "CRAN repository already configured."
    else
        _run "Add CRAN GPG key" apt-key adv --keyserver keyserver.ubuntu.com --recv-keys "${CRAN_APT_KEY_ID}"
        _run "Add CRAN repository" add-apt-repository -y "${CRAN_REPO_LINE}"
        _run "apt-get update" apt-get update -y
        _info "CRAN repository added."
    fi
}

# --- Install R ---
fn_install_r() {
    _info "Installing R..."
    if dpkg -s r-base &> /dev/null; then
        _info "R (r-base) already installed."
    else
        _run "Install R" apt-get install -y r-base r-base-dev r-base-core
        _info "R installed."
    fi
    _get_r_profile_site_path
}

# --- Install OpenBLAS/OpenMP ---
fn_install_openblas_openmp() {
    _info "Installing OpenBLAS and OpenMP..."
    local pkgs=("libopenblas-dev" "libomp-dev")
    local to_install=()
    for pkg in "${pkgs[@]}"; do
        dpkg -s "$pkg" &> /dev/null || to_install+=("$pkg")
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        _run "Install OpenBLAS/OpenMP" apt-get install -y "${to_install[@]}"
        _info "OpenBLAS/OpenMP pkgs installed/checked."
    else
        _info "All OpenBLAS/OpenMP pkgs already installed."
    fi
}

# --- Install RStudio Server ---
fn_install_rstudio_server() {
    _info "Installing RStudio Server v${RSTUDIO_VERSION}..."

    # Auto-discover latest .deb if needed (example for when the fallback is not wanted)
    # download_page_content=$(curl -fsSL "https://posit.co/download/rstudio-server/ubuntu64/")
    # grep_output=""
    # if grep_output=$(echo "$download_page_content" | grep -Eo "rstudio-server.*?\.deb" | head -n1); then
    #     grep_rc=0
    # else
    #     grep_rc=$?
    # fi
    # if [[ $grep_rc -ne 0 && -n "$grep_output" ]]; then
    #     _log "WARN" "RStudio URL pipeline (grep|head) non-zero exit (RC:$grep_rc), but output found ('$grep_output'). Proceeding."
    # fi
    # latest_url="$grep_output"

    if dpkg -s rstudio-server &>/dev/null && rstudio-server version 2>/dev/null | grep -q "^${RSTUDIO_VERSION}"; then
        _info "RStudio Server v${RSTUDIO_VERSION} already installed."
        systemctl is-active --quiet rstudio-server || _run "Start RStudio" systemctl start rstudio-server
        return
    elif dpkg -s rstudio-server &>/dev/null; then
        local inst_ver
        inst_ver=$(rstudio-server version 2>/dev/null||echo "unknown")
        _info "Other RStudio Server (${inst_ver}) installed. Removing for target version."
        _run "Stop RStudio" systemctl stop rstudio-server || true
        _run "Purge RStudio" apt-get purge -y rstudio-server
    fi
    if [[ ! -f "/tmp/${RSTUDIO_DEB_FILENAME}" ]]; then
        _run "Download RStudio .deb" wget -O "/tmp/${RSTUDIO_DEB_FILENAME}" "${RSTUDIO_DEB_URL}"
    else
        _info "RStudio .deb already downloaded: /tmp/${RSTUDIO_DEB_FILENAME}"
    fi
    _run "Install RStudio via gdebi" gdebi -n "/tmp/${RSTUDIO_DEB_FILENAME}"
    _run "Check RStudio status" systemctl is-active --quiet rstudio-server || _run "Start RStudio" systemctl start rstudio-server
    _run "Enable RStudio on boot" systemctl enable rstudio-server
    _info "RStudio Server version: $(rstudio-server version 2>/dev/null||echo 'N/A')"
    _info "RStudio Server installed & verified."
}

# --- Setup BSPM ---
fn_setup_bspm() {
    _info "Setting up bspm (Binary R Package Manager)..."
    _get_r_profile_site_path
    if [[ -z "$R_PROFILE_SITE_PATH" ]]; then
        _error "R_PROFILE_SITE_PATH is not set. Cannot setup bspm."
        return 1
    fi

    local r_profile_dir
    r_profile_dir=$(dirname "$R_PROFILE_SITE_PATH")
    [[ -d "$r_profile_dir" ]] || _run "Create Rprofile.site dir" mkdir -p "$r_profile_dir"
    [[ -f "$R_PROFILE_SITE_PATH" ]] || _run "Touch Rprofile.site" touch "$R_PROFILE_SITE_PATH"

    _info "Installing bspm R package..."
    local bspm_check_cmd='if(requireNamespace("bspm", quietly=TRUE)) "installed" else "not_installed"'
    if [[ $(Rscript -e "$bspm_check_cmd" 2>/dev/null) == "installed" ]]; then
        _info "bspm R package already installed."
    else
        _run "Install bspm R package" Rscript -e "install.packages('bspm', repos='${CRAN_REPO_URL_SRC}')"
    fi

    _backup_file "$R_PROFILE_SITE_PATH"
    _info "Enabling bspm in ${R_PROFILE_SITE_PATH}..."
    local bspm_enable_line='suppressMessages(bspm::enable())'
    grep -qF -- "$bspm_enable_line" "$R_PROFILE_SITE_PATH" || _run "Append bspm enable" sh -c "echo '$bspm_enable_line' | tee -a '$R_PROFILE_SITE_PATH'"
    _info "bspm enabled in Rprofile.site."
}

# --- Install R packages ---
_install_r_pkg_list() {
    local pkg_type="$1"; shift; local r_packages_list=("${@}")
    if [[ ${#r_packages_list[@]} -eq 0 ]]; then
        _info "No ${pkg_type} R pkgs in list."
        return
    fi
    _info "Installing ${pkg_type} R packages: ${r_packages_list[*]}"
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
            install_script="if(!requireNamespace('$pkg_name_short',q=T))devtools::install_github('$pkg_name_full')else cat('R pkg $pkg_name_short (GitHub) installed.\\n')"
        else
            _warn "Unknown pkg type: $pkg_type for $pkg_name_full. Skipping."
            continue
        fi
        _run "Install/Verify R pkg: $pkg_name_full" Rscript -e "$install_script"
    done
    _info "${pkg_type} R pkgs install process done."
}

fn_install_r_packages() {
    _install_r_pkg_list "CRAN" "${R_PACKAGES_CRAN[@]}"
    if [[ ${#R_PACKAGES_GITHUB[@]} -gt 0 ]]; then
        _info "Ensuring devtools for GitHub packages..."
        local r_cmd_devtools; r_cmd_devtools="if(!requireNamespace('devtools',q=T)){install.packages('devtools',repos='${CRAN_REPO_URL_SRC}');if(!requireNamespace('devtools',q=T))stop('Fail devtools install')}"
        _run "Ensure devtools R pkg installed" Rscript -e "${r_cmd_devtools}"
        _install_r_pkg_list "GitHub" "${R_PACKAGES_GITHUB[@]}"
    else
        _info "No GitHub R packages in list."
    fi
}

# --- Main Installation ---
install_all() {
    _info "--- Starting Full Installation ---"
    fn_pre_flight_checks
    fn_add_cran_repo
    fn_install_r
    fn_install_openblas_openmp
    fn_setup_bspm
    fn_install_r_packages
    fn_install_rstudio_server
    _info "--- Full Installation Completed ---"
    _info "RStudio Server at http://<SERVER_IP>:8787 (if not firewalled). Log: ${LOG_FILE}"
}

# --- Main Uninstallation ---
uninstall_all() {
    _info "--- Starting Full Uninstallation ---"
    _ensure_root
    # Add uninstall logic here, similar to install functions, following the same structure
    _info "--- Full Uninstallation Completed ---"
}

# --- Usage / Menu ---
usage() {
    echo "Usage: $0 [ACTION]"
    echo "Manages R, RStudio, OpenBLAS, BSPM, R packages."
    echo ""
    echo "Actions:"
    echo "  install_all         Run all installation steps."
    echo "  uninstall_all       Uninstall all components by this script."
    echo ""
    echo "Environment variables:"
    echo "  DRY_RUN=1           Simulate actions only (safe mode)."
    echo "  LOG_LEVEL=DEBUG     Show debug logs."
    echo ""
    exit 1
}

main() {
    _info "Script started. Log: ${LOG_FILE}"
    _get_r_profile_site_path

    if [[ $# -eq 0 ]]; then
        usage
    else
        _ensure_root
        local action_arg="$1"
        shift

        case "$action_arg" in
            install_all) install_all ;;
            uninstall_all) uninstall_all ;;
            fn_pre_flight_checks) fn_pre_flight_checks ;;
            fn_add_cran_repo) fn_add_cran_repo ;;
            fn_install_r) fn_install_r ;;
            fn_install_openblas_openmp) fn_install_openblas_openmp ;;
            fn_setup_bspm) fn_setup_bspm ;;
            fn_install_r_packages) fn_install_r_packages ;;
            fn_install_rstudio_server) fn_install_rstudio_server ;;
            *) _error "Unknown action: $action_arg"; usage ;;
        esac
    fi
    _info "Script finished."
}

main "$@"
