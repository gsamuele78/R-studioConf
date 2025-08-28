#!/usr/bin/env bash

##############################################################################
# Script: r_env_manager.sh
# Desc:   Installs, configures, and manages R, OpenBLAS, OpenMP, RStudio Server,
#         BSPM, and R packages. Includes auto-detection, uninstall, backup/restore.
# Author: Your Name/Team
# Date:   $(date +%Y-%m-%d)
##############################################################################


# --- Refactored Configuration ---
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Source config file for all variables
CONFIG_FILE="$(dirname "$0")/config/r_env_manager.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config file $CONFIG_FILE not found. Exiting." >&2
    exit 1
fi

# Source shared functions
COMMON_UTILS="$(dirname "$0")/lib/common_utils.sh"
if [[ -f "$COMMON_UTILS" ]]; then
    source "$COMMON_UTILS"
else
    echo "ERROR: Common utils $COMMON_UTILS not found. Exiting." >&2
    exit 1
fi

# If CUSTOM_R_PROFILE_SITE_PATH_ENV is set, override config
if [[ -n "${CUSTOM_R_PROFILE_SITE_PATH_ENV:-}" ]]; then
    USER_SPECIFIED_R_PROFILE_SITE_PATH="${CUSTOM_R_PROFILE_SITE_PATH_ENV}"
fi

# --- Helper Functions ---

log_init_if_needed() {
    if [[ -z "$LOG_FILE" ]]; then
        if [[ "${EUID}" -eq 0 ]]; then
            mkdir -p "$LOG_DIR"
            LOG_FILE="${LOG_DIR}/r_setup_$(date +'%Y%m%d_%H%M%S').log"
            touch "$LOG_FILE"
            chmod 640 "$LOG_FILE"
        else
            LOG_FILE="/dev/stderr"
        fi
    fi
    if [[ "${EUID}" -eq 0 ]]; then
        mkdir -p "$BACKUP_DIR"
    fi
}

log() {
    local type="$1"
    local message="$2"
    if [[ -n "$LOG_FILE" && ( "$LOG_FILE" == "/dev/stderr" || -w "$LOG_FILE" ) ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${type}] ${message}" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${type}] ${message}" >&2
    fi
}

ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] This script must be run as root or with sudo." >&2
        exit 1
    fi
}

run_command() {
    local cmd_desc="$1"; shift
    log "INFO" "Start: $cmd_desc"
    log "DEBUG" "Executing in run_command: $*"
    if [[ "$1" == "mv" ]]; then
        log "DEBUG" "mv source details: $(ls -ld "$2" 2>&1 || echo "source $2 not found")"
        log "DEBUG" "mv target details: $(ls -ld "$3" 2>&1 || echo "target $3 not found")"
        log "DEBUG" "mv target parent dir details: $(ls -ld "$(dirname "$3")" 2>&1 || echo "target parent dir for $3 not found")"
    fi
    if "$@" >>"$LOG_FILE" 2>&1; then
        log "INFO" "OK: $cmd_desc"
        return 0
    else
        local exit_code=$?
        log "ERROR" "FAIL: $cmd_desc (RC:$exit_code). See log: $LOG_FILE"
        if [ -f "$LOG_FILE" ] && [ "$LOG_FILE" != "/dev/stderr" ]; then
            tail -n 10 "$LOG_FILE" | sed 's/^/    /'
        fi
        return "$exit_code"
    fi
}

backup_file() {
    local filepath="$1"
    if [[ -f "$filepath" || -L "$filepath" ]]; then
        local backup_filename
        backup_filename="$(basename "$filepath")_$(date +'%Y%m%d%H%M%S').bak"
        log "INFO" "Backing up '${filepath}' to '${BACKUP_DIR}/${backup_filename}'"
        cp -a "$filepath" "${BACKUP_DIR}/${backup_filename}"
    else
        log "INFO" "File '${filepath}' not found for backup. Skipping."
    fi
}

restore_latest_backup() {
    local original_filepath="$1"
    local filename_pattern
    local latest_backup
    filename_pattern="$(basename "$original_filepath")_*.bak"
    latest_backup=$(find "$BACKUP_DIR" -name "$filename_pattern" -print0 | xargs -0 ls -1tr 2>/dev/null | tail -n 1)
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        log "INFO" "Restoring '${original_filepath}' from latest backup '${latest_backup}'"
        cp -a "$latest_backup" "$original_filepath"
    else
        log "INFO" "No backup found for '${original_filepath}' in '${BACKUP_DIR}' with pattern '${filename_pattern}'. Skipping restore."
    fi
}

get_r_profile_site_path() {
    local log_details=false
    if [[ -z "$R_PROFILE_SITE_PATH" && -z "$USER_SPECIFIED_R_PROFILE_SITE_PATH" ]]; then
        log_details=true
    fi
    if $log_details; then log "INFO" "Determining Rprofile.site path..."; fi
    if [[ -n "$USER_SPECIFIED_R_PROFILE_SITE_PATH" ]]; then
        if [[ "$R_PROFILE_SITE_PATH" != "$USER_SPECIFIED_R_PROFILE_SITE_PATH" ]]; then
            R_PROFILE_SITE_PATH="$USER_SPECIFIED_R_PROFILE_SITE_PATH"
            log "INFO" "Using user-specified R_PROFILE_SITE_PATH: ${R_PROFILE_SITE_PATH}"
        fi
        return
    fi
    if command -v R &>/dev/null; then
        local r_home_output
        r_home_output=$(R RHOME 2>/dev/null || echo "")
        if [[ -n "$r_home_output" && -d "$r_home_output" ]]; then
            local detected_path="${r_home_output}/etc/Rprofile.site"
            if [[ "$R_PROFILE_SITE_PATH" != "$detected_path" ]]; then
                log "INFO" "Auto-detected R_PROFILE_SITE_PATH (from R RHOME): ${detected_path}"
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
            log "INFO" "Auto-detected R_PROFILE_SITE_PATH (apt default): ${new_detected_path}"
        fi
    elif [[ -f "$default_local_path" || -L "$default_local_path" ]]; then
        new_detected_path="$default_local_path"
        if $log_details || [[ "$R_PROFILE_SITE_PATH" != "$new_detected_path" ]]; then
            log "INFO" "Auto-detected R_PROFILE_SITE_PATH (local default): ${new_detected_path}"
        fi
    else
        new_detected_path="$default_apt_path"
        if $log_details || [[ "$R_PROFILE_SITE_PATH" != "$new_detected_path" ]]; then
            log "INFO" "No Rprofile.site found. Defaulting to standard location for creation: ${new_detected_path}"
        fi
    fi
    R_PROFILE_SITE_PATH="$new_detected_path"
}

safe_systemctl() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl "$@" >> "$LOG_FILE" 2>&1; then
            return 0
        else
            local exit_code=$?
            log "ERROR" "systemctl command '$*' failed (RC:$exit_code)."
            return "$exit_code"
        fi
    else
        log "INFO" "systemctl command not found, skipping systemctl action: $*"
        return 0
    fi
}

is_vm_or_ci_env() {
    if [[ "${CI:-false}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]] || [[ -n "${TRAVIS:-}" ]]; then
        return 0
    elif [[ "$EUID" -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# --- Core Functions ---
get_latest_rstudio_info() {
    # Query the latest RStudio Server version and architecture from the official site or fallback
    log "INFO" "Detecting latest RStudio Server version and architecture..."
    local latest_version latest_arch
    latest_version="$RSTUDIO_VERSION_FALLBACK"
    latest_arch="$RSTUDIO_ARCH_FALLBACK"
    # Try to fetch latest version info (robust fallback)
    local json_url="https://rstudio.com/products/rstudio/download-server/"
    local html
    html=$(curl -fsSL "$json_url" 2>/dev/null || true)
    if [[ -n "$html" ]]; then
        latest_version=$(echo "$html" | grep -Eo 'rstudio-server-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | head -n1)
        latest_arch=$(echo "$html" | grep -Eo 'amd64|arm64' | head -n1)
        if [[ -n "$latest_version" ]]; then
            RSTUDIO_VERSION="$latest_version"
        fi
        if [[ -n "$latest_arch" ]]; then
            RSTUDIO_ARCH="$latest_arch"
        fi
    fi
    RSTUDIO_DEB_FILENAME="rstudio-server-${RSTUDIO_VERSION}_${RSTUDIO_ARCH}.deb"
    RSTUDIO_DEB_URL="https://download2.rstudio.org/server/${RSTUDIO_ARCH}/ubuntu/${RSTUDIO_DEB_FILENAME}"
    log "INFO" "Using RStudio Server version: $RSTUDIO_VERSION, arch: $RSTUDIO_ARCH"
    log "INFO" "Download URL: $RSTUDIO_DEB_URL"
}

pre_flight_checks() {
    log_init_if_needed
    ensure_root
    log "INFO" "Pre-flight checks: OS, network, permissions, disk space..."
    if ! command -v apt-get &>/dev/null; then
        log "ERROR" "apt-get not found. This script requires a Debian/Ubuntu system."
        exit 1
    fi
    if ! ping -c 1 cloud.r-project.org &>/dev/null; then
        log "WARN" "Network check: Unable to reach CRAN. Continuing, but package installs may fail."
    fi
    if [[ $(df / | tail -1 | awk '{print $4}') -lt 1048576 ]]; then
        log "WARN" "Low disk space on root filesystem. At least 1GB recommended."
    fi
}

setup_cran_repo() {
    log "INFO" "Setting up CRAN repository..."
    UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
    CRAN_REPO_LINE="deb [signed-by=${CRAN_APT_KEYRING_FILE}] ${CRAN_REPO_URL_BIN}/${UBUNTU_CODENAME} ./"
    run_command "Add CRAN apt key" wget -qO- "$CRAN_APT_KEY_URL" | gpg --dearmor | tee "$CRAN_APT_KEYRING_FILE" >/dev/null
    echo "$CRAN_REPO_LINE" > /etc/apt/sources.list.d/cran.list
    run_command "apt-get update" apt-get update
}

install_r() {
    log "INFO" "Installing R base and recommended packages..."
    run_command "apt-get install R base" apt-get install -y --no-install-recommends r-base r-base-dev
}

install_openblas_openmp() {
    log "INFO" "Installing OpenBLAS and OpenMP..."
    run_command "apt-get install OpenBLAS/OpenMP" apt-get install -y libopenblas-dev libomp-dev
}

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

    local r_profile_dir; r_profile_dir=$(dirname "$R_PROFILE_SITE_PATH")
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
        local r2u_add_script_url="${R2U_REPO_URL_BASE}/add_cranapt_${UBUNTU_CODENAME}.sh"
        log "INFO" "Downloading R2U setup script: ${r2u_add_script_url}"
        run_command "Download R2U setup script" curl -sSLf "${r2u_add_script_url}" -o /tmp/add_cranapt.sh
        log "INFO" "Executing R2U repository setup script..."
        if ! sudo bash /tmp/add_cranapt.sh 2>&1 | sudo tee -a "$LOG_FILE"; then
            log "ERROR" "Failed to execute R2U repository setup script."
            return 1
        fi
        rm -f /tmp/add_cranapt.sh
    fi

    if systemctl list-units --type=service | grep -q dbus.service; then
        log "INFO" "Restarting dbus service..."
        sudo systemctl restart dbus.service
    elif service --status-all 2>&1 | grep -q dbus.service; then
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
bspm_status_rc=$?
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

install_r_build_deps() {
    log "INFO" "Installing common system dependencies for building R packages from source (e.g., for devtools)..."
    local build_deps=(
        build-essential libcurl4-openssl-dev libssl-dev libxml2-dev libgit2-dev \
        libfontconfig1-dev libcairo2-dev libharfbuzz-dev libfribidi-dev libfreetype6-dev \
        libpng-dev libtiff5-dev libjpeg-dev zlib1g-dev libbz2-dev liblzma-dev \
        libreadline-dev libicu-dev libxt-dev cargo libgdal-dev libproj-dev \
        libgeos-dev libudunits2-dev
    )
    run_command "Update apt cache before installing build deps" apt-get update -y
    run_command "Install R package build dependencies" apt-get install -y "${build_deps[@]}"
    log "INFO" "System dependencies for R package building installed."
}

install_r_pkg_list() {
    local pkg_type="$1"; shift
    local r_packages_list=("$@")

    if [[ ${#r_packages_list[@]} -eq 0 ]]; then
        log "INFO" "No ${pkg_type} R packages specified in the list to install."
        return
    fi

    log "INFO" "Processing ${pkg_type} R packages for installation: ${r_packages_list[*]}"

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
                log "WARN" "GITHUB_PAT environment variable is not set. GitHub API rate limits may be encountered for installing packages like '${pkg_name_full}'. See script comments for GITHUB_PAT setup."
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
            log "WARN" "Unknown package type '${pkg_type}' for package '${pkg_name_full}'. Skipping."
            continue 
        fi

        echo "$r_install_cmd" > "$pkg_install_script_path"
        if ! run_command "Install/Verify R pkg ($pkg_type): $pkg_name_full" Rscript "$pkg_install_script_path"; then
            log "ERROR" "Failed to install R package '${pkg_name_full}'. See R output in the log above."
        fi
    done
    rm -f "$pkg_install_script_path" 
    log "INFO" "${pkg_type} R packages installation process completed."
}

install_r_packages() {
    log "INFO" "Starting R package installation process..."
    install_r_build_deps

    log "INFO" "Ensuring 'devtools' and 'remotes' R packages are installed..."
    local core_r_dev_pkgs=("devtools" "remotes")
    local r_pkgs_to_ensure_str="c(\"devtools\", \"remotes\")"
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
        log "ERROR" "Failed to install one or more core R development packages (devtools/remotes). RC: $r_script_rc. Check log."
    else
        log "INFO" "Core R development packages (devtools/remotes) are installed/verified."
    fi

    install_r_pkg_list "CRAN" "${R_PACKAGES_CRAN[@]}"

    if [[ ${#R_PACKAGES_GITHUB[@]} -gt 0 ]]; then
        log "INFO" "Installing GitHub R packages using remotes/devtools..."
        [[ -n "${GITHUB_PAT:-}" ]] && export GITHUB_PAT
        install_r_pkg_list "GitHub" "${R_PACKAGES_GITHUB[@]}"
    else
        log "INFO" "No GitHub R packages listed for installation."
    fi

    log "INFO" "Listing installed R packages and their installation type (bspm/binary or source)..."
    local r_list_pkgs_cmd_file="/tmp/list_installed_pkgs.R"
cat > "$r_list_pkgs_cmd_file" <<'EOF'
get_install_type <- function(pkg_name, installed_pkgs_df) {
    install_type <- "source/unknown"
    if (! pkg_name %in% rownames(installed_pkgs_df)) {
        return("not_found_in_df")
    }
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
installed_pkgs_df_raw <- as.data.frame(installed.packages(fields = ip_fields, noCache=TRUE), stringsAsFactors = FALSE) 

if (nrow(installed_pkgs_df_raw) == 0) {
    cat("No R packages appear to be installed.\n")
} else {
    installed_pkgs_df <- installed_pkgs_df_raw[!duplicated(installed_pkgs_df_raw$Package), ]
    installed_pkgs_df$InstallType <- "pending"
    if (nrow(installed_pkgs_df) > 0 && "Package" %in% colnames(installed_pkgs_df)) {
        rownames(installed_pkgs_df) <- installed_pkgs_df$Package 
    } else if (nrow(installed_pkgs_df) > 0) {
         cat("Warning: 'Package' column not found for setting rownames after deduplication.\n", file=stderr())
    }
    for (i in seq_len(nrow(installed_pkgs_df))) {
        pkg_name <- installed_pkgs_df[i, "Package"]
        if (pkg_name %in% rownames(installed_pkgs_df)) {
            installed_pkgs_df[i, "InstallType"] <- tryCatch(
                get_install_type(pkg_name, installed_pkgs_df),
                error = function(e) "error_determining"
            )
        } else {
             installed_pkgs_df[i, "InstallType"] <- "pkg_name_not_in_rownames"
        }
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
    if ! run_command "List installed R packages with types" Rscript "$r_list_pkgs_cmd_file"; then
        log "WARN" "R script for listing packages encountered an error. List may be incomplete or missing."
    fi
    rm -f "$r_list_pkgs_cmd_file"
    log "INFO" "R package installation and listing process finished."
}

uninstall_r_packages() {
    log "INFO" "Attempting to uninstall R packages specified by this script..."
    local all_pkgs_to_remove_short_names=("${R_PACKAGES_CRAN[@]}")
    for gh_pkg_full_name in "${R_PACKAGES_GITHUB[@]}"; do
        all_pkgs_to_remove_short_names+=("$(basename "${gh_pkg_full_name%.git}")")
    done
    local unique_pkgs_to_remove_list=()
    mapfile -t unique_pkgs_to_remove_list < <(printf "%s\n" "${all_pkgs_to_remove_short_names[@]}" | sort -u)
    if [[ ${#unique_pkgs_to_remove_list[@]} -eq 0 ]]; then
        log "INFO" "No R packages found in script lists to attempt removal after unique sort."
        return
    fi
    log "INFO" "Will attempt to remove these R packages: ${unique_pkgs_to_remove_list[*]}"
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
        log "INFO" "Package list for R removal script is empty after processing. Skipping."
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
    log "INFO" "R script for package removal prepared at ${r_pkg_removal_script_file}"
    local r_removal_rc=0
    ( Rscript "$r_pkg_removal_script_file" >>"$LOG_FILE" 2>&1 ) || r_removal_rc=$?
    rm -f "$r_pkg_removal_script_file"
    if [[ $r_removal_rc -eq 0 ]]; then
        log "INFO" "R package uninstallation script completed successfully."
    else
        log "WARN" "R package uninstallation script finished with errors (Rscript Exit Code: $r_removal_rc). Check log for details."
    fi
    log "INFO" "R package uninstallation attempt finished."
}

remove_bspm_config() {
    log "INFO" "Removing bspm configuration from Rprofile.site and R2U apt repository..."
    get_r_profile_site_path
    if [[ -n "$R_PROFILE_SITE_PATH" && (-f "$R_PROFILE_SITE_PATH" || -L "$R_PROFILE_SITE_PATH") ]]; then
        log "INFO" "Removing bspm configuration lines from '${R_PROFILE_SITE_PATH}'."
        backup_file "$R_PROFILE_SITE_PATH"
        local temp_rprofile_cleaned
        temp_rprofile_cleaned=$(mktemp)
        sed '/# Added by setup_r_env.sh for bspm configuration/,/# End of bspm configuration/d' "$R_PROFILE_SITE_PATH" > "$temp_rprofile_cleaned"
        if ! cmp -s "$R_PROFILE_SITE_PATH" "$temp_rprofile_cleaned"; then
            if run_command "Update Rprofile.site (remove bspm block)" mv "$temp_rprofile_cleaned" "$R_PROFILE_SITE_PATH"; then
                 log "INFO" "Removed bspm configuration block from '${R_PROFILE_SITE_PATH}'."
            else
                log "ERROR" "Failed to update Rprofile.site after attempting to remove bspm block. Restoring backup."
                restore_latest_backup "$R_PROFILE_SITE_PATH"
                rm -f "$temp_rprofile_cleaned"
            fi
        else
            log "INFO" "No bspm configuration block (matching markers) found in '${R_PROFILE_SITE_PATH}', or file was unchanged. Cleaning up temporary file."
            rm -f "$temp_rprofile_cleaned"
        fi
    else
        log "INFO" "Rprofile.site ('${R_PROFILE_SITE_PATH:-not set or found}') not found or path not determined. Skipping bspm configuration removal from it."
    fi
    log "INFO" "Removing R2U apt repository configuration..."
    local r2u_apt_pattern="r2u.stat.illinois.edu"
    if [[ -f "$R2U_APT_SOURCES_LIST_D_FILE" ]]; then
        log "INFO" "Removing R2U repository file: '${R2U_APT_SOURCES_LIST_D_FILE}'."
        run_command "Remove R2U sources file '${R2U_APT_SOURCES_LIST_D_FILE}'" rm -f "$R2U_APT_SOURCES_LIST_D_FILE"
    fi
    find /etc/apt/sources.list /etc/apt/sources.list.d/ -type f -name '*.list' -print0 | \
    while IFS= read -r -d $'\0' apt_list_file; do
        if grep -q "$r2u_apt_pattern" "$apt_list_file"; then
            log "INFO" "R2U entry found in '${apt_list_file}'. Backing up and removing entry."
            backup_file "$apt_list_file"
            run_command "Remove R2U entry from '${apt_list_file}'" sed -i.r2u_removed_bak "/${r2u_apt_pattern}/d" "$apt_list_file"
        fi
    done
    local r2u_keyring_pattern="r2u-cran-archive-keyring.gpg"
    find /etc/apt/keyrings/ -name "$r2u_keyring_pattern" -type f -print0 | while IFS= read -r -d $'\0' key_file; do
        log "INFO" "Removing R2U GPG keyring file: '$key_file'"
        run_command "Remove R2U GPG keyring '$key_file'" rm -f "$key_file"
    done
    log "INFO" "R2U apt repository configuration removal process finished."
    log "INFO" "Consider running 'apt-get update' after these changes."
}

remove_cran_repo() {
    log "INFO" "Removing this script's CRAN apt repository configuration..."
    local cran_line_pattern_to_remove_escaped
    cran_line_pattern_to_remove_escaped=$(printf '%s' "$CRAN_REPO_LINE" | sed 's|[&/\]|\\&|g')
    find /etc/apt/sources.list /etc/apt/sources.list.d/ -type f -name '*.list' -print0 | \
    while IFS= read -r -d $'\0' apt_list_file; do
        if grep -qF "${CRAN_REPO_LINE}" "$apt_list_file"; then
            log "INFO" "CRAN repository entry (matching simple format) found in '${apt_list_file}'. Backing up and removing."
            backup_file "$apt_list_file"
            run_command "Remove CRAN entry from '${apt_list_file}'" sed -i.cran_removed_bak "\#${cran_line_pattern_to_remove_escaped}#d" "$apt_list_file"
        fi
    done
    log "INFO" "Removing CRAN GPG key file '${CRAN_APT_KEYRING_FILE}'..."
    if [[ -f "$CRAN_APT_KEYRING_FILE" ]]; then
        run_command "Remove CRAN GPG key file '${CRAN_APT_KEYRING_FILE}'" rm -f "$CRAN_APT_KEYRING_FILE"
    else
        log "INFO" "CRAN GPG key file '${CRAN_APT_KEYRING_FILE}' not found."
    fi
    log "INFO" "CRAN apt repository configuration removal finished."
    log "INFO" "Consider running 'apt-get update' after these changes."
}

uninstall_system_packages() {
    log "INFO" "Uninstalling system packages installed by this script (RStudio Server, R, OpenBLAS, OpenMP, bspm)..."
    if dpkg -s rstudio-server &>/dev/null; then
        log "INFO" "Stopping and purging RStudio Server..."
        run_command "Stop RStudio Server" safe_systemctl stop rstudio-server
        run_command "Disable RStudio Server from boot" safe_systemctl disable rstudio-server
        run_command "Purge RStudio Server package" apt-get purge -y rstudio-server
    else
        log "INFO" "RStudio Server package (rstudio-server) not found, or already removed."
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
        log "INFO" "The following system packages will be purged: ${actual_pkgs_to_purge[*]}"
        run_command "Purge specified system packages" apt-get purge -y "${actual_pkgs_to_purge[@]}"
    else
        log "INFO" "None of the targeted system packages (R, bspm, OpenBLAS, etc.) are currently installed, or they were already removed."
    fi
    log "INFO" "Running apt autoremove and autoclean to remove unused dependencies and clean cache..."
    run_command "Run apt autoremove" apt-get autoremove -y
    run_command "Run apt autoclean" apt-get autoclean -y
    log "INFO" "Updating apt cache after removals..."
    run_command "Update apt cache" apt-get update -y
    log "INFO" "System package uninstallation process finished."
}

remove_leftover_files() {
    log "INFO" "Removing leftover R and RStudio Server related files and directories..."
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
            log "INFO" "Directory '/etc/R' or its contents appear to be owned by an installed package. Skipping its direct removal."
        else
            log "INFO" "Directory '/etc/R' seems unowned by any package. Adding it to the removal list."
            paths_to_remove+=("/etc/R")
        fi
    fi
    for path_item in "${paths_to_remove[@]}"; do
        if [[ -d "$path_item" ]]; then
            log "INFO" "Attempting to remove directory: '${path_item}'"
            run_command "Remove directory '${path_item}'" rm -rf "$path_item"
        elif [[ -f "$path_item" || -L "$path_item" ]]; then
            log "INFO" "Attempting to remove file/symlink: '${path_item}'"
            run_command "Remove file/symlink '${path_item}'" rm -f "$path_item"
        else
            log "INFO" "Path '${path_item}' not found, or already removed. Skipping."
        fi
    done
    if [[ -n "${RSTUDIO_DEB_FILENAME:-}" && -f "/tmp/${RSTUDIO_DEB_FILENAME}" ]]; then
        log "INFO" "Removing downloaded RStudio Server .deb file: '/tmp/${RSTUDIO_DEB_FILENAME}'"
        rm -f "/tmp/${RSTUDIO_DEB_FILENAME}"
    else
        log "INFO" "No RStudio .deb file matching known filename ('${RSTUDIO_DEB_FILENAME:-not set}') found in /tmp."
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
            log "INFO" "FORCE_USER_CLEANUP is 'yes'. Proceeding with aggressive user-level R data removal."
            perform_aggressive_user_cleanup=true
        elif $is_interactive_shell; then
            log "WARN" "PROMPT: You are about to perform an AGGRESSIVE cleanup of R-related data from user home directories."
            log "WARN" "This includes ~/.R, ~/R, ~/.config/R*, ~/.cache/R*, ~/.rstudio, etc., for ALL users with UID >= 1000."
            log "WARN" "THIS IS DESTRUCTIVE AND CANNOT BE UNDONE."
            read -r -p "Are you sure you want to remove these user-level R files and directories? (Type 'yes' to proceed, anything else to skip): " aggressive_confirm_response
            if [[ "$aggressive_confirm_response" == "yes" ]]; then
                perform_aggressive_user_cleanup=true
            else
                log "INFO" "Skipping aggressive user-level R cleanup based on user response."
            fi
        fi
        if [[ "$perform_aggressive_user_cleanup" == "true" ]]; then
            log "INFO" "Starting aggressive user-level R configuration and library cleanup..."
            awk -F: '$3 >= 1000 && $3 < 60000 && $6 != "" && $6 != "/nonexistent" && $6 != "/" {print $6}' /etc/passwd | while IFS= read -r user_home_dir; do
                if [[ -d "$user_home_dir" ]]; then
                    log "INFO" "Scanning user home directory for R data: '${user_home_dir}'"
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
                            log "WARN" "Aggressive Cleanup: Removing '${r_path_to_check}'"
                            if [[ "$r_path_to_check" != "$user_home_dir" && "$r_path_to_check" == "$user_home_dir/"* ]]; then
                                run_command "Aggressively remove user R path '${r_path_to_check}'" rm -rf "$r_path_to_check"
                            else
                                log "ERROR" "Safety break: Skipped removing suspicious path '${r_path_to_check}'."
                            fi
                        fi
                    done
                else
                    log "INFO" "User home directory '${user_home_dir}' listed in /etc/passwd does not exist. Skipping."
                fi
            done
            log "INFO" "Aggressive user-level R data cleanup attempt finished."
        fi
    else
        log "INFO" "Skipping aggressive user-level R data cleanup."
    fi
    log "INFO" "Leftover file and directory removal process finished."
}

# --- Main Execution Functions ---
install_all() {
    log "INFO" "--- Starting Full R Environment Installation ---"
    pre_flight_checks
    setup_cran_repo
    install_r
    install_openblas_openmp
    if ! verify_openblas_openmp; then 
        log "WARN" "OpenBLAS/OpenMP verification encountered issues or failed. Installation will continue, but performance or stability might be affected. Review logs carefully."
    else
        log "INFO" "OpenBLAS/OpenMP verification passed."
    fi
    if ! setup_bspm; then 
        log "ERROR" "BSPM (R2U Binary Package Manager) setup failed. Subsequent R package installations might not use bspm correctly."
    else
        log "INFO" "BSPM setup appears successful."
    fi
    install_r_packages 
    install_rstudio_server
    log "INFO" "--- Full R Environment Installation Completed ---"
    log "INFO" "Summary:"
    log "INFO" "- R version: $(R --version | head -n 1 || echo 'Not found')"
    log "INFO" "- RStudio Server version: $(rstudio-server version 2>/dev/null || echo 'Not found/not running')"
    log "INFO" "- RStudio Server URL: http://<YOUR_SERVER_IP>:8787 (if not firewalled)"
    log "INFO" "- BSPM status: Check logs from setup_bspm and install_r_packages."
    log "INFO" "- Main log file for this session: ${LOG_FILE}"
    log "INFO" "- State file (for individual function calls): ${R_ENV_STATE_FILE}"
}

uninstall_all() {
    log "INFO" "--- Starting Full R Environment Uninstallation ---"
    ensure_root
    get_r_profile_site_path
    if [[ -f "$R_ENV_STATE_FILE" ]]; then
        log "INFO" "Uninstall: Sourcing state from ${R_ENV_STATE_FILE}"
        source "$R_ENV_STATE_FILE"
    fi
    uninstall_r_packages
    remove_bspm_config
    uninstall_system_packages
    remove_cran_repo
    remove_leftover_files
    log "INFO" "--- Verification of Uninstallation ---"
    local verification_issues_found=0
    if command -v R &>/dev/null; then log "WARN" "VERIFICATION FAIL: 'R' command still found."; ((verification_issues_found++)); else log "INFO" "VERIFICATION OK: 'R' command not found."; fi
    if command -v Rscript &>/dev/null; then log "WARN" "VERIFICATION FAIL: 'Rscript' command still found."; ((verification_issues_found++)); else log "INFO" "VERIFICATION OK: 'Rscript' command not found."; fi
    if command -v rstudio-server &>/dev/null; then log "WARN" "VERIFICATION FAIL: 'rstudio-server' command still found."; ((verification_issues_found++)); fi
    local pkgs_to_check_absent=("rstudio-server" "r-base" "r-cran-bspm" "libopenblas-dev" "libomp-dev")
    for pkg_check in "${pkgs_to_check_absent[@]}"; do
        if dpkg -s "$pkg_check" &>/dev/null; then
            log "WARN" "VERIFICATION FAIL: Package '$pkg_check' is still installed."
            ((verification_issues_found++))
        else
            log "INFO" "VERIFICATION OK: Package '$pkg_check' is not installed."
        fi
    done
    log "INFO" "VERIFICATION: Check logs from 'remove_bspm_config' and 'remove_cran_repo' to confirm apt sources were removed."
    if [[ $verification_issues_found -eq 0 ]]; then
        log "INFO" "--- Full R Environment Uninstallation Completed Successfully (based on checks) ---"
    else
        log "ERROR" "--- Full R Environment Uninstallation Completed with ${verification_issues_found} verification issue(s). ---"
        log "ERROR" "Manual inspection of the system and the log file ('${LOG_FILE}') is recommended to ensure complete removal."
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
    echo "  pre_flight_checks, setup_cran_repo, install_r, install_openblas_openmp, verify_openblas_openmp, setup_bspm, install_r_packages, install_rstudio_server, uninstall_r_packages, remove_bspm_config, uninstall_system_packages, remove_cran_repo, remove_leftover_files"
    echo ""
    echo "Log file for this session will be in: ${LOG_DIR}/r_setup_YYYYMMDD_HHMMSS.log"
    exit 1
}

interactive_menu() {
    ensure_root
    if [[ -f "$R_ENV_STATE_FILE" ]]; then
        source "$R_ENV_STATE_FILE"
    fi
    get_r_profile_site_path
    while true; do
        local display_rstudio_version="$RSTUDIO_VERSION_FALLBACK"
        if [[ -n "${UBUNTU_CODENAME:-}" && -n "${RSTUDIO_ARCH:-}" ]]; then
            if [[ -f "$R_ENV_STATE_FILE" ]]; then
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
            2) pre_flight_checks ;;
            3) pre_flight_checks; setup_cran_repo; install_r ;;
            4) pre_flight_checks; install_openblas_openmp ;;
            5) pre_flight_checks; install_r; install_openblas_openmp; verify_openblas_openmp ;;
            6) pre_flight_checks; install_r; setup_bspm ;;
            7) pre_flight_checks; install_r; setup_bspm; install_r_packages ;;
            8) pre_flight_checks; install_r; install_rstudio_server ;;
            9) uninstall_all ;;
            F|f)
                if [[ "$FORCE_USER_CLEANUP" == "yes" ]]; then
                    FORCE_USER_CLEANUP="no"
                    log "INFO" "Aggressive user data cleanup during uninstall TOGGLED OFF."
                else
                    FORCE_USER_CLEANUP="yes"
                    log "INFO" "Aggressive user data cleanup during uninstall TOGGLED ON."
                fi
                ;;
            0) log "INFO" "Exiting interactive menu."; exit 0 ;;
            *) log "WARN" "Invalid option: '$option'. Please try again." ;;
        esac
        echo ""
        read -r -p "Action finished or selected. Press Enter to return to menu..."
    done
}

main() {
    if [[ $# -eq 0 ]]; then
        ensure_root
        log_init_if_needed
        log "INFO" "No action specified, entering interactive menu."
        interactive_menu
    else
        local action_arg="$1"
        if [[ "$action_arg" != "install_all" && "$action_arg" != "uninstall_all" ]]; then
            if [[ -f "$R_ENV_STATE_FILE" ]]; then
                log "INFO" "Individual function call detected. Sourcing existing state file: ${R_ENV_STATE_FILE}"
                source "$R_ENV_STATE_FILE"
            else
                log "WARN" "Individual function call detected, but no state file (${R_ENV_STATE_FILE}) found. Variables might not be set."
            fi
        fi
        if [[ -n "${CUSTOM_R_PROFILE_SITE_PATH_ENV:-}" ]]; then
            log "INFO" "Rprofile.site path from env: ${CUSTOM_R_PROFILE_SITE_PATH_ENV}"
        fi
        get_r_profile_site_path
        shift
        local target_function_name=""
        case "$action_arg" in
            install_all|uninstall_all)
                target_function_name="$action_arg"
                ;;
            interactive)
                interactive_menu
                log "INFO" "Script finished after interactive session via direct call."
                exit 0
                ;;
            pre_flight_checks|setup_cran_repo|install_r|install_openblas_openmp|verify_openblas_openmp|setup_bspm|install_r_packages|install_rstudio_server|uninstall_r_packages|remove_bspm_config|uninstall_system_packages|remove_cran_repo|remove_leftover_files)
                target_function_name="$action_arg"
                log "INFO" "Directly invoking function: ${target_function_name}"
                ;;
            F|f|toggle_aggressive_cleanup)
                if [[ "$FORCE_USER_CLEANUP" == "yes" ]]; then
                    FORCE_USER_CLEANUP="no"
                    log "INFO" "Aggressive user data cleanup (FORCE_USER_CLEANUP) set to 'no'."
                else
                    FORCE_USER_CLEANUP="yes"
                    log "INFO" "Aggressive user data cleanup (FORCE_USER_CLEANUP) set to 'yes'."
                fi
                echo "FORCE_USER_CLEANUP is now: $FORCE_USER_CLEANUP"
                log "INFO" "Script finished after toggling FORCE_USER_CLEANUP."
                exit 0
                ;;
            *)
                log "ERROR" "Unknown direct action: '$action_arg'."
                log "ERROR" "Run without arguments for interactive menu, or use a valid action like 'install_all' or 'uninstall_all'."
                usage
                ;;
        esac
        if declare -f "$target_function_name" >/dev/null; then
            "$target_function_name" "$@"
        else
            log "ERROR" "Internal script error: Target function '${target_function_name}' for action '${action_arg}' is not defined or not callable."
            usage
        fi
    fi
    log "INFO" "Script execution finished."
}

main "$@"
