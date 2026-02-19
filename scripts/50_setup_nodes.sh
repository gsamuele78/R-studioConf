#!/usr/bin/env bash
# ==============================================================================
# 50_setup_nodes.sh — BIOME-CALC NODE SETUP
# ==============================================================================
# Deploys OpenBLAS CORETYPE auto-detection, Rprofile.site, Renviron.site,
# kernel tuning, R packages, Python geospatial venv, and optional Ollama AI.
#
# Part of: R-studioConf legacy deployment suite
# Requires: lib/common_utils.sh, config/setup_nodes.vars.conf
#           templates/Rprofile_site.R.template
#           templates/00_audit_v26.R.template
#
# Usage:
#   sudo ./50_setup_nodes.sh                 (interactive menu)
#   sudo ./50_setup_nodes.sh --skip-ollama   (skip Ollama AI)
#   sudo ./50_setup_nodes.sh --dry-run       (preview changes)
#   sudo ./50_setup_nodes.sh --uninstall     (remove deployed files)
#
# ==============================================================================

set -euo pipefail

# ── Resolve script location ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Load legacy common utilities ──
COMMON_UTILS="${WORKSPACE_ROOT}/lib/common_utils.sh"
if [[ ! -f "${COMMON_UTILS}" ]]; then
  echo "[ERROR] Missing: ${COMMON_UTILS}" >&2
  exit 1
fi
# shellcheck source=../lib/common_utils.sh
source "${COMMON_UTILS}"

# ── Load configuration ──
VARS_CONF="${WORKSPACE_ROOT}/config/setup_nodes.vars.conf"
if [[ ! -f "${VARS_CONF}" ]]; then
  log_error "Missing config: ${VARS_CONF}"
  exit 1
fi
# shellcheck source=../config/setup_nodes.vars.conf
source "${VARS_CONF}"

# ── Template paths ──
RPROFILE_TEMPLATE="${WORKSPACE_ROOT}/templates/Rprofile_site.R.template"
AUDIT_TEMPLATE="${WORKSPACE_ROOT}/templates/00_audit_v26.R.template"

# ── Args ──
SKIP_OLLAMA="${SKIP_OLLAMA:-false}"
DRY_RUN=false
DO_UNINSTALL=false

for arg in "$@"; do
  case "$arg" in
    --skip-ollama) SKIP_OLLAMA=true ;;
    --dry-run)     DRY_RUN=true ;;
    --uninstall)   DO_UNINSTALL=true ;;
    --help|-h)
      echo "Usage: sudo $0 [--skip-ollama] [--dry-run] [--uninstall]"
      exit 0
      ;;
  esac
done

# ── Root check ──
[[ "$(id -u)" -ne 0 ]] && { log_error "Must run as root"; exit 1; }

# ── Auto-detect host info if not set ──
[[ -z "${BIOME_HOST}" ]] && BIOME_HOST=$(hostname)
[[ -z "${BIOME_IP}" ]] && BIOME_IP=$(hostname -I | awk '{print $1}')

# ── Timestamp for backups ──
TS=$(date +%Y%m%d_%H%M%S)

# ── run_cmd wrapper: respects DRY_RUN ──
run_cmd() {
  if [[ "${DRY_RUN}" == true ]]; then
    log_info "[DRY-RUN] $*"
  else
    execute_command "$@"
  fi
}

# ==============================================================================
# UNINSTALL
# ==============================================================================
setup_nodes_uninstall() {
  log_step "Uninstalling BIOME-CALC node setup"
  
  local files_to_remove=(
    "/usr/local/bin/biome-detect-coretype.sh"
    "/etc/systemd/system/biome-detect-coretype.service"
    "/etc/systemd/system/ollama.service.d/biome-hardening.conf"
    "/usr/local/lib/pkgconfig/openmp.pc"
    "/etc/tmpfiles.d/thp-madvise.conf"
  )
  
  for f in "${files_to_remove[@]}"; do
    if [[ -f "$f" ]]; then
      run_cmd rm -f "$f"
      log_success "Removed: $f"
    fi
  done
  
  # Restore Rprofile/Renviron backups
  for f in /etc/R/Rprofile.site /etc/R/Renviron.site; do
    local newest_backup
    newest_backup=$(ls -t "${f}.bak."* 2>/dev/null | head -1 || true)
    if [[ -n "${newest_backup}" ]]; then
      run_cmd cp "${newest_backup}" "${f}"
      log_success "Restored: ${f} from ${newest_backup}"
    fi
  done
  
  # Disable and stop services
  run_cmd systemctl disable biome-detect-coretype.service 2>/dev/null || true
  run_cmd systemctl stop biome-detect-coretype.service 2>/dev/null || true
  run_cmd systemctl daemon-reload
  
  log_success "Uninstall complete"
}

# ==============================================================================
# STEP 0: PRE-FLIGHT
# ==============================================================================
setup_nodes_preflight() {
  log_step "Pre-flight checks"
  
  log_info "Host:    ${BIOME_HOST} (${BIOME_IP})"
  log_info "NFS:     ${NFS_HOME}"
  log_info "Config:  ${BIOME_CONF}"

  # Check templates
  if [[ ! -f "${RPROFILE_TEMPLATE}" ]]; then
    log_error "Missing: ${RPROFILE_TEMPLATE}"
    exit 1
  fi
  if [[ ! -f "${AUDIT_TEMPLATE}" ]]; then
    log_error "Missing: ${AUDIT_TEMPLATE}"
    exit 1
  fi
  
  log_success "All templates present"
}

# ==============================================================================
# STEP 1: SYSTEM DEPENDENCIES
# ==============================================================================
setup_nodes_dependencies() {
  log_step "Step 1: System Dependencies"

  # Remove snap curl if present (conflicts with package curl on some Ubuntu)
  if command -v snap &>/dev/null && snap list curl &>/dev/null 2>&1; then
    log_info "Removing snap curl"
    run_cmd snap remove curl 2>/dev/null || true
  fi

  run_cmd apt-get update -qq
  run_cmd apt-get install -y -qq \
    ca-certificates lsb-release wget apt-transport-https gnupg curl \
    libgdal-dev libgeos-dev libproj-dev \
    libpython3-dev python3-venv python3-pip \
    libudunits2-dev cmake build-essential \
    libopenblas-dev libomp-dev gfortran \
    libgoogle-perftools-dev
  log_success "Base dependencies installed"
}

# ==============================================================================
# STEP 2: APACHE ARROW
# ==============================================================================
setup_nodes_arrow() {
  log_step "Step 2: Apache Arrow"

  if ! dpkg -l 2>/dev/null | grep -q libarrow-dev; then
    local dc di deb
    dc=$(lsb_release --codename --short)
    di=$(lsb_release --id --short | tr 'A-Z' 'a-z')
    deb="apache-arrow-apt-source-latest-${dc}.deb"
    run_cmd wget -q "https://packages.apache.org/artifactory/arrow/${di}/${deb}" -O "/tmp/${deb}"
    run_cmd dpkg -i "/tmp/${deb}"
    rm -f "/tmp/${deb}"
    run_cmd apt-get update -qq
    run_cmd apt-get install -y -qq \
      libarrow-dev libparquet-dev libarrow-dataset-dev \
      libarrow-acero-dev libarrow-flight-dev libparquet-glib-dev
    log_success "Apache Arrow installed"
  else
    log_info "Apache Arrow already present"
  fi
}

# ==============================================================================
# STEP 3: GOOGLE CLOUD CLI
# ==============================================================================
setup_nodes_gcloud() {
  log_step "Step 3: Google Cloud CLI"

  if ! command -v gcloud &>/dev/null; then
    if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
      curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    fi
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list
    run_cmd apt-get update -qq
    run_cmd apt-get install -y -qq google-cloud-cli
    log_success "Google Cloud CLI installed"
  else
    log_info "gcloud already present"
  fi
}

# ==============================================================================
# STEP 4: OPENBLAS, CORETYPE DETECTION, KERNEL TUNING
# ==============================================================================
setup_nodes_blas() {
  log_step "Step 4: OpenBLAS, CORETYPE Auto-Detection & Kernel Tuning"

  # ── CPU detection for smart CORETYPE selection ──
  local cpu_model cpu_vendor cpu_flags
  cpu_model=$(lscpu | grep "Model name" | head -1 | sed 's/.*:\s*//')
  cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}' || echo "unknown")
  cpu_flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}' || echo "")
  log_info "CPU Model:  ${cpu_model}"
  log_info "CPU Vendor: ${cpu_vendor}"

  detect_coretype() {
    local vendor="$1" flags="$2" model="$3"
    if ! echo "$model" | grep -qi "QEMU\|Virtual"; then
      echo "$model" | grep -qiE "sapphire|emerald" && { echo "SAPPHIRERAPIDS"; return; }
      echo "$model" | grep -qiE "skylake|cascade"  && { echo "SKYLAKEX"; return; }
      echo "$model" | grep -qiE "haswell"           && { echo "HASWELL"; return; }
      echo "$model" | grep -qiE "zen4|zen ?4|7[789][0-9][0-9]|9[0-9][0-9][0-9]" && { echo "ZEN"; return; }
      echo "$model" | grep -qiE "zen|epyc|ryzen"   && { echo "ZEN"; return; }
    fi
    if echo "$vendor" | grep -qi "AMD"; then
      echo "$flags" | grep -q "avx2" && { echo "ZEN"; return; }
      echo "$flags" | grep -q "avx"  && { echo "BULLDOZER"; return; }
      echo "SANDYBRIDGE"; return
    elif echo "$vendor" | grep -qiE "Intel|Genuine"; then
      echo "$flags" | grep -q "avx512" && { echo "SKYLAKEX"; return; }
      echo "$flags" | grep -q "avx2"   && { echo "HASWELL"; return; }
      echo "$flags" | grep -q "avx"    && { echo "SANDYBRIDGE"; return; }
      echo "PRESCOTT"; return
    fi
    echo "SANDYBRIDGE"
  }

  local detected_ct
  detected_ct=$(detect_coretype "${cpu_vendor}" "${cpu_flags}" "${cpu_model}")
  log_info "Detected CORETYPE: ${detected_ct} (will be refreshed at every boot by systemd service)"

  # ── Remove stale static CORETYPE from /etc/environment ──
  if grep -q "^OPENBLAS_CORETYPE=" /etc/environment 2>/dev/null; then
    sed -i '/^OPENBLAS_CORETYPE=/d' /etc/environment
    log_info "Removed static OPENBLAS_CORETYPE from /etc/environment"
  fi
  for var in OPENBLAS_NUM_THREADS OMP_NUM_THREADS MKL_NUM_THREADS; do
    if grep -q "^${var}=" /etc/environment 2>/dev/null; then
      sed -i "/^${var}=/d" /etc/environment
      log_info "Removed static ${var} from /etc/environment"
    fi
  done

  # ── Deploy boot-time CORETYPE detection service ──
  cat > /usr/local/bin/biome-detect-coretype.sh <<'DETECTEOF'
#!/usr/bin/env bash
# BIOME-CALC: Detect CPU vendor and set OPENBLAS_CORETYPE at boot.
# Deployed by 50_setup_nodes.sh — runs as systemd oneshot on every boot.
# Rprofile.site also detects per-session (handles live migration).
VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}')
FLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}')
if echo "$VENDOR" | grep -qi "AMD"; then
  if echo "$FLAGS" | grep -q "avx2"; then CT="ZEN"
  elif echo "$FLAGS" | grep -q "avx";  then CT="BULLDOZER"
  else CT="SANDYBRIDGE"; fi
elif echo "$VENDOR" | grep -qiE "Intel|Genuine"; then
  if echo "$FLAGS" | grep -q "avx512"; then CT="SKYLAKEX"
  elif echo "$FLAGS" | grep -q "avx2";  then CT="HASWELL"
  elif echo "$FLAGS" | grep -q "avx";   then CT="SANDYBRIDGE"
  else CT="PRESCOTT"; fi
else
  CT="SANDYBRIDGE"
fi
if grep -q "^OPENBLAS_CORETYPE=" /etc/environment 2>/dev/null; then
  sed -i "s/^OPENBLAS_CORETYPE=.*/OPENBLAS_CORETYPE=${CT}/" /etc/environment
else
  echo "OPENBLAS_CORETYPE=${CT}" >> /etc/environment
fi
mkdir -p /etc/biome-calc
echo "$CT" > /etc/biome-calc/coretype
echo "VENDOR=$VENDOR" > /etc/biome-calc/cpu_vendor
logger -t biome-calc "CORETYPE=$CT (vendor=$VENDOR)"
DETECTEOF
  chmod 755 /usr/local/bin/biome-detect-coretype.sh

  cat > /etc/systemd/system/biome-detect-coretype.service <<'SVCEOF'
[Unit]
Description=BIOME-CALC: Detect CPU vendor and set OPENBLAS_CORETYPE
After=local-fs.target
Before=rstudio-server.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/biome-detect-coretype.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable biome-detect-coretype.service
  /usr/local/bin/biome-detect-coretype.sh
  local current_ct
  current_ct=$(cat "${BIOME_CONF}/coretype" 2>/dev/null || echo "unknown")
  log_success "Boot-time CORETYPE detection service installed (current: ${current_ct})"

  # ── BLAS/LAPACK alternatives: force OpenBLAS-pthread ──
  if [[ -f "${OPENBLAS_BLAS_PATH}" ]]; then
    run_cmd update-alternatives --set libblas.so.3-x86_64-linux-gnu "${OPENBLAS_BLAS_PATH}" 2>/dev/null || \
      log_warn "Could not set BLAS alternative (may need: update-alternatives --config libblas.so.3-x86_64-linux-gnu)"
    log_success "BLAS alternative: openblas-pthread"
  else
    log_warn "OpenBLAS pthread BLAS not found at: ${OPENBLAS_BLAS_PATH}"
  fi

  if [[ -f "${OPENBLAS_LAPACK_PATH}" ]]; then
    run_cmd update-alternatives --set liblapack.so.3-x86_64-linux-gnu "${OPENBLAS_LAPACK_PATH}" 2>/dev/null || \
      log_warn "Could not set LAPACK alternative"
    log_success "LAPACK alternative: openblas-pthread"
  else
    log_warn "OpenBLAS pthread LAPACK not found at: ${OPENBLAS_LAPACK_PATH}"
  fi

  # ── OpenMP pkg-config ──
  local openmp_pc="/usr/local/lib/pkgconfig/openmp.pc"
  if [[ ! -f "${openmp_pc}" ]]; then
    mkdir -p /usr/local/lib/pkgconfig
    cat > "${openmp_pc}" <<'OMPEOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: OpenMP
Description: OpenMP (Portable Shared Memory Parallel Programming)
Version: 4.5
Cflags: -fopenmp
Libs: -fopenmp
OMPEOF
    if ! echo "${PKG_CONFIG_PATH:-}" | grep -q "/usr/local/lib/pkgconfig"; then
      echo 'PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}"' >> /etc/environment
    fi
    log_success "OpenMP pkg-config installed (${openmp_pc})"
  else
    log_info "OpenMP pkg-config already present"
  fi

  # ── Transparent Hugepages: madvise ──
  local thp_path="/sys/kernel/mm/transparent_hugepage/enabled"
  if [[ -f "${thp_path}" ]]; then
    if ! grep -q '\[madvise\]' "${thp_path}"; then
      echo madvise > "${thp_path}" 2>/dev/null || true
    fi
    mkdir -p /etc/tmpfiles.d
    echo "w ${thp_path} - - - - madvise" > /etc/tmpfiles.d/thp-madvise.conf
    log_success "THP=madvise (persistent)"
  fi

  # ── I/O Scheduler: mq-deadline for virtualized disks ──
  for disk in /sys/block/sd* /sys/block/vd*; do
    [[ -d "$disk" ]] || continue
    local sched_file="${disk}/queue/scheduler"
    [[ -f "${sched_file}" ]] || continue
    local diskname current_sched
    diskname=$(basename "$disk")
    current_sched=$(cat "${sched_file}")
    if echo "${current_sched}" | grep -q 'mq-deadline'; then
      if ! echo "${current_sched}" | grep -q '\[mq-deadline\]'; then
        echo mq-deadline > "${sched_file}" 2>/dev/null || true
        log_info "Scheduler for ${diskname}: set to mq-deadline"
      fi
    fi
  done

  # ── NUMA Detection ──
  local numa_nodes
  numa_nodes=$(lscpu 2>/dev/null | grep "NUMA node(s)" | awk '{print $NF}')
  if [[ -n "${numa_nodes}" ]] && [[ "${numa_nodes}" -gt 1 ]]; then
    log_info "NUMA: ${numa_nodes} nodes detected"
    command -v numactl &>/dev/null || run_cmd apt-get install -y -qq numactl 2>/dev/null || true
    if ! grep -q "^GOMP_CPU_AFFINITY" /etc/environment 2>/dev/null; then
      echo "GOMP_CPU_AFFINITY=0-$(($(nproc)-1))" >> /etc/environment
    fi
    log_success "NUMA: ${numa_nodes} nodes configured"
  else
    log_info "NUMA: Single node — no cross-socket overhead"
  fi

  log_success "BLAS tuning complete (CORETYPE auto-detected at every boot + R session)"
}

# ==============================================================================
# STEP 5: RAMDISK
# ==============================================================================
setup_nodes_ramdisk() {
  log_step "Step 5: RAMDisk (${RAMDISK_SIZE} on /tmp)"

  local fstab_entry="tmpfs /tmp tmpfs rw,nosuid,nodev,size=${RAMDISK_SIZE},mode=1777 0 0"
  if ! grep -q "^tmpfs /tmp" /etc/fstab 2>/dev/null; then
    echo "${fstab_entry}" >> /etc/fstab
  fi
  run_cmd systemctl daemon-reload
  run_cmd mount -o "remount,size=${RAMDISK_SIZE}" /tmp 2>/dev/null || mount /tmp 2>/dev/null || true
  log_success "RAMDisk: $(df -h /tmp | tail -1 | awk '{print $2}')"
}

# ==============================================================================
# STEP 6: PYTHON GEOSPATIAL VENV
# ==============================================================================
setup_nodes_python() {
  log_step "Step 6: Python Geospatial Venv (${PYTHON_ENV})"

  if [[ ! -f "${PYTHON_ENV}/bin/python" ]]; then
    log_info "Creating venv: ${PYTHON_ENV}"
    rm -rf "${PYTHON_ENV}"
    run_cmd python3 -m venv "${PYTHON_ENV}"
  else
    log_info "Venv exists: ${PYTHON_ENV}"
  fi

  run_cmd "${PYTHON_ENV}/bin/pip" install --quiet --upgrade pip
  run_cmd "${PYTHON_ENV}/bin/pip" install --quiet "${PYTHON_PACKAGES[@]}"
  log_success "Python: $("${PYTHON_ENV}/bin/python" --version 2>&1)"
}

# ==============================================================================
# STEP 7: R PACKAGES
# ==============================================================================
setup_nodes_r_packages() {
  log_step "Step 7: bspm & R Packages"

  run_cmd Rscript --vanilla -e '
if (!requireNamespace("bspm",quietly=TRUE))
  install.packages("bspm",repos="https://cloud.r-project.org")
'

  # Build a safe R vector from the bash array
  local r_pkg_vector
  r_pkg_vector=$(printf '"%s",' "${R_PACKAGES[@]}" | sed 's/,$//')

  run_cmd Rscript --vanilla -e "
suppressMessages(bspm::enable())
pkgs <- c(${r_pkg_vector})
for (p in pkgs) {
  if (!requireNamespace(p,quietly=TRUE)) tryCatch({
    install.packages(p,repos='https://cloud.r-project.org',quiet=TRUE)
    cat(sprintf('  Installed: %s\n',p))
  }, error=function(e) cat(sprintf('  FAILED: %s (%s)\n',p,e\$message)))
}
"

  # Configure reticulate
  run_cmd Rscript --vanilla -e "
library(reticulate)
use_python('${PYTHON_ENV}/bin/python',required=TRUE)
tryCatch({tf<-reticulate::import('tensorflow')
  cat(sprintf('TensorFlow: %s\n',tf[['__version__']]))\n
}, error=function(e) cat('TF will init on first use.\n'))
"
  log_success "R packages configured"
}

# ==============================================================================
# STEP 8: DEPLOY SYSTEM CONFIGURATION FILES
# ==============================================================================
setup_nodes_config_files() {
  log_step "Step 8: Deploy System Configuration Files"

  local current_ct
  current_ct=$(cat "${BIOME_CONF}/coretype" 2>/dev/null || echo "auto")
  local cpu_vendor
  cpu_vendor=$(cat "${BIOME_CONF}/cpu_vendor" 2>/dev/null | grep VENDOR | cut -d= -f2 || echo "unknown")

  # ── Renviron.site ──
  local renviron="/etc/R/Renviron.site"
  [[ -f "${renviron}" ]] && run_cmd cp "${renviron}" "${renviron}.bak.${TS}"

  cat > "${renviron}" <<RENVEOF
# ${BIOME_HOST} Renviron.site — Generated: $(date -Iseconds)
# Deployed by 50_setup_nodes.sh

# R Library Paths
R_LIBS_SITE=/usr/local/lib/R/site-library/:\${R_LIBS_SITE}:/usr/lib/R/library

# OpenBLAS CORETYPE — NOT set here (migration-safe design).
# Detected dynamically by:
#   1. biome-detect-coretype.service (systemd oneshot, runs at boot)
#      -> writes to /etc/environment and ${BIOME_CONF}/coretype
#   2. Rprofile.site (per R session, reads /proc/cpuinfo vendor_id)
#      -> handles live migration without reboot
# Current boot-time detection: CORETYPE=${current_ct} (vendor=${cpu_vendor})

# Temp dirs (${RAMDISK_SIZE} RAMDisk)
TMPDIR=/tmp
TMP=/tmp
TEMP=/tmp
R_TEMPDIR=/tmp

# Python (system-wide venv)
RETICULATE_PYTHON=${PYTHON_ENV}/bin/python
EARTHENGINE_PYTHON=${PYTHON_ENV}/bin/python

# Compilation flags
_R_CHECK_COMPILATION_FLAGS_KNOWN_='-Wformat -Werror=format-security -Wdate-time'

# TensorFlow (CPU-only, no GPU)
TF_CPP_MIN_LOG_LEVEL=2
KERAS_HOME=/tmp/keras
CUDA_VISIBLE_DEVICES=-1

# RAMDisk size (read by Rprofile.site)
BIOME_RAMDISK_GB=${RAMDISK_GB}

# Threading: managed DYNAMICALLY by Rprofile.site. Do NOT set here.
RENVEOF
  chmod 644 "${renviron}"
  log_success "Renviron.site deployed (dynamic CORETYPE, no static thread vars)"

  # ── Rprofile.site (from template) ──
  local rprofile="/etc/R/Rprofile.site"
  [[ -f "${rprofile}" ]] && run_cmd cp "${rprofile}" "${rprofile}.bak.${TS}"
  rm -f /etc/R/Rprofile.site.bspm  # remove orphan bspm file from v6

  # Process the template using common_utils process_template
  # (substitutes all %%KEY%% placeholders from vars.conf)
  local tmp_profile="/tmp/Rprofile.site.deploy.${TS}"
  process_template "${RPROFILE_TEMPLATE}" "${tmp_profile}"
  run_cmd cp "${tmp_profile}" "${rprofile}"
  rm -f "${tmp_profile}"
  chmod 644 "${rprofile}"

  # Validate R syntax
  log_info "Validating Rprofile.site syntax..."
  local parse_result
  parse_result=$(Rscript --vanilla -e "
tryCatch({parse(file='${rprofile}');cat('PARSE_OK')},
  error=function(e) cat(sprintf('PARSE_FAIL: %s',e\$message)))" 2>&1)

  if echo "${parse_result}" | grep -q "PARSE_OK"; then
    log_success "Rprofile.site deployed and syntax validated"
  else
    log_error "Parse error: ${parse_result}"
    log_warn "Restoring backup..."
    cp "${rprofile}.bak.${TS}" "${rprofile}"
    exit 1
  fi
}

# ==============================================================================
# STEP 9: USER HOME MIGRATION
# ==============================================================================
setup_nodes_migrate_users() {
  log_step "Step 9: Migrate User Configurations"

  local user_home username
  for user_home in "${NFS_HOME}"/*/; do
    [[ -d "${user_home}" ]] || continue
    username=$(basename "${user_home}")
    log_info "Processing: ${username}"

    # ── Fix .Renviron ──
    local re_file="${user_home}/.Renviron"
    if [[ -f "${re_file}" ]]; then
      cp "${re_file}" "${re_file}.bak.$(date +%Y%m%d)" 2>/dev/null || true
      # Fix legacy Python paths
      sed -i 's|^EARTHENGINE_PYTHON=.*|EARTHENGINE_PYTHON="'"${PYTHON_ENV}"'/bin/python"|' "${re_file}"
      sed -i 's|^RETICULATE_PYTHON=.*|RETICULATE_PYTHON="'"${PYTHON_ENV}"'/bin/python"|' "${re_file}"
      # Remove legacy env vars
      sed -i '/^EARTHENGINE_ENV=/d' "${re_file}"
      sed -i '/^TMP=/d; /^TEMP=/d; /^TMPDIR=/d' "${re_file}"
      # Remove static threading (conflicts with dynamic Rprofile)
      sed -i '/^OMP_NUM_THREADS=/d' "${re_file}"
      sed -i '/^OPENBLAS_NUM_THREADS=/d' "${re_file}"
      sed -i '/^MKL_NUM_THREADS=/d' "${re_file}"
      sed -i '/^MC_CORES=/d' "${re_file}"
      sed -i '/^OPENBLAS_CORETYPE=/d' "${re_file}"
      # Add warning block if missing
      if ! grep -q "Threading Configuration" "${re_file}"; then
        cat >> "${re_file}" <<'WEOF'

# =============================================================
# IMPORTANT: Threading Configuration
# =============================================================
# Thread settings (OMP, BLAS, MC_CORES) are now managed
# dynamically by the system Rprofile.site. Do NOT set them here.
# =============================================================
WEOF
      fi
      log_success "  .Renviron migrated for ${username}"
    fi

    # ── Fix .Rprofile ──
    local rp_file="${user_home}/.Rprofile"
    if [[ -f "${rp_file}" ]]; then
      sed -i 's|^source("/usr/local/custom/rstudio/show_quota.R")|#source("/usr/local/custom/rstudio/show_quota.R") # Deprecated|' "${rp_file}"
      sed -i 's|^source(".*parallelize.R")|#source("parallelize.R") # Managed by system|' "${rp_file}"
      log_success "  .Rprofile migrated for ${username}"
    fi

    # ── Fix rstudio-prefs.json ──
    local prefs="${user_home}/.config/rstudio/rstudio-prefs.json"
    if [[ -f "${prefs}" ]]; then
      sed -i 's|//opt/r-geospatial|/opt/r-geospatial|g' "${prefs}"
      sed -i 's|"/usr/bin/python3"|"'"${PYTHON_ENV}"'/bin/python"|g' "${prefs}"
      log_success "  rstudio-prefs.json migrated for ${username}"
    fi
  done

  # ── User /etc/skel template for new users ──
  mkdir -p /etc/skel
  cat > /etc/skel/.Renviron <<SKELEOF
# ${BIOME_HOST} User .Renviron — Loaded AFTER /etc/R/Renviron.site
#
# Python (defaults to system venv, uncomment to override):
#RETICULATE_PYTHON="${PYTHON_ENV}/bin/python"
#EARTHENGINE_PYTHON="${PYTHON_ENV}/bin/python"
#
# XDG dirs
XDG_DATA_HOME=\${HOME}/.local/share
XDG_CONFIG_HOME=\${HOME}/.config
#
# Threading: managed by system Rprofile.site. Do NOT set manually.
SKELEOF
  chmod 644 /etc/skel/.Renviron
  log_success "New-user /etc/skel/.Renviron template created"
}

# ==============================================================================
# STEP 10: LOGGING & AUDIT INFRASTRUCTURE
# ==============================================================================
setup_nodes_logging() {
  log_step "Step 10: Logging & Audit Infrastructure"

  mkdir -p "${BIOME_CONF}"
  chmod 755 "${BIOME_CONF}"

  # Deploy audit script from template
  local tmp_audit="/tmp/00_audit_v26.R.deploy.${TS}"
  process_template "${AUDIT_TEMPLATE}" "${tmp_audit}"
  run_cmd cp "${tmp_audit}" "${BIOME_CONF}/00_audit_v26.R"
  rm -f "${tmp_audit}"
  chmod 644 "${BIOME_CONF}/00_audit_v26.R"
  log_success "Audit: ${BIOME_CONF}/00_audit_v26.R"

  # System log
  touch "${LOG_FILE}"
  chmod 666 "${LOG_FILE}"
  log_success "System log: ${LOG_FILE} (world-writable for AD users)"

  # RStudio converter log dir
  mkdir -p /var/log/biome_converter
  if getent group rstudio-server &>/dev/null; then
    chown root:rstudio-server /var/log/biome_converter
    chmod 775 /var/log/biome_converter
  fi

  # Audit config (read by 00_audit_v26.R and 99_audit_r_environment.sh)
  cat > "${BIOME_CONF}/audit.conf" <<ACONF
# BIOME-CALC Audit Config — Generated: $(date -Iseconds)
nfs_home       <- "${NFS_HOME}"
cifs_archive   <- "${CIFS_ARCHIVE}"
python_env     <- "${PYTHON_ENV}/bin/python"
log_file       <- "${LOG_FILE}"
test_ollama    <- $([ "${SKIP_OLLAMA}" = true ] && echo "FALSE" || echo "TRUE")
ACONF
  chmod 644 "${BIOME_CONF}/audit.conf"
  log_success "Logging infrastructure ready"
}

# ==============================================================================
# STEP 11: OLLAMA AI SERVICE
# ==============================================================================
setup_nodes_ollama() {
  if [[ "${SKIP_OLLAMA}" == true ]]; then
    log_step "Step 11: Ollama (SKIPPED)"
    return 0
  fi
  log_step "Step 11: Ollama AI Service (Hardened)"

  ulimit -n 65535 2>/dev/null || true

  # ── Install Ollama ──
  if ! command -v ollama &>/dev/null; then
    log_info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
  else
    log_info "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown')"
  fi

  # ── Systemd hardening override ──
  mkdir -p /etc/systemd/system/ollama.service.d
  cat > /etc/systemd/system/ollama.service.d/biome-hardening.conf <<OLLEOF
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
MemoryMax=${OLLAMA_RAM_LIMIT}
MemorySwapMax=0
Environment="OLLAMA_NUM_PARALLEL=2"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
LimitNOFILE=65535
Restart=on-failure
RestartSec=10
OLLEOF
  log_success "Ollama hardening: localhost-only, MemoryMax=${OLLAMA_RAM_LIMIT}"

  run_cmd systemctl daemon-reload
  run_cmd systemctl enable ollama
  if systemctl is-active --quiet ollama; then
    run_cmd systemctl restart ollama
  else
    run_cmd systemctl start ollama
  fi
  sleep 3

  # Wait for readiness
  local i
  for i in $(seq 1 15); do
    curl -sf http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
    sleep 1
  done

  if ! curl -sf http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    log_error "Ollama failed to start — check: journalctl -u ollama -n 50"
  else
    log_success "Ollama running on 127.0.0.1:11434"
  fi

  # ── Pull models ──
  if ! ollama list 2>/dev/null | grep -q "qwen2.5-coder.*14b"; then
    log_info "Pulling ${OLLAMA_BASE_MODEL} (~9GB download, ~16GB RAM when loaded)..."
    run_cmd ollama pull "${OLLAMA_BASE_MODEL}" || log_warn "Failed to pull base model"
  else
    log_info "Base model already present"
  fi

  if ! ollama list 2>/dev/null | grep -q "codellama"; then
    run_cmd ollama pull "${OLLAMA_FALLBACK_MODEL}" || log_warn "Could not pull fallback model"
  fi

  # ── Create R-Optimized Custom Model ──
  local modelfile_path="${BIOME_CONF}/r-coder.modelfile"
  cat > "${modelfile_path}" <<'MFEOF'
# BIOME-CALC R-Coder — CPU-Optimized Modelfile
FROM qwen2.5-coder:14b-instruct-q4_K_M

PARAMETER num_thread 24
PARAMETER num_ctx 4096
PARAMETER temperature 0.3
PARAMETER top_p 0.9

SYSTEM """You are an expert R programming assistant for ecological and biodiversity research.

Core competencies:
- R programming: tidyverse, data.table, base R
- Statistics: GLMs, GAMs, mixed models (lme4, nlme), multivariate (vegan, ade4)
- Ecology packages: vegan, betapart, mobr, iNEXT
- Geospatial: terra, sf, stars, rgee (Google Earth Engine)
- Biodiversity: species distribution models (biomod2, ENMeval)
- Parallel computing: future, future.apply, parallel::mclapply

Rules:
- Write clean, commented R code ready for RStudio.
- For large datasets, suggest arrow::read_parquet() over read.csv().
- For geospatial, prefer terra over raster (deprecated).
- Be concise: CPU inference is slow, minimize output.
"""
MFEOF
  chmod 644 "${modelfile_path}"

  if ollama list 2>/dev/null | grep -q "qwen2.5-coder.*14b"; then
    log_info "Creating custom model: ${OLLAMA_CUSTOM_MODEL}..."
    if ollama create "${OLLAMA_CUSTOM_MODEL}" -f "${modelfile_path}" 2>/dev/null; then
      log_success "Custom model created: ${OLLAMA_CUSTOM_MODEL}"
    else
      log_warn "Could not create custom model — users will use base model"
      OLLAMA_CUSTOM_MODEL="${OLLAMA_BASE_MODEL}"
    fi
  else
    log_warn "Base model not available — using fallback: ${OLLAMA_FALLBACK_MODEL}"
    OLLAMA_CUSTOM_MODEL="${OLLAMA_FALLBACK_MODEL}"
  fi

  echo "${OLLAMA_CUSTOM_MODEL}" > "${BIOME_CONF}/ai_model"
  chmod 644 "${BIOME_CONF}/ai_model"

  # Security check
  if ss -tlnp 2>/dev/null | grep ":11434" | grep -q "0.0.0.0"; then
    log_error "SECURITY: Ollama listening on 0.0.0.0! Should be 127.0.0.1 only."
  else
    log_success "Ollama security: 127.0.0.1 only"
  fi
}

# ==============================================================================
# STEP 12: BLAS SMOKE TEST
# ==============================================================================
setup_nodes_blas_test() {
  log_step "Step 12: BLAS Smoke Test"

  local smoke_ct
  smoke_ct=$(cat "${BIOME_CONF}/coretype" 2>/dev/null || echo "SANDYBRIDGE")
  log_info "BLAS smoke test with CORETYPE=${smoke_ct} (10s timeout)..."

  local blas_test
  blas_test=$(timeout 10 Rscript --vanilla -e "
  Sys.setenv(OPENBLAS_CORETYPE='${smoke_ct}')
  A <- matrix(runif(500*500), 500, 500)
  t0 <- Sys.time()
  B <- A %*% A
  dt <- round(as.numeric(difftime(Sys.time(), t0, units='secs')), 2)
  cat(sprintf('BLAS_OK in %ss', dt))
" 2>&1) || blas_test="BLAS_TIMEOUT"

  if echo "${blas_test}" | grep -q "BLAS_OK"; then
    log_success "BLAS smoke test: ${blas_test}"
  else
    log_error "BLAS smoke test FAILED: ${blas_test}"
    log_warn "CORETYPE=${smoke_ct} may be wrong — try: OPENBLAS_CORETYPE=SANDYBRIDGE as fallback"
  fi
}

# ==============================================================================
# FINAL SUMMARY
# ==============================================================================
setup_nodes_summary() {
  local current_ct
  current_ct=$(cat "${BIOME_CONF}/coretype" 2>/dev/null || echo "unknown")
  local cpu_vendor
  cpu_vendor=$(grep '^VENDOR' "${BIOME_CONF}/cpu_vendor" 2>/dev/null | cut -d= -f2 || echo "unknown")

  log_success "================================================="
  log_success "BIOME-CALC NODE SETUP COMPLETE — ${BIOME_HOST}"
  log_success "================================================="
  echo ""
  echo "  CORETYPE Detection (Migration-Safe):"
  echo "    - Boot-time:    biome-detect-coretype.service (systemd)"
  echo "    - Per-session:  Rprofile.site (reads /proc/cpuinfo)"
  echo "    - Current:      ${current_ct} (vendor=${cpu_vendor})"
  echo ""
  echo "  Next steps:"
  echo "    1. sudo systemctl restart rstudio-server"
  echo "    2. In R: source('${BIOME_CONF}/00_audit_v26.R')"
  echo "    3. In R: status()"
  echo ""
  echo "  Key files deployed:"
  echo "    /etc/R/Rprofile.site"
  echo "    /etc/R/Renviron.site"
  echo "    /usr/local/bin/biome-detect-coretype.sh"
  echo "    ${BIOME_CONF}/00_audit_v26.R"
  echo "    ${BIOME_CONF}/audit.conf"
  echo "    ${LOG_FILE}"
  if [[ "${SKIP_OLLAMA}" != true ]]; then
    echo "    ${BIOME_CONF}/ai_model"
    echo "    ${BIOME_CONF}/r-coder.modelfile"
  fi
}

# ==============================================================================
# MAIN — INTERACTIVE MENU (legacy pattern)
# ==============================================================================

if [[ "${DO_UNINSTALL}" == true ]]; then
  setup_nodes_uninstall
  exit 0
fi

echo ""
echo "============================================================"
echo "  BIOME-CALC NODE SETUP"
echo "  Host: ${BIOME_HOST} | NFS: ${NFS_HOME}"
echo "  Ollama: $([ "${SKIP_OLLAMA}" = true ] && echo "SKIP" || echo "ENABLED")"
echo "  Dry-run: $([ "${DRY_RUN}" = true ] && echo "YES" || echo "NO")"
echo "============================================================"
echo ""
echo "  1) Full deployment (all steps)"
echo "  2) BLAS/CORETYPE detection only (Step 4)"
echo "  3) Config files only (Rprofile + Renviron, Step 8)"
echo "  4) Migrate user configs only (Step 9)"
echo "  5) Ollama AI service only (Step 11)"
echo "  6) Run BLAS smoke test only (Step 12)"
echo "  U) Uninstall (remove deployed files)"
echo "  Q) Quit"
echo ""

read -r -p "  Selection [1]: " choice
choice="${choice:-1}"
choice="${choice^^}"  # uppercase

case "${choice}" in
  1)
    setup_nodes_preflight
    setup_nodes_dependencies
    setup_nodes_arrow
    setup_nodes_gcloud
    setup_nodes_blas
    setup_nodes_ramdisk
    setup_nodes_python
    setup_nodes_r_packages
    setup_nodes_config_files
    setup_nodes_migrate_users
    setup_nodes_logging
    setup_nodes_ollama
    setup_nodes_blas_test
    setup_nodes_summary
    ;;
  2)
    setup_nodes_preflight
    setup_nodes_blas
    setup_nodes_blas_test
    ;;
  3)
    setup_nodes_preflight
    setup_nodes_config_files
    ;;
  4)
    setup_nodes_migrate_users
    ;;
  5)
    setup_nodes_preflight
    setup_nodes_ollama
    ;;
  6)
    setup_nodes_blas_test
    ;;
  U)
    setup_nodes_uninstall
    ;;
  Q)
    log_info "Aborted."
    exit 0
    ;;
  *)
    log_error "Invalid selection: ${choice}"
    exit 1
    ;;
esac
