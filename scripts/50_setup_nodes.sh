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
#           templates/00_audit_v27.R.template
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
# shellcheck source=../lib/common_utils.sh disable=SC1091
source "${COMMON_UTILS}"

# ── Load configuration ──
VARS_CONF="${WORKSPACE_ROOT}/config/setup_nodes.vars.conf"
if [[ ! -f "${VARS_CONF}" ]]; then
  # NOTE: log_error wrapper is defined later in this file; use the
  # base log() function from common_utils.sh (already sourced above)
  # so this pre-flight error path doesn't depend on forward refs.
  log "ERROR" "Missing config: ${VARS_CONF}"
  exit 1
fi
# shellcheck source=../config/setup_nodes.vars.conf disable=SC1091
source "${VARS_CONF}"

# ── Template paths ──
RPROFILE_TEMPLATE="${WORKSPACE_ROOT}/templates/Rprofile_site.R.template"
AUDIT_TEMPLATE="${WORKSPACE_ROOT}/templates/00_audit_v28.R.template"
RPROFILE_MIN_TEMPLATE="${WORKSPACE_ROOT}/templates/Rprofile_site.minimal.R.template"

# ── Args ──
SKIP_OLLAMA="${SKIP_OLLAMA:-false}"
DRY_RUN=false
DO_UNINSTALL=false
DO_VERIFY=false

for arg in "$@"; do
  case "$arg" in
    --skip-ollama) SKIP_OLLAMA=true ;;
    --dry-run)     DRY_RUN=true ;;
    --uninstall)   DO_UNINSTALL=true ;;
    --verify)      DO_VERIFY=true ;;
    --help|-h)
      echo "Usage: sudo $0 [--skip-ollama] [--dry-run] [--uninstall] [--verify]"
      echo "  --verify    Run 3-layer cgroup + Rprofile version check without deploying"
      exit 0
      ;;
  esac
done

# ── Root check ──
# log_error wrapper isn't defined until line ~95; use base log() here.
[[ "$(id -u)" -ne 0 ]] && { log "ERROR" "Must run as root"; exit 1; }

# ── Auto-detect host info if not set ──
[[ -z "${BIOME_HOST}" ]] && BIOME_HOST=$(hostname)
[[ -z "${BIOME_IP}" ]] && BIOME_IP=$(hostname -I | awk '{print $1}')

# ── run_cmd wrapper: respects DRY_RUN ──
run_cmd() {
  if [[ "${DRY_RUN}" == true ]]; then
    log "INFO" "[DRY-RUN] $*"
  else
    run_command "Execute" "$*"
  fi
}

# ── Logging wrappers ──
log_step() {
  echo ""
  log "INFO" "============================================================"
  log "INFO" "$1"
  log "INFO" "============================================================"
}
log_info() { log "INFO" "$1"; }
log_success() { log "INFO" "[SUCCESS] $1"; }
log_error() { log "ERROR" "$1"; }
log_warn() { log "WARN" "$1"; }

# ── Check if command exists ──
command_exists() {
    command -v "$1" &>/dev/null
}

# ==============================================================================
# UNINSTALL
# ==============================================================================
setup_nodes_uninstall() {
  log_step "Uninstalling BIOME-CALC node setup"
  
  local files_to_remove=(
    "/etc/profile.d/biome-coretype.sh"
    "/etc/rstudio/rsession-profile"
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
  
  # Restore Rprofile/Renviron backups (fixed .bak suffix)
  for f in /etc/R/Rprofile.site /etc/R/Renviron.site; do
    if [[ -f "${f}.bak" ]]; then
      run_cmd cp "${f}.bak" "${f}"
      log_success "Restored: ${f} from ${f}.bak"
    fi
  done
  
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

  # ── Kernel/fragment contract check ──
  # If the Rprofile kernel template references Rprofile_site.d/, the
  # companion templates directory MUST exist AND contain fragments.
  # Otherwise deploy would ship a broken RStudio (v12.2 kernel expects fragments).
  if grep -q 'Rprofile_site\.d' "${RPROFILE_TEMPLATE}" 2>/dev/null; then
    local frag_src_dir="$(dirname "${RPROFILE_TEMPLATE}")/Rprofile_site.d"
    if [[ ! -d "${frag_src_dir}" ]]; then
      log_error "Kernel template references Rprofile_site.d/ but source dir missing: ${frag_src_dir}"
      exit 1
    fi
    local src_count
    src_count=$(find "${frag_src_dir}" -maxdepth 1 -type f -name '[0-9][0-9]_*.R.template' 2>/dev/null | wc -l)
    if (( src_count == 0 )); then
      log_error "Kernel template references Rprofile_site.d/ but 0 fragments in ${frag_src_dir}"
      log_error "  Expected files matching: [0-9][0-9]_*.R.template"
      exit 1
    fi
    log_info "Fragment contract: ${src_count} fragment template(s) present in ${frag_src_dir}"
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
    libopenblas-serial-dev libomp-dev gfortran \
    libfreetype-dev libharfbuzz-dev libfribidi-dev libtiff-dev libpng-dev \
    libnetcdf-dev libhdf5-dev libeigen3-dev \
    default-jdk \
    libnlopt-dev \
    libgoogle-perftools-dev sendemail dnsutils \
    samba-common-bin winbind rsync tree
  log_success "Base dependencies installed"
  # NOTE: R CMD javareconf + rJava source install handled by r_env_manager.sh configure_java_for_r()
}

# ==============================================================================
# STEP 2: APACHE ARROW
# ==============================================================================
setup_nodes_arrow() {
  log_step "Step 2: Apache Arrow"

  if ! dpkg -l 2>/dev/null | grep -q libarrow-dev; then
    local dc di deb
    dc=$(lsb_release --codename --short)
    di=$(lsb_release --id --short | tr '[:upper:]' '[:lower:]')
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
      if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg"
      else
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
          | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
      fi
    fi
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "[DRY-RUN] echo \"deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main\" > /etc/apt/sources.list.d/google-cloud-sdk.list"
    else
      echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list
    fi
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

  # ── Deploy boot/session-time CORETYPE detection wrappers ──
  cat > /etc/profile.d/biome-coretype.sh <<'DETECTEOF'
# BIOME-CALC: Detect CPU vendor and set OPENBLAS_CORETYPE.
# Profile.d script for terminal R usage (Rscript/R batch).
VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | tr -d ' ')
FLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2)
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
export OPENBLAS_CORETYPE="${CT}"
DETECTEOF
  chmod 755 /etc/profile.d/biome-coretype.sh

  mkdir -p /etc/rstudio
  cat > /etc/rstudio/rsession-profile <<'RSTEOF'
#!/bin/sh
# BIOME-CALC: Evaluate CPU capabilities before spawning rsession.
if [ -f /etc/profile.d/biome-coretype.sh ]; then
  . /etc/profile.d/biome-coretype.sh
fi
RSTEOF
  chmod 755 /etc/rstudio/rsession-profile

  log_success "OS-level OPENBLAS_CORETYPE wrappers installed (/etc/profile.d & rsession-profile)"

  # ── BLAS/LAPACK alternatives: force OpenBLAS-serial ──
  # OpenBLAS-pthread's internal thread pool conflicts with RStudio rsession's
  # own pthreads (event loop, HTTP, watchdog), causing SIGSEGV in
  # blas_thread_server during solve()/crossprod(). See: rstudio/rstudio#7031
  # Fix: use openblas-serial (no internal thread pool, no collision).

  # Ensure serial variant is installed
  if ! dpkg -l libopenblas0-serial 2>/dev/null | grep -q '^ii'; then
    log_info "Installing libopenblas0-serial..."
    run_cmd apt-get install -y -qq libopenblas0-serial
  fi

  # Remove pthread variant to prevent alternatives from reverting
  if dpkg -l libopenblas0-pthread 2>/dev/null | grep -q '^ii'; then
    log_info "Removing libopenblas0-pthread (conflicts with RStudio rsession pthreads)"
    run_cmd apt-get remove -y libopenblas0-pthread 2>/dev/null || true
  fi

  # Set BLAS alternative → serial
  if [[ -f "${OPENBLAS_BLAS_PATH}" ]]; then
    run_cmd update-alternatives --set libblas.so.3-x86_64-linux-gnu "${OPENBLAS_BLAS_PATH}" 2>/dev/null || \
      log_warn "Could not set BLAS alternative (may need: update-alternatives --config libblas.so.3-x86_64-linux-gnu)"
    log_success "BLAS alternative: openblas-serial"
  else
    log_warn "OpenBLAS serial BLAS not found at: ${OPENBLAS_BLAS_PATH}"
  fi

  # Set LAPACK alternative → serial
  if [[ -f "${OPENBLAS_LAPACK_PATH}" ]]; then
    run_cmd update-alternatives --set liblapack.so.3-x86_64-linux-gnu "${OPENBLAS_LAPACK_PATH}" 2>/dev/null || \
      log_warn "Could not set LAPACK alternative"
    log_success "LAPACK alternative: openblas-serial"
  else
    log_warn "OpenBLAS serial LAPACK not found at: ${OPENBLAS_LAPACK_PATH}"
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
      echo "PKG_CONFIG_PATH=\"/usr/local/lib/pkgconfig:\${PKG_CONFIG_PATH}\"" >> /etc/environment
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
# STEP 5: LOCAL /Rtmp DISK VALIDATION (v10.0)
# ==============================================================================
setup_nodes_tmp_disk() {
  log_step "Step 5: Local /Rtmp Disk Validation (${TMP_DISK_GB:-400}GB)"

  local RTMP_MOUNT="/Rtmp"

  # ── Create mount point if needed ──
  if [[ ! -d "${RTMP_MOUNT}" ]]; then
    mkdir -p "${RTMP_MOUNT}"
    chmod 1777 "${RTMP_MOUNT}"
    log_info "Created ${RTMP_MOUNT} mount point"
  fi

  # ── Remove legacy tmpfs /tmp entry if present ──
  if grep -q "^tmpfs /tmp" /etc/fstab 2>/dev/null; then
    log_warn "Removing legacy tmpfs /tmp entry from /etc/fstab"
    sed -i '/^tmpfs \/tmp/d' /etc/fstab
    run_cmd systemctl daemon-reload
    run_cmd umount /tmp 2>/dev/null || true
  fi

  # ── Validate /Rtmp is on a real disk (not tmpfs) ──
  local tmp_fstype
  tmp_fstype=$(df -T "${RTMP_MOUNT}" 2>/dev/null | awk 'NR==2 {print $2}')
  if [[ "${tmp_fstype}" == "tmpfs" || "${tmp_fstype}" == "rootfs" ]]; then
    log_error "${RTMP_MOUNT} is NOT on a dedicated disk (got: ${tmp_fstype})."
    log_error "Expected: ext4/xfs on a dedicated disk mounted at ${RTMP_MOUNT}."
    log_error "Attach a dedicated disk, format as ext4, add to /etc/fstab, and mount at ${RTMP_MOUNT}."
    exit 1
  fi

  # ── Validate sufficient space ──
  local tmp_size_gb
  tmp_size_gb=$(df -BG "${RTMP_MOUNT}" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$2); print $2}')
  if [[ "${tmp_size_gb}" -lt 100 ]]; then
    log_warn "${RTMP_MOUNT} disk is only ${tmp_size_gb}GB. Recommended: ${TMP_DISK_GB:-400}GB dedicated disk."
  fi

  # ── Ensure correct permissions ──
  chmod 1777 "${RTMP_MOUNT}"

  # ── Deploy systemd-tmpfiles cleanup rule ──
  # Clean files >7 days old on boot and via systemd-tmpfiles-clean.timer (daily)
  mkdir -p /etc/tmpfiles.d
  cat > /etc/tmpfiles.d/biome-rtmp-cleanup.conf <<TMPEOF
# BIOME-CALC: Clean /Rtmp files older than 7 days
# Runs on boot via systemd-tmpfiles-clean.timer
q ${RTMP_MOUNT} 1777 root root 7d
TMPEOF

  log_success "/Rtmp disk: ${tmp_fstype} filesystem, ${tmp_size_gb}GB ($(df -h "${RTMP_MOUNT}" | tail -1 | awk '{print $4}') free)"
}

# ==============================================================================
# STEP 5b: SWAP FILE
# ==============================================================================
setup_nodes_swap() {
  log_step "Step 5b: Swap File (${SWAP_SIZE_GB}GB at ${SWAP_FILE})"

  local swap_size_mb=$(( SWAP_SIZE_GB * 1024 ))
  local expected_bytes=$(( swap_size_mb * 1024 * 1024 ))
  local actual_bytes=0

  # Check if swap file exists and get its size
  if [[ -f "${SWAP_FILE}" ]]; then
    actual_bytes=$(stat -c%s "${SWAP_FILE}" 2>/dev/null || echo 0)
  fi

  # ── Step 1: Determine if we need to (re)create the swap file ──
  local needs_mkswap=false

  if [[ "${actual_bytes}" -eq "${expected_bytes}" ]]; then
    log_info "Swap file exists and is the exact configured size (${SWAP_SIZE_GB}GB / ${expected_bytes} bytes)."
  else
    if [[ "${actual_bytes}" -gt 0 ]]; then
      log_info "Swap file size mismatch! Configured: ${expected_bytes}B (${SWAP_SIZE_GB}GB), Current: ${actual_bytes}B."
      log_info "Resizing swap file..."
    else
      log_info "Swap file not found. Creating new ${SWAP_SIZE_GB}GB swap at ${SWAP_FILE}..."
    fi
    needs_mkswap=true
  fi

  # Check active swap size if it's currently on
  local active_size_bytes=0
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qF "${SWAP_FILE}"; then
     active_size_bytes=$(swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null | awk -v f="${SWAP_FILE}" '$1==f {print $2}')
     if [[ "${needs_mkswap}" == false && -n "${active_size_bytes}" && "${active_size_bytes}" -ne "${expected_bytes}" ]]; then
         log_info "Swap is active but reports incorrect runtime size (${active_size_bytes}B instead of ${expected_bytes}B). Recreating..."
         needs_mkswap=true
     fi
  fi

  # ── Step 2: Create/Resize the swap file if necessary ──
  if [[ "${needs_mkswap}" == true ]]; then
    # Deactivate if active before removing or recreating
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qF "${SWAP_FILE}"; then
      log_info "Deactivating active swap: ${SWAP_FILE}"
      run_cmd swapoff "${SWAP_FILE}" || true
    fi

    if [[ -f "${SWAP_FILE}" ]]; then
      run_cmd rm -f "${SWAP_FILE}"
    fi

    # Create new swap file
    log_info "Allocating swap space..."
    if ! run_cmd fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}"; then
      log_warn "fallocate failed, falling back to dd (this may take a while)..."
      run_cmd dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${swap_size_mb}" status=progress
    fi
    run_cmd chmod 600 "${SWAP_FILE}"
    run_cmd mkswap "${SWAP_FILE}"
    
    log_info "Activating new swap: ${SWAP_FILE}"
    run_cmd swapon "${SWAP_FILE}"
  else
    # It exists and is the correct size, just ensure it's on
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qF "${SWAP_FILE}"; then
      log_info "Activating existing swap: ${SWAP_FILE}"
      run_cmd swapon "${SWAP_FILE}"
    else
      log_info "Swap is already active and properly sized."
    fi
  fi

  # ── Persist in /etc/fstab (idempotent) ──
  local fstab_marker="# managed-by: 50_setup_nodes.sh swap"
  local fstab_entry="${SWAP_FILE} none swap sw 0 0  ${fstab_marker}"
  if grep -qF "${SWAP_FILE}" /etc/fstab 2>/dev/null; then
    log_info "Swap entry already present in /etc/fstab. Skipping."
  else
    log_info "Adding swap entry to /etc/fstab..."
    echo "${fstab_entry}" >> /etc/fstab
    log_success "fstab updated: ${fstab_entry}"
  fi

  # ── Tune swappiness — prefer RAM but tolerate compiler spikes ──
  # v9.9: Raised 10→30. cc1plus (NIMBLE CppAD) spikes 8-15GB transiently.
  # At 10, OOM killer fires before 32GB swap is utilized.
  local swappiness_target=30
  if ! grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
    echo "vm.swappiness=${swappiness_target}" >> /etc/sysctl.conf
    log_info "vm.swappiness=${swappiness_target} written to /etc/sysctl.conf"
  else
    log_info "vm.swappiness already configured in /etc/sysctl.conf"
  fi
  sysctl -q vm.swappiness="${swappiness_target}" 2>/dev/null || true

  # Show actual summary
  local final_swap_summary
  final_swap_summary=$(free -h | awk '/^Swap:/ {print $2}')
  if [[ "${DRY_RUN}" == true ]]; then
      log_success "Swap: (Dry-Run active, assuming ${SWAP_SIZE_GB}G) (vm.swappiness=${swappiness_target})"
  else
      log_success "Swap: ${final_swap_summary} active (vm.swappiness=${swappiness_target})"
  fi
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
  # Install Python packages individually to handle version constraints properly
  for py_pkg in "${PYTHON_PACKAGES[@]}"; do
    log_info "  pip install: ${py_pkg}"
    "${PYTHON_ENV}/bin/pip" install --quiet "${py_pkg}" || {
      log_warn "  pip install failed: ${py_pkg} — continuing"
    }
  done
  log_success "Python: $("${PYTHON_ENV}/bin/python" --version 2>&1)"
}

# ==============================================================================
# STEP 7: R PACKAGES & BSPM AUTHENTICATION
# ==============================================================================
setup_nodes_r_packages() {
  log_step "Step 7: bspm & R Packages"

  # ── Configure bspm Authentication ──
  # RStudio Web terminal/console does not have a polkit agent or interactive TTY for passwords.
  # We must explicitly allow the users to execute apt via bspm without a password.
  local sudoers_bspm="/etc/sudoers.d/99-bspm-domain-users"
  log_info "Configuring passwordless sudo for bspm (domain_users)"
  cat > "${sudoers_bspm}" << 'SUDOEOF'
# BIOME-CALC: Allow domain_users to use bspm for R package management without password prompts in RStudio.
%domain_users ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt-mark, /usr/bin/dpkg, /usr/lib/R/site-library/bspm/service/bspm.py
SUDOEOF
  run_cmd chmod 0440 "${sudoers_bspm}"

  local tmp_bspm
  tmp_bspm=$(mktemp /tmp/r_setup_bspm.XXXXXX.R)
  cat > "${tmp_bspm}" << 'EOF'
if (!requireNamespace("bspm", quietly=TRUE)) {
  install.packages("bspm", repos="https://cloud.r-project.org")
}
EOF
  run_cmd Rscript --vanilla "${tmp_bspm}"
  run_cmd rm -f "${tmp_bspm}"

  # Build a safe R vector from the bash array
  local r_pkg_vector
  r_pkg_vector=$(printf '"%s",' "${R_PACKAGES[@]}" | sed 's/,$//')

  local tmp_pkgs
  tmp_pkgs=$(mktemp /tmp/r_setup_pkgs.XXXXXX.R)
  cat > "${tmp_pkgs}" << EOF
suppressMessages(bspm::enable())
pkgs <- c(${r_pkg_vector})
for (p in pkgs) {
  if (!requireNamespace(p, quietly=TRUE)) tryCatch({
    install.packages(p, repos="https://cloud.r-project.org", quiet=TRUE)
    cat(sprintf("  Installed: %s\n", p))
  }, error=function(e) cat(sprintf("  FAILED: %s (%s)\n", p, e\$message)))
}
EOF
  run_cmd Rscript --vanilla "${tmp_pkgs}"
  run_cmd rm -f "${tmp_pkgs}"

  # Configure reticulate
  local tmp_reticulate
  tmp_reticulate=$(mktemp /tmp/r_setup_reticulate.XXXXXX.R)
  cat > "${tmp_reticulate}" << EOF
library(reticulate)
use_python("${PYTHON_ENV}/bin/python", required=TRUE)
tryCatch({
  tf <- reticulate::import("tensorflow")
  cat(sprintf("TensorFlow: %s\n", tf[["__version__"]]))
}, error=function(e) cat("TF will init on first use.\n"))
EOF
  run_cmd Rscript --vanilla "${tmp_reticulate}"
  run_cmd rm -f "${tmp_reticulate}"
  log_success "R packages configured"
}

# ==============================================================================
# STEP 7B: COMPILE RUST OPTIMIZATIONS
# ==============================================================================
setup_nodes_rust_compile() {
  log_step "Step 7B: Compiling Rust Native Extensions"

  if ! command -v cargo &>/dev/null; then
    log_info "Installing Rust toolchain (cargo, rustc)..."
    run_cmd apt-get update -qq
    run_cmd apt-get install -y -qq cargo rustc
  fi

  local rust_src="${WORKSPACE_ROOT}/src/biome_core_rust"
  if [[ -d "${rust_src}" ]]; then
    log_info "Compiling biome_core_rust via Cargo..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "[DRY-RUN] cargo build --release in ${rust_src}"
    else
      (cd "${rust_src}" && cargo build --release) || { log_error "Cargo build failed"; exit 1; }
      run_cmd mkdir -p /opt/rstudio-tools
      run_cmd cp "${rust_src}/target/release/libbiome_core_rust.so" "/opt/rstudio-tools/biome_core.so"
      run_cmd chmod 755 /opt/rstudio-tools/biome_core.so
      run_cmd chown root:root /opt/rstudio-tools/biome_core.so
      log_success "Compiled and deployed biome_core.so safely to /opt/rstudio-tools"
    fi
  else
    log_warn "Rust source not found at ${rust_src}"
  fi
}

# ==============================================================================
# STEP 7C: PER-USER LOCAL R LIBRARY DISK (v12.4)
# ==============================================================================
# Creates ${R_LIBS_LOCAL_ROOT} (default /var/lib/biome-Rlibs) on each node and
# sticky-bits it 1777 so every AD user can populate their own subtree without
# crossing NFS during library() fan-out.
#
# Mode A — shared with rootfs (R_LIBS_LOCAL_DEVICE empty):
#   Just mkdir + chmod 1777. Cheap, but counts against rootfs free space.
#
# Mode B — dedicated block device (R_LIBS_LOCAL_DEVICE=/dev/sdX):
#   Idempotent: if device unformatted → mkfs.${R_LIBS_LOCAL_FSTYPE}; ensure
#   /etc/fstab entry by UUID; mount; mkdir + chmod 1777.
#   Safe to re-run on already-deployed nodes after attaching disk in Proxmox.
#
# HC-14: any chmod / mkdir / mount failure aborts deploy (exit 1).
# ==============================================================================
setup_nodes_local_rlibs() {
  log_step "Step 7c: Per-user local R library disk (v12.4)"

  # Allow opt-out
  if [[ "${ENABLE_R_LIBS_LOCAL:-true}" != "true" ]]; then
    log_info "ENABLE_R_LIBS_LOCAL=false — skipping local R library disk setup"
    return 0
  fi

  local rlibs_root="${R_LIBS_LOCAL_ROOT:-/var/lib/biome-Rlibs}"
  local rlibs_dev="${R_LIBS_LOCAL_DEVICE:-}"
  local rlibs_fs="${R_LIBS_LOCAL_FSTYPE:-ext4}"

  # ── Mode B: dedicated block device ───────────────────────────────────
  if [[ -n "${rlibs_dev}" ]]; then
    log_info "Dedicated R libs disk requested: ${rlibs_dev} (${rlibs_fs})"

    if [[ ! -b "${rlibs_dev}" ]]; then
      log_error "R_LIBS_LOCAL_DEVICE=${rlibs_dev} is not a block device"
      log_error "  → After attaching the disk in Proxmox, verify with: lsblk"
      log_error "  → Then re-run this step. Aborting (HC-14)."
      exit 1
    fi

    # ── Idempotency fast-path ─────────────────────────────────────────
    # If the device is ALREADY mounted at the configured mount point with
    # the configured filesystem, the disk has already been provisioned by
    # a prior run. Skip all destructive pre-flight (wipefs/mkfs/fstab/mount)
    # and proceed straight to permissions + warm-up. This makes Step 7c
    # safely re-runnable on production nodes.
    local already_mounted_at=""
    already_mounted_at=$(awk -v dev="${rlibs_dev}" '$1==dev{print $2; exit}' /proc/mounts || true)
    if [[ -n "${already_mounted_at}" && "${already_mounted_at}" == "${rlibs_root}" ]]; then
      local mounted_fs
      mounted_fs=$(awk -v dev="${rlibs_dev}" '$1==dev{print $3; exit}' /proc/mounts || true)
      if [[ "${mounted_fs}" == "${rlibs_fs}" ]]; then
        log_info "  ${rlibs_dev} already mounted at ${rlibs_root} as ${mounted_fs} — skipping format/fstab/mount"
        # Best-effort: ensure fstab entry exists (don't fail if blkid/UUID lookup hiccups)
        local _uuid
        _uuid=$(blkid -s UUID -o value "${rlibs_dev}" 2>/dev/null || true)
        if [[ -n "${_uuid}" ]] && ! grep -qE "^UUID=${_uuid}\b" /etc/fstab 2>/dev/null; then
          log_warn "  fstab missing UUID=${_uuid} for ${rlibs_root} — adding (mount survived without it)"
          if [[ "${DRY_RUN}" != "true" ]]; then
            printf 'UUID=%s  %s  %s  defaults,nofail  0  2  # managed-by: 50_setup_nodes.sh local-Rlibs\n' \
              "${_uuid}" "${rlibs_root}" "${rlibs_fs}" >> /etc/fstab
          fi
        fi
        # Jump to the shared post-mount permission/probe/warm-up block below.
        # We do this by setting a flag and short-circuiting the rest of Mode B.
        local _rlibs_already_deployed=true
      fi
    fi

    if [[ "${_rlibs_already_deployed:-false}" != "true" ]]; then

    # ── Pessimistic pre-flight: device must NOT be in use ──────────────

    # mkfs.ext4 -F refuses ("apparently in use by the system") whenever
    # the kernel has registered partitions on the device, OR a holder
    # (LVM/MD/crypt) sits on top, OR a partition is mounted/in swap.
    # We detect each case explicitly and either remediate (wipe stale
    # signatures + partition table) or abort with a precise diagnosis.
    local devbase
    devbase=$(basename "${rlibs_dev}")

    # 1. Holders (LVM PV / MD member / crypt) — always abort
    if [[ -d "/sys/block/${devbase}/holders" ]]; then
      local holders
      holders=$(ls -1 "/sys/block/${devbase}/holders" 2>/dev/null || true)
      if [[ -n "${holders}" ]]; then
        log_error "${rlibs_dev} has active holders (LVM/MD/dm): ${holders}"
        log_error "  → Tear down the holder stack first, then re-run. Aborting (HC-14)."
        exit 1
      fi
    fi

    # 2. Partitions — list everything under the disk
    local parts
    parts=$(lsblk -nrpo NAME,TYPE "${rlibs_dev}" 2>/dev/null | awk '$2=="part"{print $1}' || true)

    # 3. Any partition mounted? abort
    if [[ -n "${parts}" ]]; then
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if awk -v dev="$p" '$1==dev{found=1} END{exit !found}' /proc/mounts; then
          log_error "${rlibs_dev}: partition ${p} is currently mounted"
          log_error "  → unmount it first, then re-run. Aborting (HC-14)."
          exit 1
        fi
        if grep -qE "^${p}\b" /proc/swaps 2>/dev/null; then
          log_error "${rlibs_dev}: partition ${p} is active swap"
          log_error "  → swapoff ${p} first, then re-run. Aborting (HC-14)."
          exit 1
        fi
      done <<< "${parts}"
    fi

    # 4. Whole-disk mounted? (rare, but possible)
    if awk -v dev="${rlibs_dev}" '$1==dev{found=1} END{exit !found}' /proc/mounts; then
      log_error "${rlibs_dev} (whole device) is currently mounted — aborting (HC-14)"
      exit 1
    fi
    if grep -qE "^${rlibs_dev}\b" /proc/swaps 2>/dev/null; then
      log_error "${rlibs_dev} is currently used as swap — aborting (HC-14)"
      exit 1
    fi

    # Detect existing whole-disk filesystem (no clobber if it matches)
    local existing_fs
    existing_fs=$(blkid -s TYPE -o value "${rlibs_dev}" 2>/dev/null || true)

    # 5. Stale signatures or a partition table that confuses mkfs?
    #    wipefs -n shows what's there without deleting. If anything is
    #    listed AND no whole-disk fs of the right type exists, we wipe.
    local stale_sigs=""
    if command -v wipefs &>/dev/null; then
      stale_sigs=$(wipefs -n "${rlibs_dev}" 2>/dev/null | awk 'NR>1{print $0}' || true)
    fi

    if [[ -z "${existing_fs}" ]]; then
      if [[ -n "${parts}" || -n "${stale_sigs}" ]]; then
        log_warn "  ${rlibs_dev} has no whole-disk filesystem but kernel sees:"
        [[ -n "${parts}" ]]      && log_warn "    partitions: $(echo "${parts}" | tr '\n' ' ')"
        [[ -n "${stale_sigs}" ]] && log_warn "    signatures: $(echo "${stale_sigs}" | tr '\n' ';' | head -c 200)"
        log_warn "  → wiping signatures + partition table so mkfs.${rlibs_fs} can proceed"
        run_cmd wipefs -a "${rlibs_dev}"
        # Force the kernel to drop cached partition table
        run_cmd partprobe "${rlibs_dev}" 2>/dev/null || true
        run_cmd blockdev --rereadpt "${rlibs_dev}" 2>/dev/null || true
        sleep 1
      fi
      log_info "  ${rlibs_dev} is unformatted → creating ${rlibs_fs}"
      run_cmd "mkfs.${rlibs_fs}" -F -L biome-Rlibs "${rlibs_dev}"
    elif [[ "${existing_fs}" != "${rlibs_fs}" ]]; then
      log_warn "  ${rlibs_dev} already has filesystem '${existing_fs}' (config wants '${rlibs_fs}')"
      log_warn "  → Refusing to reformat. Continuing with existing fs."
    else
      log_info "  ${rlibs_dev} already formatted as ${existing_fs}"
    fi

    # Ensure mount point exists
    run_cmd mkdir -p "${rlibs_root}"

    # Ensure /etc/fstab entry (by UUID — survives /dev/sdX renumbering)
    # Settle udev so blkid sees the freshly-written superblock.
    command -v udevadm &>/dev/null && udevadm settle 2>/dev/null || true
    local rlibs_uuid
    rlibs_uuid=$(blkid -s UUID -o value "${rlibs_dev}" 2>/dev/null || true)
    # Validate UUID format: 8-4-4-4-12 hex
    if [[ -z "${rlibs_uuid}" ]] || \
       ! [[ "${rlibs_uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      log_error "Could not read a valid UUID of ${rlibs_dev} (got: '${rlibs_uuid}') (HC-14)"
      log_error "  → Try: blkid ${rlibs_dev}   and re-run this step."
      exit 1
    fi
    log_info "  ${rlibs_dev} UUID=${rlibs_uuid}"
    if ! grep -qE "^UUID=${rlibs_uuid}\b" /etc/fstab 2>/dev/null; then
      log_info "  Adding fstab entry: UUID=${rlibs_uuid}  ${rlibs_root}  ${rlibs_fs}  defaults,nofail  0  2"
      if [[ "${DRY_RUN}" != "true" ]]; then
        printf 'UUID=%s  %s  %s  defaults,nofail  0  2  # managed-by: 50_setup_nodes.sh local-Rlibs\n' \
          "${rlibs_uuid}" "${rlibs_root}" "${rlibs_fs}" >> /etc/fstab
      fi
    else
      log_info "  fstab entry already present for UUID=${rlibs_uuid}"
    fi

    # Mount if not already mounted
    if ! mountpoint -q "${rlibs_root}" 2>/dev/null; then
      log_info "  Mounting ${rlibs_root}"
      run_cmd mount "${rlibs_root}"
    else
      log_info "  ${rlibs_root} already mounted"
    fi

    fi  # end: if [[ "${_rlibs_already_deployed:-false}" != "true" ]] (idempotency fast-path guard)
  else
    log_info "No R_LIBS_LOCAL_DEVICE configured — using shared rootfs path: ${rlibs_root}"
    run_cmd mkdir -p "${rlibs_root}"
  fi


  # ── Sticky-bit + ownership (HC-14: abort on failure) ─────────────────
  if [[ "${DRY_RUN}" != "true" ]]; then
    chown root:root "${rlibs_root}" || { log_error "chown root:root ${rlibs_root} failed (HC-14)"; exit 1; }
    chmod 1777 "${rlibs_root}"      || { log_error "chmod 1777 ${rlibs_root} failed (HC-14)"; exit 1; }
  fi

  # ── Sanity probe: write/read by an unprivileged identity (best-effort) ─
  if [[ "${DRY_RUN}" != "true" ]]; then
    local probe="${rlibs_root}/.deploy_probe.$$"
    if ( umask 022 && touch "${probe}" 2>/dev/null && rm -f "${probe}" ); then
      log_success "Local R libs root: ${rlibs_root} (sticky 1777, writable)"
    else
      log_error "Local R libs root: ${rlibs_root} not writable — HC-14 abort"
      exit 1
    fi
  else
    log_success "[DRY-RUN] Would prepare ${rlibs_root}"
  fi

  log_info "Renviron.site will resolve R_LIBS_USER to ${rlibs_root}/<user>/<R version>"
  log_info "Existing user packages on NFS remain reachable as fallback."

  # ── v12.6: Warm-up — pre-create per-user lib dirs ────────────────────
  # Idempotent: install -d is a no-op if dir already exists. We chown to
  # the user so the dir is writable by them on first install.packages().
  #
  # v12.8 fix: gate is now [uid >= 1000 && uid != 65534]. The previous
  # ceiling of 65000 silently excluded SSSD/Samba AD users, whose UIDs
  # are SID-mapped into the 100M+ range (e.g. 163718183).
  #
  # v12.9 fix: ENUMERATION SOURCE was `getent passwd` (bulk). On
  # SSSD-joined hosts the default is `enumerate=false` (Debian/RHEL),
  # which means bulk passwd queries return ZERO AD entries — only
  # per-name `getent passwd <name>` resolves them. Symptom on
  # biome-calc03: warmup reported "warmed=1 skipped=40" (only ladmin),
  # AD users never got a pre-created dir. v12.9 replaces the source
  # with a hybrid:
  #   1. local /etc/passwd (`getent -s files passwd`) — covers ladmin
  #      and any local-only accounts.
  #   2. AD discovery: every directory under ${NFS_HOME_BASE:-/nfs/home}
  #      is treated as a candidate username; we resolve each via
  #      per-name `getent passwd <name>` (SSSD answers individually
  #      regardless of enumerate setting). Disabled accounts return
  #      empty and are skipped.
  # NFS_HOME_BASE existence is mandatory for AD discovery; if missing
  # (single-node sandbox or NFS down), we fall back to local-only with
  # a WARN. HC-13 honored: only /var/lib/biome-Rlibs/ is touched, never
  # /nfs/home or any user file.
  #
  # Companion runtime safety net (still active for users added between
  # warmup runs and to PREPEND the per-user path to .libPaths()):
  # templates/Rprofile_site.d/04_user_lib_bootstrap.R (v12.9).
  if [[ "${ENABLE_R_LIBS_LOCAL_WARMUP:-true}" == "true" && "${DRY_RUN}" != "true" ]]; then
    local r_ver
    r_ver="$(R --version 2>/dev/null | awk '/^R version/ {print $3; exit}' | awk -F. '{print $1"."$2}')"
    if [[ -z "${r_ver}" ]]; then
      log_warn "Cannot detect R version — skipping per-user lib dir warm-up"
    else
      local nfs_home_base="${NFS_HOME_BASE:-/nfs/home}"
      log_info "Warm-up: pre-creating ${rlibs_root}/<user>/${r_ver} for existing AD/local users"
      log_info "  enumeration source: local /etc/passwd ∪ per-name lookup of dirs under ${nfs_home_base}/"
      if [[ ! -d "${nfs_home_base}" ]]; then
        log_warn "  ${nfs_home_base} not present — AD discovery skipped (local accounts only)"
      fi
      local warmup_count=0 warmup_skipped=0 warmup_failed=0 warmup_unresolved=0
      while IFS=: read -r u _ uid gid _ home shell; do
        # v12.8 gate: accepts AD/SSSD users (UIDs 100M+); excludes system
        # accounts (<1000) and the nobody sentinel (65534).
        [[ ${uid} -ge 1000 && ${uid} -ne 65534 ]] || { warmup_skipped=$((warmup_skipped+1)); continue; }
        [[ "${shell}" == */nologin || "${shell}" == */false ]] && { warmup_skipped=$((warmup_skipped+1)); continue; }
        [[ -d "${home}" ]] || { warmup_skipped=$((warmup_skipped+1)); continue; }
        local user_root="${rlibs_root}/${u}"
        local user_lib="${user_root}/${r_ver}"
        # v12.9 ownership fix: `install -d -m -o -g LEAF` only chowns the
        # LEAF; the auto-created PARENT (<rlibs_root>/<u>/) keeps the
        # root:root umask. That left every AD user unable to install
        # packages into their own dir on first contact. We now do it
        # explicitly: mkdir -p (idempotent), then chmod+chown both the
        # parent AND the leaf. Re-running this loop also HEALS dirs
        # left as root:root by earlier (broken) deploys.
        if mkdir -p "${user_lib}" 2>/dev/null \
             && chmod 0755 "${user_root}" "${user_lib}" 2>/dev/null \
             && chown "${u}:${gid}" "${user_root}" "${user_lib}" 2>/dev/null; then
          warmup_count=$((warmup_count+1))
        else
          warmup_failed=$((warmup_failed+1))
          log_warn "Warm-up: failed to create/chown ${user_lib} (skipping)"
        fi
      done < <(
        {
          # (1) Local accounts via NSS files backend
          getent -s files passwd
          # (2) AD users discovered via NFS home dir presence + per-name lookup
          if [[ -d "${nfs_home_base}" ]]; then
            local ad_name
            while IFS= read -r ad_name; do
              [[ -n "${ad_name}" ]] || continue
              # Per-name lookup: SSSD answers even with enumerate=false
              getent passwd -- "${ad_name}" 2>/dev/null || true
            done < <(find "${nfs_home_base}" -mindepth 1 -maxdepth 1 \
                          -type d -printf '%f\n' 2>/dev/null | sort -u)
          fi
        } | awk -F: '!seen[$1]++'
      )
      log_success "Warm-up: ${warmup_count} per-user lib dir(s) ready (skipped=${warmup_skipped}, failed=${warmup_failed})"
    fi
  elif [[ "${ENABLE_R_LIBS_LOCAL_WARMUP:-true}" != "true" ]]; then
    log_info "ENABLE_R_LIBS_LOCAL_WARMUP=false — runtime fragment 04_user_lib_bootstrap.R will handle per-user dirs at R startup"
  fi
}


# ==============================================================================
# STEP 7D: NFS MOUNT AUDIT (v12.4)
# ==============================================================================
# Read-only audit. Never remounts. Surfaces drift between deployed mount
# options and the values configured in setup_nodes.vars.conf so the sysadmin
# can act on TrueNAS / fstab side. PSE: detect, never silently coerce.
# ==============================================================================
setup_nodes_audit_nfs() {
  log_step "Step 7d: NFS mount audit (read-only)"

  local req_nconn="${NFS_AUDIT_REQUIRE_NCONNECT_MIN:-4}"
  local req_vers="${NFS_AUDIT_REQUIRE_VERS_MIN:-4.1}"
  local hint_lookupcache="${NFS_AUDIT_HINT_LOOKUPCACHE_ALL:-true}"

  local found=0 issues=0
  while IFS= read -r line; do
    # /proc/mounts: <dev> <mp> <fstype> <opts> <freq> <passno>
    local fstype mp opts
    fstype=$(awk '{print $3}' <<< "${line}")
    mp=$(awk     '{print $2}' <<< "${line}")
    opts=$(awk   '{print $4}' <<< "${line}")
    [[ "${fstype}" =~ ^nfs ]] || continue
    found=$((found+1))

    log_info "  NFS mount: ${mp}  (fstype=${fstype})"

    # vers
    local vers
    vers=$(grep -oE 'vers=[0-9.]+' <<< "${opts}" | head -1 | cut -d= -f2 || true)
    if [[ -z "${vers}" ]]; then
      log_warn "    [audit] no 'vers=' option in mount opts — kernel may default unsafely"
      issues=$((issues+1))
    else
      # numeric compare: split on dot
      if awk -v a="${vers}" -v b="${req_vers}" 'BEGIN{
            split(a,A,"."); split(b,B,".");
            for(i=1;i<=length(B);i++){
              ai=(A[i]==""?0:A[i]+0); bi=B[i]+0;
              if(ai<bi){exit 1} else if(ai>bi){exit 0}
            }
            exit 0
          }'; then
        log_info  "    [audit] vers=${vers} ≥ required ${req_vers} (OK)"
      else
        log_warn "    [audit] vers=${vers} < required ${req_vers} (FIX on TrueNAS / fstab)"
        issues=$((issues+1))
      fi
    fi

    # nconnect
    local nconn
    nconn=$(grep -oE 'nconnect=[0-9]+' <<< "${opts}" | head -1 | cut -d= -f2 || true)
    if [[ -z "${nconn}" ]]; then
      log_warn "    [audit] nconnect= not set — single TCP connection bottleneck under load"
      log_warn "             FIX: add 'nconnect=${req_nconn}' to fstab and remount"
      issues=$((issues+1))
    elif (( nconn < req_nconn )); then
      log_warn "    [audit] nconnect=${nconn} < required ${req_nconn}"
      issues=$((issues+1))
    else
      log_info  "    [audit] nconnect=${nconn} ≥ ${req_nconn} (OK)"
    fi

    # lookupcache
    if [[ "${hint_lookupcache}" == "true" ]]; then
      if grep -qE 'lookupcache=positive' <<< "${opts}"; then
        log_info "    [audit] lookupcache=positive (HINT: 'all' may help library() fan-out)"
      elif grep -qE 'lookupcache=' <<< "${opts}"; then
        log_info "    [audit] lookupcache present"
      else
        log_info "    [audit] lookupcache not pinned — kernel default in effect"
      fi
    fi
  done < /proc/mounts

  if (( found == 0 )); then
    log_info "No NFS mounts present on this host — audit skipped."
    return 0
  fi
  if (( issues > 0 )); then
    log_warn "NFS audit: ${issues} issue(s) flagged across ${found} mount(s) — fix on storage / fstab side"
  else
    log_success "NFS audit: ${found} mount(s) compliant with audit thresholds"
  fi
}

# ==============================================================================
# STEP 8: DEPLOY SYSTEM CONFIGURATION FILES
# ==============================================================================
setup_nodes_config_files() {
  log_step "Step 8: Deploy System Configuration Files"

  local current_ct
  current_ct=$(cat "${BIOME_CONF}/coretype" 2>/dev/null || echo "auto")
  local cpu_vendor cpu_model
  cpu_vendor=$(grep VENDOR "${BIOME_CONF}/cpu_vendor" 2>/dev/null | cut -d= -f2 || echo "unknown")

  # ── Renviron.site ──
  local renviron="/etc/R/Renviron.site"
  [[ -f "${renviron}" ]] && run_cmd cp "${renviron}" "${renviron}.bak"

  # ── R_LIBS_USER policy (v12.4 / single source of truth) ─────────────
  # Renviron.site MUST mirror the actual on-disk state:
  #   * ENABLE_R_LIBS_LOCAL=true  → emit R_LIBS_USER pointing to the
  #       local disk first, NFS \$HOME path as fallback. The local root
  #       MUST already exist (sticky 1777) — guaranteed by Step 7c.
  #   * ENABLE_R_LIBS_LOCAL=false → DO NOT emit R_LIBS_USER. R falls
  #       back to its built-in default (~/R/x86_64-pc-linux-gnu-library/<v>),
  #       which is the pre-v12.4 NFS-only behavior. Setting an explicit
  #       value here that points to a non-existent /var/lib/biome-Rlibs
  #       would break library() on every node where Step 7c was skipped.
  # PSE: the system file reflects what Step 7c actually deployed.
  local rlibs_user_line=""
  if [[ "${ENABLE_R_LIBS_LOCAL:-true}" == "true" ]]; then
    local _rlibs_root="${R_LIBS_LOCAL_ROOT:-/var/lib/biome-Rlibs}"
    rlibs_user_line="# Per-user local R library (v12.4) — eliminates NFS lookupcache storm during
# library() fan-out from PSOCK workers. Created by setup_nodes_local_rlibs()
# (sticky 1777). Fallback to NFS \$HOME path keeps pre-v12.4 packages reachable.
# Bypass for one debug session: R_LIBS_USER=\${HOME}/R/x86_64-pc-linux-gnu-library/%V R
R_LIBS_USER=${_rlibs_root}/%u/%v:\${HOME}/R/x86_64-pc-linux-gnu-library/%v"
  else
    rlibs_user_line="# Per-user local R library DISABLED (ENABLE_R_LIBS_LOCAL=false in setup_nodes.vars.conf).
# R_LIBS_USER intentionally NOT set here — R falls back to its built-in default
# (~/R/x86_64-pc-linux-gnu-library/<R-version>), i.e. NFS-only legacy behavior.
# To re-enable local-disk libraries: set ENABLE_R_LIBS_LOCAL=true and re-run Step 7c+8."
  fi

  cat > "${renviron}" <<RENVEOF
# ${BIOME_HOST} Renviron.site — Generated: $(date -Iseconds)
# Deployed by 50_setup_nodes.sh

# R Library Paths
R_LIBS_SITE=/usr/local/lib/R/site-library/:\${R_LIBS_SITE}:/usr/lib/R/library

${rlibs_user_line}

# OpenBLAS CORETYPE — NOT set here (migration-safe design).
# Detected dynamically by OS-level wrappers BEFORE R starts:
#   1. /etc/profile.d/biome-coretype.sh (for terminal R sessions)
#   2. /etc/rstudio/rsession-profile (for RStudio Server web sessions)
# This prevents OpenBLAS illegal opcode crashes by evaluating the CPU
# directly from bash before libopenblas.so is dynamically loaded.

# Temp dirs (local /Rtmp disk — NOT tmpfs, no RAM consumed, NOT OS /tmp)
TMPDIR=/Rtmp
TMP=/Rtmp
TEMP=/Rtmp
R_TEMPDIR=/Rtmp

# Python (system-wide venv)
RETICULATE_PYTHON=${PYTHON_ENV}/bin/python
EARTHENGINE_PYTHON=${PYTHON_ENV}/bin/python

# Compilation flags
_R_CHECK_COMPILATION_FLAGS_KNOWN_='-Wformat -Werror=format-security -Wdate-time'

# TensorFlow (CPU-only, no GPU)
TF_CPP_MIN_LOG_LEVEL=2
KERAS_HOME=/Rtmp/keras
CUDA_VISIBLE_DEVICES=-1

# Force BSPM to use sudo instead of pkexec
BSPM_SUDO=true

# /tmp disk size (v10.0: local disk, NOT tmpfs — no RAM consumed)
BIOME_TMP_DISK_GB=${TMP_DISK_GB:-400}

# Font configuration for ragg/systemfonts (v9.6)
FONTCONFIG_PATH=/etc/fonts

# Belt-and-suspenders: Force single-threaded BLAS at the environment level.
# With openblas-serial this is a no-op (serial ignores it). But if someone
# accidentally reinstalls openblas-pthread, this prevents the SIGSEGV by
# stopping the internal thread pool from spawning. See: rstudio/rstudio#7031
OPENBLAS_NUM_THREADS=1

# Threading: managed DYNAMICALLY by Rprofile.site. Do NOT set here.
# (OMP_NUM_THREADS, MKL_NUM_THREADS are set per-session by the profile)
RENVEOF
  run_cmd chmod 644 "${renviron}"
  log_success "Renviron.site deployed (dynamic CORETYPE, no static thread vars)"

  # ── Rprofile.site (from template) ──
  local rprofile="/etc/R/Rprofile.site"
  [[ -f "${rprofile}" ]] && run_cmd cp "${rprofile}" "${rprofile}.bak"
  rm -f /etc/R/Rprofile.site.bspm  # remove orphan bspm file from v6

  # Process the template using common_utils process_template
  # (substitutes all %%KEY%% placeholders from vars.conf)
  local tmp_profile
  tmp_profile=$(mktemp /tmp/Rprofile.site.deploy.XXXXXX)
  local generated_profile
  process_template "${RPROFILE_TEMPLATE}" generated_profile \
    BIOME_HOST="${BIOME_HOST}" \
    RPROFILE_VERSION="${RPROFILE_VERSION}" \
    VM_VCORES="${VM_VCORES}" \
    VM_RAM_GB="${VM_RAM_GB}" \
    BIOME_CONTACT="${BIOME_CONTACT}" \
    MAX_BLAS_THREADS="${MAX_BLAS_THREADS}" \
    BIOME_CONF="${BIOME_CONF}" \
    LOG_FILE="${LOG_FILE}" \
    RAMDISK_GB="${RAMDISK_GB}" \
    RSESSION_CONF_PATH="${RSESSION_CONF_PATH}" \
    TMP_WARN_THRESHOLD_PCT="${TMP_WARN_THRESHOLD_PCT:-80}"

  printf "%s" "$generated_profile" > "${tmp_profile}"
  run_cmd cp "${tmp_profile}" "${rprofile}"
  rm -f "${tmp_profile}"
  run_cmd chmod 644 "${rprofile}"

  # Validate R syntax
  log_info "Validating Rprofile.site syntax..."
  local parse_result
  parse_result=$(Rscript --vanilla -e "
tryCatch({parse(file='${rprofile}');cat('PARSE_OK')},
  error=function(e) cat(sprintf('PARSE_FAIL: %s',e\$message)))" 2>&1)

  if echo "${parse_result}" | grep -q "PARSE_OK"; then
    # ── Version assertion: rendered file must match RPROFILE_VERSION from vars.conf ──
    # NOTE: use `grep -m1` (not `grep | head -1`) — under `set -euo pipefail`,
    # `head -1` closes stdin after the first line and grep receives SIGPIPE (exit 141),
    # pipefail propagates it, and `set -e` silently kills this function BEFORE the
    # Rprofile_site.d/ fragment deployment block below ever runs. This was the exact
    # bug that left /etc/R/Rprofile_site.d/ empty on v12.2 kernel deployments.
    local rendered_version
    rendered_version=$(grep -m1 -oP 'VERSION\s*<-\s*"\K[0-9.]+' "${rprofile}" || true)
    if [[ -n "${rendered_version}" && "${rendered_version}" != "${RPROFILE_VERSION}" ]]; then
      log_error "Version drift: rendered='${rendered_version}' expected='${RPROFILE_VERSION}'"
      log_error "  → Check template or update RPROFILE_VERSION in config/setup_nodes.vars.conf"
      [[ -f "${rprofile}.bak" ]] && cp "${rprofile}.bak" "${rprofile}"
      exit 1
    fi
    log_success "Rprofile.site deployed and syntax validated (v${rendered_version:-unknown})"
  else
    log_error "Parse error: ${parse_result}"
    log_warn "Restoring backup..."
    cp "${rprofile}.bak" "${rprofile}"
    exit 1
  fi

  # ── Rprofile_site.d/ FRAGMENTS (v12.1 modular-additive) ──────────────────────
  # Deploy every templates/Rprofile_site.d/*.R.template to /etc/R/Rprofile_site.d/
  # Each fragment is independently rollback-able. See templates/Rprofile_site.d/README.md
  local frag_src_dir="$(dirname "${RPROFILE_TEMPLATE}")/Rprofile_site.d"
  local frag_dst_dir="/etc/R/Rprofile_site.d"

  if [[ -d "${frag_src_dir}" ]]; then
    log_info "Deploying Rprofile_site.d/ feature fragments from ${frag_src_dir}"
    run_cmd mkdir -p "${frag_dst_dir}"
    run_cmd chmod 755 "${frag_dst_dir}"

    # ── v12.5: pre-create /Rtmp/biome_thread_guard with sticky 1777 ──────
    # Fragments 05 and 55 write per-user audit logs here. Without sticky
    # 1777 the first user to start R becomes owner of the dir+files and
    # every subsequent user gets EACCES on cat(file=..., append=TRUE).
    # Per-user log filenames (guard_<host>_<user>.log) eliminate file-level
    # contention; this dir-level fix eliminates the create-time race.
    if [[ -d /Rtmp ]]; then
      run_cmd install -d -m 1777 /Rtmp/biome_thread_guard
      run_cmd chmod 1777 /Rtmp/biome_thread_guard
      # Heal any stale file from pre-v12.5 deployments (single shared log
      # owned by whichever user touched it first).
      if [[ -f /Rtmp/biome_thread_guard/guard_$(hostname).log ]]; then
        log_info "  v12.5 migration: removing stale shared guard log"
        run_cmd rm -f "/Rtmp/biome_thread_guard/guard_$(hostname).log"
      fi
    else
      log_warn "/Rtmp not present — skipping biome_thread_guard pre-create"
    fi

    # Backup existing deployed fragments (if any) in one timestamped tarball
    if compgen -G "${frag_dst_dir}/*.R" >/dev/null 2>&1; then
      local frag_bak="${frag_dst_dir}.bak.$(date +%s)"
      run_cmd cp -a "${frag_dst_dir}" "${frag_bak}" && \
        log_info "  backup: ${frag_bak}"
    fi

    local frag_count=0 frag_failed=0
    shopt -s nullglob
    for frag_tpl in "${frag_src_dir}"/[0-9][0-9]_*.R.template; do
      local frag_name
      frag_name="$(basename "${frag_tpl}" .template)"   # strip .template → *.R
      local frag_dst="${frag_dst_dir}/${frag_name}"
      local frag_tmp
      frag_tmp=$(mktemp /tmp/Rfrag.XXXXXX.R)

      # Substitute %%VARS%% (same key set as the main Rprofile). Fragments
      # that don't reference any var will just pass through unchanged.
      local generated_frag
      process_template "${frag_tpl}" generated_frag \
        BIOME_HOST="${BIOME_HOST}" \
        RPROFILE_VERSION="${RPROFILE_VERSION}" \
        VM_VCORES="${VM_VCORES}" \
        VM_RAM_GB="${VM_RAM_GB}" \
        BIOME_CONTACT="${BIOME_CONTACT}" \
        MAX_BLAS_THREADS="${MAX_BLAS_THREADS}" \
        BIOME_CONF="${BIOME_CONF}" \
        LOG_FILE="${LOG_FILE}" \
        RAMDISK_GB="${RAMDISK_GB}" \
        RSESSION_CONF_PATH="${RSESSION_CONF_PATH}" \
        TMP_WARN_THRESHOLD_PCT="${TMP_WARN_THRESHOLD_PCT:-80}"

      printf "%s" "${generated_frag}" > "${frag_tmp}"

      # Parse-check each fragment BEFORE deploying (fail-fast: PSE rule)
      local fpr
      fpr=$(Rscript --vanilla -e "
tryCatch({parse(file='${frag_tmp}');cat('PARSE_OK')},
  error=function(e) cat(sprintf('PARSE_FAIL: %s',e\$message)))" 2>&1)

      if echo "${fpr}" | grep -q "PARSE_OK"; then
        run_cmd cp "${frag_tmp}" "${frag_dst}"
        run_cmd chmod 644 "${frag_dst}"
        rm -f "${frag_tmp}"
        log_success "  deployed fragment: ${frag_name}"
        frag_count=$((frag_count + 1))
      else
        log_error "  parse-fail fragment ${frag_name}: ${fpr}"
        rm -f "${frag_tmp}"
        frag_failed=$((frag_failed + 1))
      fi
    done
    shopt -u nullglob

    if (( frag_failed > 0 )); then
      log_error "Rprofile_site.d: ${frag_failed} fragment(s) failed to parse — NOT deployed"
      exit 1
    fi
    log_success "Rprofile_site.d: ${frag_count} fragment(s) deployed to ${frag_dst_dir}"
  else
    log_info "No Rprofile_site.d/ sources found at ${frag_src_dir} (optional)"
  fi

  # ── Post-deploy sanity: if kernel references Rprofile_site.d/, fragments must exist ──
  # This turns silent failures (e.g. earlier SIGPIPE bug) into loud aborts.
  if grep -q 'Rprofile_site\.d' "${rprofile}" 2>/dev/null; then
    local deployed_frags
    deployed_frags=$(find "${frag_dst_dir}" -maxdepth 1 -type f -name '[0-9][0-9]_*.R' 2>/dev/null | wc -l)
    if (( deployed_frags == 0 )); then
      log_error "Kernel Rprofile.site references Rprofile_site.d/ but 0 fragments deployed in ${frag_dst_dir}"
      log_error "  → Check that ${frag_src_dir} contains [0-9][0-9]_*.R.template files"
      log_error "  → Aborting to avoid shipping a broken RStudio environment"
      exit 1
    fi
    log_success "Post-deploy sanity: ${deployed_frags} fragment(s) present in ${frag_dst_dir}"

    # ── v12.3: Build byte-compiled fragment BUNDLE (boot-time fast path) ────
    # Pessimistic contract:
    #   * Bundle is an OPTIONAL optimization; dispatcher ALWAYS falls back
    #     to the legacy per-fragment loop on any mismatch/error.
    #   * We regenerate the bundle on every deploy (cheap, deterministic).
    #   * Manifest is md5(file)  basename(file), one per line — consumed by
    #     the dispatcher to decide whether the bundle is in sync with the
    #     on-disk *.R files. If a user hand-edits a fragment, hash mismatch
    #     forces the legacy loop (single source of truth: the .R files).
    #   * Atomic: write to staging dir, fsync, then rename into place.
    #   * Ownership/permissions: bundle dir is root:root 0755, files 0644.
    #   * Idempotent: re-running produces identical output if sources didn't
    #     change (manifest hashes stable). No partial/corrupt state possible
    #     because the rename is the only visible side-effect.
    # ────────────────────────────────────────────────────────────────────────
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "[DRY-RUN] Would build ${frag_dst_dir}/.compiled/{bundle.Rc,manifest.txt}"
    else
      local bundle_dir="${frag_dst_dir}/.compiled"
      local bundle_stage
      bundle_stage=$(mktemp -d /tmp/biome_bundle.XXXXXX)
      # Concatenate fragments in lexical order with explicit separators so that
      # any syntax error's filename is visible to the R parser.
      local concat_r="${bundle_stage}/bundle.R"
      : > "${concat_r}"
      local f
      while IFS= read -r -d '' f; do
        printf '\n# <<< %s >>>\n' "$(basename "$f")" >> "${concat_r}"
        cat "$f" >> "${concat_r}"
      done < <(find "${frag_dst_dir}" -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -print0 | sort -z)

      # Byte-compile. Any parse/compile failure → skip bundle deployment
      # (dispatcher falls back to legacy loop automatically).
      local compile_log="${bundle_stage}/compile.log"
      if Rscript --vanilla -e "
options(warn=2)
tryCatch({
  suppressPackageStartupMessages(library(compiler))
  cmpfile('${concat_r}', '${bundle_stage}/bundle.Rc',
          options = list(optimize = 3L), verbose = FALSE)
  cat('BUNDLE_OK\n')
}, error = function(e) {
  cat(sprintf('BUNDLE_FAIL: %s\n', conditionMessage(e)))
  quit(status = 1)
})
" >"${compile_log}" 2>&1 && grep -q 'BUNDLE_OK' "${compile_log}"; then

        # Build manifest: md5sum  basename, sorted for deterministic output.
        # NOTE: md5sum output is already `<hash>  <path>`. We strip the leading
        # `./` from the `find -printf` output so the manifest stores bare
        # basenames matching what the dispatcher sees via basename().
        (
          cd "${frag_dst_dir}" || exit 1
          find . -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -printf '%f\n' \
            | LC_ALL=C sort \
            | xargs -r -I{} md5sum -- "{}"
        ) > "${bundle_stage}/manifest.txt"

        # Atomic install: mkdir bundle_dir if needed, then mv the two files.
        run_cmd mkdir -p "${bundle_dir}"
        run_cmd chmod 755 "${bundle_dir}"
        run_cmd chown root:root "${bundle_dir}" || true

        # Move into place (rename is atomic within /etc).
        run_cmd mv -f "${bundle_stage}/bundle.Rc"    "${bundle_dir}/bundle.Rc"
        run_cmd mv -f "${bundle_stage}/manifest.txt" "${bundle_dir}/manifest.txt"
        run_cmd chmod 644 "${bundle_dir}/bundle.Rc" "${bundle_dir}/manifest.txt"
        run_cmd chown root:root "${bundle_dir}/bundle.Rc" "${bundle_dir}/manifest.txt" || true

        local bundle_bytes frag_md5_count
        bundle_bytes=$(stat -c%s "${bundle_dir}/bundle.Rc" 2>/dev/null || echo 0)
        frag_md5_count=$(wc -l < "${bundle_dir}/manifest.txt")
        log_success "Fragment bundle: ${bundle_dir}/bundle.Rc (${bundle_bytes} bytes, ${frag_md5_count} fragments hashed)"

        # v12.3: Page-cache warm-up — prime kernel page cache for the very
        # first R session after deploy so it hits warm disk for the
        # dispatcher + bundle + fragments instead of paying cold-I/O.
        # Non-fatal (PSE fail-safe): warm-up errors NEVER break deploy.
        log_info "Warming page cache for Rprofile + fragment bundle..."
        { cat "${rprofile}" \
              "${renviron}" \
              "${bundle_dir}/bundle.Rc" \
              "${bundle_dir}/manifest.txt" \
              "${frag_dst_dir}"/[0-9][0-9]_*.R \
              > /dev/null 2>&1; } || true
        log_success "Page cache primed (dispatcher + Renviron + bundle + fragments)"
      else
        # Non-fatal: dispatcher will use the legacy per-fragment loop.
        log_warn "Fragment bundle compile failed — dispatcher will use legacy per-fragment load"
        log_warn "  compile log: $(tail -n 3 "${compile_log}" 2>/dev/null | tr '\n' ' ')"
        # If an old bundle exists, invalidate it so dispatcher doesn't load
        # a stale compiled form that predates this deploy.
        if [[ -f "${bundle_dir}/manifest.txt" ]]; then
          run_cmd rm -f "${bundle_dir}/bundle.Rc" "${bundle_dir}/manifest.txt"
          log_info "  Removed stale bundle to force legacy fallback."
        fi
      fi
      rm -rf "${bundle_stage}"
    fi
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
      cp "${re_file}" "${re_file}.bak" 2>/dev/null || true
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
      # ── v12.4: Strip R_LIBS_* shadowing (CRITICAL) ───────────────────
      # R loads ~/.Renviron AFTER /etc/R/Renviron.site, so any R_LIBS_USER /
      # R_LIBS_SITE / R_LIBS in the user file SILENTLY OVERRIDES the
      # system path deployed in Step 7c+8. A legacy hard-coded
      # `R_LIBS_USER=${HOME}/R/x86_64-pc-linux-gnu-library/4.4` from the
      # previous server keeps every library() call going through NFS,
      # vanishing the local-disk fast path and re-creating the
      # lookupcache storm. We strip them: the system file is now the
      # single source of truth (Step 7c toggle decides local-vs-NFS).
      # Backup line went into ${re_file}.bak above — recoverable.
      sed -i '/^[[:space:]]*R_LIBS_USER[[:space:]]*=/d' "${re_file}"
      sed -i '/^[[:space:]]*R_LIBS_SITE[[:space:]]*=/d' "${re_file}"
      sed -i '/^[[:space:]]*R_LIBS[[:space:]]*=/d'      "${re_file}"
      # Add warning block if missing
      if ! grep -q "Threading Configuration" "${re_file}"; then
        cat >> "${re_file}" <<'WEOF'

# =============================================================
# IMPORTANT: Threading & R Library Path Configuration
# =============================================================
# Thread settings (OMP, BLAS, MC_CORES) are managed dynamically
# by the system Rprofile.site. Do NOT set them here.
#
# R_LIBS_USER / R_LIBS_SITE / R_LIBS are managed by the system
# /etc/R/Renviron.site:
#   * If the node has the local-disk lib enabled (v12.4):
#       /var/lib/biome-Rlibs/<user>/<Rver>  (local, fast)
#       :${HOME}/R/x86_64-pc-linux-gnu-library/<Rver>  (NFS fallback)
#   * Otherwise R falls back to its built-in default
#     (~/R/x86_64-pc-linux-gnu-library/<Rver>) i.e. NFS-only.
# Defining R_LIBS_USER here would SHADOW the system path and force
# every library() call back through NFS — do NOT redefine.
# Bypass for one debug session only:
#   R_LIBS_USER=${HOME}/R/x86_64-pc-linux-gnu-library/%V R
# Audit other users with: scripts/99_check_user_renviron_overrides.sh
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
  run_cmd chmod 644 /etc/skel/.Renviron
  log_success "New-user /etc/skel/.Renviron template created"
}

# ==============================================================================
# STEP 10: LOGGING & AUDIT INFRASTRUCTURE
# ==============================================================================
setup_nodes_logging() {
  log_step "Step 10: Logging & Audit Infrastructure"

  mkdir -p "${BIOME_CONF}"
  run_cmd chmod 755 "${BIOME_CONF}"

  # Deploy audit script from template
  local tmp_audit
  tmp_audit=$(mktemp /tmp/00_audit_v27.R.deploy.XXXXXX)
  local generated_audit
  process_template "${AUDIT_TEMPLATE}" generated_audit \
    BIOME_CONF="${BIOME_CONF}" \
    LOG_FILE="${LOG_FILE}" \
    MAX_THREADS="${MAX_THREADS}" \
    NFS_HOME="${NFS_HOME}" \
    CIFS_ARCHIVE="${CIFS_ARCHIVE}" \
    PYTHON_ENV="${PYTHON_ENV}"

  printf "%s" "$generated_audit" > "${tmp_audit}"
  run_cmd cp "${tmp_audit}" "${BIOME_CONF}/00_audit_v27.R"
  rm -f "${tmp_audit}"
  run_cmd chmod 644 "${BIOME_CONF}/00_audit_v27.R"
  log_success "Audit: ${BIOME_CONF}/00_audit_v27.R"

  # System log
  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}"
  run_cmd chmod 666 "${LOG_FILE}"
  log_success "System log: ${LOG_FILE} (world-writable for AD users)"

  # RStudio converter log dir
  mkdir -p /var/log/biome_converter
  if getent group rstudio-server &>/dev/null; then
    run_cmd chown root:rstudio-server /var/log/biome_converter
    run_cmd chmod 775 /var/log/biome_converter
  fi

  # Audit config (read by 00_audit_v27.R and 99_audit_r_environment.sh)
  cat > "${BIOME_CONF}/audit.conf" <<ACONF
# BIOME-CALC Audit Config — Generated: $(date -Iseconds)
nfs_home       <- "${NFS_HOME}"
cifs_archive   <- "${CIFS_ARCHIVE}"
python_env     <- "${PYTHON_ENV}/bin/python"
log_file       <- "${LOG_FILE}"
test_ollama    <- $([ "${SKIP_OLLAMA}" = true ] && echo "FALSE" || echo "TRUE")
ACONF
  run_cmd chmod 644 "${BIOME_CONF}/audit.conf"

  # Deploy admin recipients
  mkdir -p "${BIOME_CONF}/core"
  if [[ -f "${WORKSPACE_ROOT}/config/admin_recipients.txt" ]]; then
    run_cmd cp "${WORKSPACE_ROOT}/config/admin_recipients.txt" "${BIOME_CONF}/core/admin_recipients.txt"
    run_cmd chmod 644 "${BIOME_CONF}/core/admin_recipients.txt"
  fi

  # Deploy archiver known projects config
  mkdir -p "${BIOME_CONF}/archiver"
  if [[ -f "${WORKSPACE_ROOT}/config/scopri_progetti_known.conf" ]]; then
    run_cmd cp "${WORKSPACE_ROOT}/config/scopri_progetti_known.conf" "${BIOME_CONF}/archiver/scopri_progetti_known.conf"
    run_cmd chmod 644 "${BIOME_CONF}/archiver/scopri_progetti_known.conf"
  fi

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
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "[DRY-RUN] curl -fsSL https://ollama.com/install.sh | sh"
    else
      curl -fsSL https://ollama.com/install.sh | sh
    fi
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
  local _i
  for _i in $(seq 1 15); do
    if [[ "${DRY_RUN}" == "true" ]]; then
      break
    fi
    curl -sf http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
    sleep 1
  done

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_success "[DRY-RUN] Ollama running on 127.0.0.1:11434"
  elif ! curl -sf http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
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
  run_cmd chmod 644 "${modelfile_path}"

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
  run_cmd chmod 644 "${BIOME_CONF}/ai_model"

  # Security check: Ensure Ollama is only bound to 127.0.0.1 (check column 4 of ss output)
  if ss -tlnp 2>/dev/null | awk '$4 ~ /:11434$/ {print $4}' | grep -E -q '^(0\.0\.0\.0|\*)'; then
    log_warn "SECURITY: Ollama listening on 0.0.0.0! Should be 127.0.0.1 only."
  else
    log_success "Ollama security: 127.0.0.1 only"
  fi
}

# ==============================================================================
# STEP 11A: SYSTEMD CGROUP USER SLICE LIMITS (v12.0)
# ==============================================================================
setup_nodes_cgroups() {
  log_step "Step 11A: Systemd cgroup limits (per-user dynamic fair-share)"

  local user_slice_dir="/etc/systemd/system/user-.slice.d"
  local system_slice_dir="/etc/systemd/system/system.slice.d"
  local ollama_dir="/etc/systemd/system/ollama.service.d"

  # ── Verify cgroup v2 is active ──
  local cgroup_version
  cgroup_version=$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null)
  if [[ "${cgroup_version}" != "cgroup2fs" ]]; then
    log_error "cgroup v2 not detected (got: ${cgroup_version})"
    log_error "Ubuntu 24.04 should have cgroup v2 by default. Check kernel cmdline:"
    log_error "  grep cgroup /proc/cmdline"
    log_error "  systemd.unified_cgroup_hierarchy=1 should be present (or no cgroup arg at all)"
    exit 1
  fi
  log_info "cgroup v2 confirmed (cgroup2fs)"

  run_cmd mkdir -p "${user_slice_dir}" "${system_slice_dir}"

  # ── User slice limits (template applies to every logged-in user) ──
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would write ${user_slice_dir}/50-biome-limits.conf"
  else
    cat > "${user_slice_dir}/50-biome-limits.conf" <<USEREOF
# BIOME-CALC: Per-user resource limits — generated $(date -Iseconds)
#
# DYNAMIC CPU FAIR-SHARE:
#   No CPUQuota set — empty server gives 1 user all available cores.
#   Multiple active users share via CPUWeight=100 proportionally.
#
# MEMORY:
#   MemoryHigh = soft limit (throttling above it, no kill)
#   MemoryMax  = catastrophic ceiling (kills inside this slice only)
#   MemorySwapMax = small to keep swap as a brake, not a relief valve
#
# Tuned for: ${VM_VCORES} cores, ${VM_RAM_GB} GB RAM

[Slice]
MemoryAccounting=yes
MemoryHigh=${USER_SLICE_MEMORY_HIGH}
MemoryMax=${USER_SLICE_MEMORY_MAX}
MemorySwapMax=${USER_SLICE_SWAP_MAX}

CPUAccounting=yes
CPUWeight=${USER_SLICE_CPU_WEIGHT}

TasksAccounting=yes
TasksMax=${USER_SLICE_TASKS_MAX}

IOAccounting=yes
IOWeight=${USER_SLICE_IO_WEIGHT}
USEREOF
    chmod 644 "${user_slice_dir}/50-biome-limits.conf"
    log_success "User slice limits: MemoryHigh=${USER_SLICE_MEMORY_HIGH}, MemoryMax=${USER_SLICE_MEMORY_MAX}, dynamic CPU"
  fi

  # ── System slice protection (floor for nginx, sssd, telemetry, rstudio supervisor) ──
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would write ${system_slice_dir}/50-biome-reserve.conf"
  else
    cat > "${system_slice_dir}/50-biome-reserve.conf" <<SYSEOF
# BIOME-CALC: Reserve resources for system services
# Generated $(date -Iseconds)
#
# MemoryMin: hard kernel-enforced floor — users cannot eat into this
# MemoryLow: soft floor — kernel reclaims from user.slice first under pressure
# CPUWeight=200: system services prioritized 2:1 over users during contention

[Slice]
MemoryAccounting=yes
MemoryMin=${SYSTEM_SLICE_MEMORY_MIN}
MemoryLow=${SYSTEM_SLICE_MEMORY_LOW}

CPUAccounting=yes
CPUWeight=${SYSTEM_SLICE_CPU_WEIGHT}
SYSEOF
    chmod 644 "${system_slice_dir}/50-biome-reserve.conf"
    log_success "System slice protection: MemoryMin=${SYSTEM_SLICE_MEMORY_MIN}, CPUWeight=${SYSTEM_SLICE_CPU_WEIGHT}"
  fi

  # ── Ollama CPU priority adjustment ──
  if [[ "${SKIP_OLLAMA}" != "true" ]]; then
    run_cmd mkdir -p "${ollama_dir}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "[DRY-RUN] Would write ${ollama_dir}/50-biome-cpu.conf"
    else
      cat > "${ollama_dir}/50-biome-cpu.conf" <<OLLEOF
# BIOME-CALC: Ollama CPU priority — yield to user compute
# Existing biome-hardening.conf already sets MemoryMax=24G
# This adds CPU weight so AI inference doesn't compete with research workloads
[Service]
CPUAccounting=yes
CPUWeight=${OLLAMA_CPU_WEIGHT}
OLLEOF
      chmod 644 "${ollama_dir}/50-biome-cpu.conf"
      log_success "Ollama CPUWeight=${OLLAMA_CPU_WEIGHT} (yields to user compute)"
    fi
  else
    log_info "Skipping Ollama CPU config (SKIP_OLLAMA=true)"
  fi

  # ── Apply changes ──
  run_cmd systemctl daemon-reload

  if [[ "${DRY_RUN}" != "true" ]]; then
    # Apply to any currently-active user slices
    local active_user_slices
    active_user_slices=$(systemctl list-units --type=slice --no-legend 2>/dev/null \
                         | awk '/user-[0-9]+\.slice/ {print $1}')
    if [[ -n "${active_user_slices}" ]]; then
      log_info "Applying limits to currently-active user slices..."
      while IFS= read -r slice; do
        [[ -z "$slice" ]] && continue
        systemctl set-property "$slice" \
          MemoryHigh="${USER_SLICE_MEMORY_HIGH}" \
          MemoryMax="${USER_SLICE_MEMORY_MAX}" \
          MemorySwapMax="${USER_SLICE_SWAP_MAX}" \
          CPUWeight="${USER_SLICE_CPU_WEIGHT}" \
          TasksMax="${USER_SLICE_TASKS_MAX}" \
          2>/dev/null && log_info "  Updated: $slice" \
                      || log_warn "  Could not update $slice (may have ended)"
      done <<< "${active_user_slices}"
    fi

    # Restart Ollama to pick up CPU weight (memory limit was already in place)
    if [[ "${SKIP_OLLAMA}" != "true" ]] && systemctl is-active --quiet ollama; then
      run_cmd systemctl restart ollama
      log_info "Ollama restarted with new CPU weight"
    fi
  fi

  # ── Verification ──
  if [[ "${DRY_RUN}" != "true" ]]; then
    log_info "Verifying deployed configuration..."
    if systemctl cat user-.slice 2>/dev/null | grep -q "MemoryHigh=${USER_SLICE_MEMORY_HIGH}"; then
      log_success "user-.slice template active and correct"
    else
      log_warn "user-.slice template may not be loaded — check: systemctl cat user-.slice"
    fi

    # Show what a fresh user session would inherit
    log_info "Effective limits for new user sessions:"
    log_info "  Memory: throttle@${USER_SLICE_MEMORY_HIGH}, kill@${USER_SLICE_MEMORY_MAX}"
    log_info "  CPU:    weight=${USER_SLICE_CPU_WEIGHT} (dynamic fair-share, no hard cap)"
    log_info "  Tasks:  max=${USER_SLICE_TASKS_MAX}"
  fi

  log_info "Existing logged-in users keep current limits until logout."
  log_info "Monitor live: systemd-cgtop -P"

  # Run 3-layer verification after deployment (non-dry-run only)
  [[ "${DRY_RUN}" != "true" ]] && setup_nodes_verify_cgroups
}

# ==============================================================================
# CGROUP DEPLOYMENT VERIFICATION (3-layer)
# ==============================================================================
setup_nodes_verify_cgroups() {
  log_step "Cgroup Deployment Verification (3-layer check)"
  local all_ok=true

  # ── Layer 1: Drop-in file present ──
  local dropin="/etc/systemd/system/user-.slice.d/50-biome-limits.conf"
  if [[ -f "${dropin}" ]]; then
    log_success "Layer 1 [PASS] Drop-in present: ${dropin}"
  else
    log_error "Layer 1 [FAIL] Drop-in missing: ${dropin}"
    log_warn  "         → Run: sudo $0  then select option 8"
    all_ok=false
  fi

  # ── Layer 2: systemd has loaded the drop-in and resolves it to the
  #            expected byte count on a real instantiated user-NNNN.slice.
  #
  # Why not `systemctl cat user-.slice`?
  #   `user-.slice` is a TEMPLATE unit. On modern systemd `systemctl cat`
  #   refuses it ("Unit user-.slice could not be loaded.") and even when it
  #   worked, the rendered output prints byte counts (e.g. 429496729600),
  #   never the literal "400G" from our drop-in — making any string-grep
  #   compare a coin-flip across systemd versions. Instead we ask systemd
  #   to RESOLVE the property on a live child slice and compare bytes.
  #
  # If no user is logged in yet (no user-NNNN.slice instantiated), Layer 2
  # is SKIPPED — Layer 3 will pick it up the moment a user logs in.
  local expected_bytes=""
  if command -v numfmt &>/dev/null; then
    expected_bytes=$(numfmt --from=iec "${USER_SLICE_MEMORY_MAX}" 2>/dev/null || true)
  fi
  if [[ -z "${expected_bytes}" ]]; then
    # Fallback parser: handles plain "400G" / "120G" / "8G" / bare bytes
    case "${USER_SLICE_MEMORY_MAX}" in
      *G|*g) expected_bytes=$(( ${USER_SLICE_MEMORY_MAX%[Gg]} * 1024 * 1024 * 1024 )) ;;
      *M|*m) expected_bytes=$(( ${USER_SLICE_MEMORY_MAX%[Mm]} * 1024 * 1024 )) ;;
      *K|*k) expected_bytes=$(( ${USER_SLICE_MEMORY_MAX%[Kk]} * 1024 )) ;;
      *)     expected_bytes="${USER_SLICE_MEMORY_MAX}" ;;
    esac
  fi

  local target_slice
  target_slice=$(systemctl list-units --type=slice --no-legend 2>/dev/null \
                 | awk '/user-[0-9]+\.slice/ {print $1; exit}')

  if [[ -z "${target_slice}" ]]; then
    log_info "Layer 2 [SKIP] no instantiated user-NNNN.slice (no users logged in)"
    log_info "         → Layer 3 will verify on next user login"
  else
    local actual_bytes
    actual_bytes=$(systemctl show -p MemoryMax --value "${target_slice}" 2>/dev/null || echo "")
    if [[ "${actual_bytes}" == "${expected_bytes}" ]]; then
      log_success "Layer 2 [PASS] ${target_slice}: MemoryMax=${actual_bytes} bytes (= ${USER_SLICE_MEMORY_MAX})"
    elif [[ -z "${actual_bytes}" || "${actual_bytes}" == "infinity" ]]; then
      log_warn "Layer 2 [WARN] ${target_slice}: MemoryMax=${actual_bytes:-<empty>} (drop-in not effective)"
      log_warn "         → Try: systemctl daemon-reload && systemctl set-property ${target_slice} MemoryMax=${USER_SLICE_MEMORY_MAX}"
      all_ok=false
    else
      log_warn "Layer 2 [WARN] ${target_slice}: MemoryMax=${actual_bytes} ≠ expected ${expected_bytes} (${USER_SLICE_MEMORY_MAX})"
      log_warn "         → A runtime override may be shadowing the drop-in. Check:"
      log_warn "            ls /etc/systemd/system.control/${target_slice}.d/ 2>/dev/null"
      all_ok=false
    fi
  fi

  # ── Layer 3: Kernel cgroup files for active user sessions ──
  local active_slices
  active_slices=$(systemctl list-units --type=slice --no-legend 2>/dev/null \
                  | awk '/user-[0-9]+\.slice/ {print $1}')
  if [[ -z "${active_slices}" ]]; then
    log_info "Layer 3: No active user slices (no users currently logged in)"
  else
    log_info "Layer 3: Checking kernel cgroup files for active user slices..."
    while IFS= read -r slice; do
      [[ -z "$slice" ]] && continue
      local uid
      uid=$(echo "$slice" | grep -oP 'user-\K[0-9]+')
      [[ -z "$uid" ]] && continue

      # cgroup v2 path
      local cg_mem_file="/sys/fs/cgroup/user.slice/user-${uid}.slice/memory.max"
      if [[ -f "${cg_mem_file}" ]]; then
        local cg_val
        cg_val=$(cat "${cg_mem_file}" 2>/dev/null || echo "error")
        if [[ "${cg_val}" == "max" ]]; then
          log_warn "Layer 3 [WARN] ${slice}: kernel shows 'max' (unlimited) — user must logout and login again"
          log_warn "         → Admin force-reset: loginctl terminate-user $(id -nu "${uid}" 2>/dev/null || echo "${uid}")"
          all_ok=false
        else
          local cg_gb
          cg_gb=$(awk "BEGIN{printf \"%.0f\", ${cg_val}/1073741824}")
          log_success "Layer 3 [PASS] ${slice}: memory.max = ${cg_gb} GB (kernel-enforced)"
        fi
      else
        # Fallback: check cgroup v1
        local cg_v1
        cg_v1=$(find /sys/fs/cgroup/memory -name "memory.limit_in_bytes" \
                      -path "*user-${uid}*" 2>/dev/null | head -1)
        if [[ -n "${cg_v1}" ]]; then
          local v1_val
          v1_val=$(cat "${cg_v1}" 2>/dev/null || echo "error")
          log_info "Layer 3 [INFO] ${slice}: cgroup v1 memory = ${v1_val} bytes (${cg_v1})"
        else
          log_warn "Layer 3 [WARN] ${slice}: no cgroup memory file found (v2 path missing, v1 not found)"
          all_ok=false
        fi
      fi
    done <<< "${active_slices}"
  fi

  if [[ "${all_ok}" == true ]]; then
    log_success "All cgroup verification layers passed."
  else
    log_warn "One or more cgroup checks failed — see details above."
    log_info "  Users needing re-login: ask them to log out and back in."
    log_info "  Force-reset a session:  loginctl terminate-user <username>"
  fi
}

# ==============================================================================
# STEP 11B: ORPHAN PROCESS CLEANUP
# ==============================================================================
setup_nodes_orphan_cleanup() {
  log_step "Step 11b: Orphan Process Cleanup (cron + email)"

  local ORPHAN_LOG_DIR="/var/log/r_orphan_cleanup"

  # 1. Ensure log structures exist
  run_cmd mkdir -p "${ORPHAN_LOG_DIR}/notifications"
  run_cmd chmod 755 "${ORPHAN_LOG_DIR}"
  run_cmd chmod 777 "${ORPHAN_LOG_DIR}/notifications" # Let anyone write their own logs

  # 2. Deploy configs
  log_info "Deploying email maps, admin recipients and main configuration..."
  run_cmd mkdir -p "${BIOME_CONF}/conf"
  run_cmd cp -f "${WORKSPACE_ROOT}/config/admin_recipients.txt" "${BIOME_CONF}/conf/admin_recipients.txt"
  run_cmd cp -f "${WORKSPACE_ROOT}/config/user_email_map.txt" "${BIOME_CONF}/conf/user_email_map.txt"
  
  run_cmd cp -f "${VARS_CONF}" "${BIOME_CONF}/conf/setup_nodes.vars.conf"
  run_cmd chmod 600 "${BIOME_CONF}/conf/setup_nodes.vars.conf"
  
  log_info "Generating r_orphan_cleanup.conf..."
  if [[ "${DRY_RUN}" == true ]]; then
    log_info "[DRY-RUN] envsubst on r_orphan_cleanup.conf.template -> ${BIOME_CONF}/conf/r_orphan_cleanup.conf"
  else
    local dns_csv
    dns_csv=$(echo "${SMTP_DNS_SERVERS}" | tr ' ' ',')
    
    # Derive dynamic node sender (e.g. noreply-biome-calc02@unibo.it)
    local node_sender
    node_sender="noreply-$(hostname -s)@unibo.it"
    
    export SMTP_HOST SMTP_PORT SENDER_EMAIL="${node_sender}" MAIL_DOMAIN MAIL_DOMAINS_USER SMTP_DNS_SERVERS="${dns_csv}" KILL_TIMEOUT BIOME_CONF
    envsubst "\${SMTP_HOST} \${SMTP_PORT} \${SENDER_EMAIL} \${MAIL_DOMAIN} \${MAIL_DOMAINS_USER} \${SMTP_DNS_SERVERS} \${KILL_TIMEOUT} \${BIOME_CONF}" < "${WORKSPACE_ROOT}/templates/r_orphan_cleanup.conf.template" > "${BIOME_CONF}/conf/r_orphan_cleanup.conf"
    run_cmd chmod 644 "${BIOME_CONF}/conf/r_orphan_cleanup.conf"
  fi

  # 3. Deploy scripts into BIOME_CONF
  log_info "Deploying executable daemon scripts..."
  run_cmd mkdir -p "${BIOME_CONF}/script"
  local scripts_to_deploy=(
    "cleanup_r_orphans.sh.template:cleanup_r_orphans.sh"
    "notify_r_orphans.sh.template:notify_r_orphans.sh"
    "r_orphan_report.sh.template:r_orphan_report.sh"
    "send_email.sh.template:send_email.sh"
    "orphan_cleanup_helpers.sh.template:orphan_cleanup_helpers.sh"
  )

  for pair in "${scripts_to_deploy[@]}"; do
    local tpl="${pair%%:*}"
    local dest="${pair##*:}"
    if [[ "${DRY_RUN}" == true ]]; then
      log_info "[DRY-RUN] Deploying script ${dest}..."
    else
      cp -f "${WORKSPACE_ROOT}/templates/${tpl}" "${BIOME_CONF}/script/${dest}"
      chmod +x "${BIOME_CONF}/script/${dest}"
      log_success "Deployed ${dest}"
    fi
  done
  
  # Deploy library for archiver alignment
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Deploying common_utils.sh to ${BIOME_CONF}/script/"
  else
    run_cmd cp -f "${WORKSPACE_ROOT}/lib/common_utils.sh" "${BIOME_CONF}/script/common_utils.sh"
    run_cmd chmod +x "${BIOME_CONF}/script/common_utils.sh"
    log_success "Deployed common_utils.sh library"
  fi

  # 4. Bind to cron
  log_info "Wiring cron schedules..."
  local cron_cleanup="${ORPHAN_CRON_CLEANUP:-15 * * * *} root ${BIOME_CONF}/script/cleanup_r_orphans.sh > /dev/null 2>&1"
  local cron_notify="${ORPHAN_CRON_NOTIFY:-00 18 * * *} root ${BIOME_CONF}/script/notify_r_orphans.sh --mail > /dev/null 2>&1"
  local cron_report="${ORPHAN_CRON_REPORT:-00 08 * * 1} root ${BIOME_CONF}/script/r_orphan_report.sh --mail > /dev/null 2>&1"
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Sarebbero stati scritti i seguenti job in /etc/cron.d/r_orphan_cleanup:"
    log_info "[DRY-RUN] ${cron_cleanup}"
    log_info "[DRY-RUN] ${cron_notify}"
    log_info "[DRY-RUN] ${cron_report}"
  else
    cat > /etc/cron.d/r_orphan_cleanup <<EOF
# R Orphan Process Cleanup Cron Jobs (Generato automaticamente)
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${cron_cleanup}
${cron_notify}
${cron_report}
EOF
    run_cmd chmod 0644 /etc/cron.d/r_orphan_cleanup
    log_success "Cron schedules synchronized in /etc/cron.d/r_orphan_cleanup."
  fi
}

# ==============================================================================
# STEP 11C: BIOME Precision Archiver
# ==============================================================================
setup_nodes_project_archiver() {
    log_step "Step 11c: BIOME Precision Archiver"
    local ARCHIVE_LOG_DIR="/var/log/biome-log/biome_archive"

    # 1. Ensure log structures exist
    run_cmd mkdir -p "${ARCHIVE_LOG_DIR}"
    run_cmd chmod 755 "${ARCHIVE_LOG_DIR}"

    # 2. Deploy configs
    log_info "Deploying archiver configuration files..."
    run_cmd mkdir -p "${BIOME_CONF}/conf"
    run_cmd cp -f "${WORKSPACE_ROOT}/config/scopri_progetti_known.conf" "${BIOME_CONF}/conf/"
    
    log_info "Generating archiver config..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] envsubst on archiver config templates"
    else
        # No specific template for archiver.conf, assuming it's scopri_progetti_known.conf
        # If there was a template for archiver.conf, it would be processed here.
        : # No specific envsubst for a main archiver.conf provided in the snippet
    fi

    # 3. Deploy scripts into BIOME_CONF
    log_info "Deploying executable archiver scripts..."
    run_cmd mkdir -p "${BIOME_CONF}/script"
    local archiver_scripts_to_deploy=(
        "scopri_progetti.sh.template:scopri_progetti.sh"
        "unibo_archive_manager.sh.template:unibo_archive_manager.sh"
    )

    for pair in "${archiver_scripts_to_deploy[@]}"; do
        local tpl="${pair%%:*}"
        local dest="${pair##*:}"
        if [[ "${DRY_RUN}" == true ]]; then
            log_info "[DRY-RUN] Deploying script ${dest}..."
        else
            # Export variables needed for envsubst
            export BIOME_CONF ARCHIVE_LOG_DIR ARCHIVE_CONF_DIR ARCHIVE_CSV_FILE NFS_HOME ARCHIVE_STORAGE_ROOT
            envsubst "\${BIOME_CONF} \${ARCHIVE_LOG_DIR} \${ARCHIVE_CONF_DIR} \${ARCHIVE_CSV_FILE} \${NFS_HOME} \${ARCHIVE_STORAGE_ROOT}" < "${WORKSPACE_ROOT}/templates/${tpl}" > "${BIOME_CONF}/script/${dest}"
            run_cmd chmod +x "${BIOME_CONF}/script/${dest}"
            log_success "Deployed ${dest}"
        fi
    done

    # 4. Bind to cron 
    log_info "Wiring archiver cron schedules..."
    local cron_archiver="${ARCHIVE_CRON_SCHEDULE:-00 03 * * *} root ${BIOME_CONF}/script/unibo_archive_manager.sh --apply > /dev/null 2>&1"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "[DRY-RUN] Sarebbe stato scritto il seguente job in /etc/cron.d/biome_archiver:"
      log_info "[DRY-RUN] ${cron_archiver}"
    else
      cat > /etc/cron.d/biome_archiver <<EOF
# BIOME Precision Archiver Cron Job (Generato automaticamente)
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${cron_archiver}
EOF
      run_cmd chmod 0644 /etc/cron.d/biome_archiver
      log_success "Archiver cron schedule synchronized."
    fi

    log_success "BIOME Precision Archiver configuration complete."
}

# ==============================================================================
# STEP 11d: BIOME ADMIN TOOLS
# ==============================================================================
setup_nodes_admin_tools() {
    log_step "Step 11d: Setup BIOME Admin Tools"
    
    local tools_dir="${BIOME_CONF}/script/tools"
    local source_tools="${WORKSPACE_ROOT}/scripts/tools"
    
    if [[ ! -d "${source_tools}" ]]; then
        log_warn "Tools source directory not found: ${source_tools}. Skipping."
        return 0
    fi
    
    log_info "Deploying BIOME diagnostic and management tools to ${tools_dir}..."
    run_cmd mkdir -p "${tools_dir}"
    
    # --- Hardware-Aware Dependency Check (Pessimistic) ---
    log_info "Pessimistic hardware assessment for diagnostic dependencies..."
    local deps=()
    
    # 1. Disk/SMART
    if lsblk -d -o NAME,TYPE | grep -q "disk"; then
        command_exists smartctl || deps+=("smartmontools")
        lsblk -d -o NAME,MODEL | grep -qi "nvme" && { command_exists nvme || deps+=("nvme-cli"); }
    fi
    
    # 2. Network/Ethtool
    lspci | grep -Ei "ethernet|network|fiber" -q && { command_exists ethtool || deps+=("ethtool"); }
    
    # 3. Base Utilities
    command_exists lsb_release || deps+=("lsb-release")
    command_exists dmidecode || deps+=("dmidecode")
    
    # 4. Network Mount Utilities (NFS/SMB)
    grep -q "nfs" /proc/mounts && { command_exists mount.nfs || deps+=("nfs-common"); }
    grep -qE "cifs|smb" /proc/mounts && { command_exists mount.cifs || deps+=("cifs-utils"); }

    if [[ ${#deps[@]} -gt 0 ]]; then
        log_info "Installing missing hardware utilities: ${deps[*]}"
        run_cmd apt-get update -qq
        run_cmd apt-get install -y "${deps[@]}" > /dev/null
    fi

    # Copy all files from scripts/tools/ maintaining structure
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] cp -r ${source_tools}/* ${tools_dir}/"
    else
        # Iterate over files in tools source
        for tool in "${source_tools}"/*; do
            [ -f "$tool" ] || continue
            local tool_name
            tool_name=$(basename "$tool")
            cp "$tool" "${tools_dir}/${tool_name}"
            chmod 0755 "${tools_dir}/${tool_name}"
            log_success "Deployed tool: ${tool_name}"
        done
    fi
    
    log_success "BIOME Admin Tools deployment complete."
}

# ==============================================================================
# STEP 11F: HC-13 TRIAGE TOOLING (minimal Rprofile + r_minimal + harnesses)
# ==============================================================================
# Per HC-13 ("Adapt System, Not User Script") we deploy the minimal-profile
# fail-safe Rprofile and the user-script triage harnesses to /usr/local/bin/.
# These are SYSTEM-SIDE tools — they never modify user .R files.
#
# Pessimistic invariants:
#   * Templates parse-checked before install (PSE: fail-fast).
#   * chmod failures abort with exit 1 (HC-10).
#   * Idempotent: re-run safe (overwrites with current versions).
#   * Atomic: stage in tmp, verify, then mv into place.
# ==============================================================================
setup_nodes_hc13_tools() {
  log_step "Step 11f: HC-13 user-script triage tooling"

  # ── 1. Render & deploy minimal Rprofile ───────────────────────────────
  if [[ ! -f "${RPROFILE_MIN_TEMPLATE}" ]]; then
    log_warn "Minimal Rprofile template not found: ${RPROFILE_MIN_TEMPLATE} — skipping HC-13 tools"
    return 0
  fi

  local min_dst="/etc/R/Rprofile_minimal.R"
  local min_tmp
  min_tmp=$(mktemp /tmp/Rprofile_minimal.XXXXXX.R)

  local generated_min
  process_template "${RPROFILE_MIN_TEMPLATE}" generated_min \
    BIOME_HOST="${BIOME_HOST}" \
    RPROFILE_VERSION="${RPROFILE_VERSION}" \
    BIOME_CONF="${BIOME_CONF}" \
    LOG_FILE="${LOG_FILE}"
  printf "%s" "${generated_min}" > "${min_tmp}"

  # Parse-check before install (PSE)
  local min_pr
  min_pr=$(Rscript --vanilla -e "
tryCatch({parse(file='${min_tmp}');cat('PARSE_OK')},
  error=function(e) cat(sprintf('PARSE_FAIL: %s',e\$message)))" 2>&1)

  if ! echo "${min_pr}" | grep -q "PARSE_OK"; then
    log_error "Minimal Rprofile parse-fail: ${min_pr}"
    rm -f "${min_tmp}"
    exit 1
  fi

  if [[ "${DRY_RUN}" != "true" ]]; then
    cp "${min_tmp}" "${min_dst}"
    chmod 644 "${min_dst}" || { log_error "chmod 644 ${min_dst} failed"; exit 1; }
    chown root:root "${min_dst}" 2>/dev/null || true
  fi
  rm -f "${min_tmp}"
  log_success "Minimal Rprofile deployed: ${min_dst}"

  # ── 2. Deploy r_minimal launcher + Rscript symlink ────────────────────
  local rmin_src="${WORKSPACE_ROOT}/scripts/r_minimal.sh"
  local rmin_dst="/usr/local/bin/r_minimal"
  local rmin_rscript="/usr/local/bin/r_minimal_rscript"

  if [[ -f "${rmin_src}" ]]; then
    if [[ "${DRY_RUN}" != "true" ]]; then
      cp "${rmin_src}" "${rmin_dst}"
      chmod 0755 "${rmin_dst}" || { log_error "chmod 0755 ${rmin_dst} failed (HC-10)"; exit 1; }
      chown root:root "${rmin_dst}" 2>/dev/null || true
      ln -sf "${rmin_dst}" "${rmin_rscript}" || { log_error "ln -sf ${rmin_rscript} failed (HC-10)"; exit 1; }
    fi
    log_success "Deployed: ${rmin_dst} (+ symlink ${rmin_rscript})"
  else
    log_warn "r_minimal source missing: ${rmin_src}"
  fi

  # ── 3. Deploy diagnostic harnesses ────────────────────────────────────
  local harnesses=(
    "scripts/99_diagnose_user_script.sh:/usr/local/bin/99_diagnose_user_script.sh"
    "scripts/99_diagnose_lussu_hang.sh:/usr/local/bin/99_diagnose_lussu_hang.sh"
  )
  for pair in "${harnesses[@]}"; do
    local src="${WORKSPACE_ROOT}/${pair%%:*}"
    local dst="${pair##*:}"
    if [[ ! -f "${src}" ]]; then
      log_warn "Harness source missing: ${src}"
      continue
    fi
    if [[ "${DRY_RUN}" != "true" ]]; then
      cp "${src}" "${dst}"
      chmod 0755 "${dst}" || { log_error "chmod 0755 ${dst} failed (HC-10)"; exit 1; }
      chown root:root "${dst}" 2>/dev/null || true
    fi
    log_success "Deployed: ${dst}"
  done

  log_success "HC-13 tooling deployed. Quick test:"
  log_info "  /usr/local/bin/r_minimal -e 'biome_diag()'"
  log_info "  /usr/local/bin/99_diagnose_user_script.sh /path/to/user_script.R"
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
  echo "    - Terminal:     /etc/profile.d/biome-coretype.sh"
  echo "    - RStudio:      /etc/rstudio/rsession-profile"
  echo "    - Current:      ${current_ct} (vendor=${cpu_vendor})"
  echo ""
  echo "  Next steps:"
  echo "    1. sudo systemctl restart rstudio-server"
  echo "    2. In R: source('${BIOME_CONF}/00_audit_v27.R')"
  echo "    3. In R: status()"
  echo ""
  echo "  Key files deployed:"
  echo "    /etc/R/Rprofile.site"
  echo "    /etc/R/Renviron.site"
  echo "    /etc/profile.d/biome-coretype.sh"
  echo "    /etc/rstudio/rsession-profile"
  echo "    ${BIOME_CONF}/00_audit_v27.R"
  echo "    ${BIOME_CONF}/audit.conf"
  echo "    ${LOG_FILE}"
  echo "    ${SWAP_FILE} (${SWAP_SIZE_GB}GB)"
  if [[ "${SKIP_OLLAMA}" != true ]]; then
    echo "    ${BIOME_CONF}/ai_model"
    echo "    ${BIOME_CONF}/r-coder.modelfile"
  fi
  echo "    ${BIOME_CONF}/script/tools/ (Diagnostic tools)"
  echo ""
}

# ==============================================================================
# STEP 11e: MASTER DIAGNOSTIC REPORT
# ==============================================================================
setup_nodes_master_report() {
    log_step "Step 11e: Master Diagnostic Report"
    
    local summary_script="${BIOME_CONF}/script/tools/deployment_summary.sh"
    
    if [[ ! -f "${summary_script}" ]]; then
        log_error "Master report script not found: ${summary_script}"
        log_warn "Please run Step 11d (Setup BIOME Admin Tools) first."
        return 1
    fi

    log_info "Generating comprehensive node report (Hardware + R + Storage)..."
    
    # We pipe the setup summary context into the master report tool
    setup_nodes_summary_content | "${summary_script}" --mail || {
        log_error "Master report generation or delivery failed."
        return 1
    }

    log_success "Master report sent to administrators."
}

# Helper to provide the summary content as a string
setup_nodes_summary_content() {
  local current_ct
  current_ct=$(cat "${BIOME_CONF}/coretype" 2>/dev/null || echo "unknown")
  echo "--- BIOME-CALC Deployment Success ---"
  echo "Node:      ${BIOME_HOST}"
  echo "Coretype:  ${current_ct}"
  echo "Swap:      ${SWAP_SIZE_GB}GB"
  echo "Location:  ${BIOME_CONF}"
}

# ==============================================================================
# MAIN — INTERACTIVE MENU (legacy pattern)
# ==============================================================================

if [[ "${DO_UNINSTALL}" == true ]]; then
  setup_nodes_uninstall
  exit 0
fi

# ── Handle --verify CLI flag (non-interactive cgroup + version check) ──
if [[ "${DO_VERIFY}" == true ]]; then
  setup_nodes_preflight
  setup_nodes_verify_cgroups
  # Check deployed Rprofile version (grep -m1, not `grep | head -1`: see SIGPIPE note above)
  deployed_ver=$(grep -m1 -oP 'VERSION\s*<-\s*"\K[0-9.]+' /etc/R/Rprofile.site 2>/dev/null || true)
  if [[ -n "${deployed_ver}" ]]; then
    if [[ "${deployed_ver}" == "${RPROFILE_VERSION}" ]]; then
      log_success "Rprofile version: deployed=v${deployed_ver} expected=v${RPROFILE_VERSION} [OK]"
    else
      log_warn "Rprofile version drift: deployed=v${deployed_ver} expected=v${RPROFILE_VERSION}"
      log_warn "  → Re-deploy: sudo $0  then select option 3"
    fi
  else
    log_warn "Could not read deployed Rprofile version from /etc/R/Rprofile.site"
    log_warn "  → File may not exist or was deployed without the version assertion"
  fi

  # ── Rprofile_site.d fragments verification ──
  log_step "Rprofile_site.d/ Fragment Verification"
  frag_src_dir="$(dirname "${RPROFILE_TEMPLATE}")/Rprofile_site.d"
  frag_dst_dir="/etc/R/Rprofile_site.d"
  kernel_needs_frags=false
  if [[ -f /etc/R/Rprofile.site ]] && grep -q 'Rprofile_site\.d' /etc/R/Rprofile.site; then
    kernel_needs_frags=true
  fi

  if [[ "${kernel_needs_frags}" == true ]]; then
    log_info "Deployed kernel references Rprofile_site.d/ → fragments are REQUIRED"
  else
    log_info "Deployed kernel does NOT reference Rprofile_site.d/ → fragments optional"
  fi

  if [[ -d "${frag_dst_dir}" ]]; then
    deployed_count=$(find "${frag_dst_dir}" -maxdepth 1 -type f -name '[0-9][0-9]_*.R' 2>/dev/null | wc -l)
    log_info "Deployed fragments in ${frag_dst_dir}: ${deployed_count}"
    if (( deployed_count > 0 )); then
      find "${frag_dst_dir}" -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -printf '  %f\n' 2>/dev/null | sort
    fi
  else
    deployed_count=0
    log_warn "Directory ${frag_dst_dir} does NOT exist"
  fi

  if [[ -d "${frag_src_dir}" ]]; then
    src_count=$(find "${frag_src_dir}" -maxdepth 1 -type f -name '[0-9][0-9]_*.R.template' 2>/dev/null | wc -l)
    log_info "Source fragment templates in ${frag_src_dir}: ${src_count}"
  else
    src_count=0
  fi

  if [[ "${kernel_needs_frags}" == true ]]; then
    if (( deployed_count == 0 )); then
      log_error "FAIL — kernel needs fragments but none are deployed"
      log_error "  → Re-deploy: sudo $0  then select option 3"
    elif (( src_count > 0 && deployed_count != src_count )); then
      log_warn "Fragment count mismatch: ${deployed_count} deployed vs ${src_count} in source"
      log_warn "  → Re-deploy option 3 to sync"
    else
      log_success "Fragments OK: ${deployed_count} deployed"
    fi
  fi
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
echo "  7) Run Swap Creation only (Step 5b)"
echo "  8) Setup CGroups only (Step 11a)"
echo "  9) Setup Orphan Process Cleanup (Step 11b)"
echo "  10) Setup BIOME Precision Archiver (Step 11c)"
echo "  T) Setup BIOME Admin Tools (Step 11d)"
echo "  L) Setup local R libs disk + NFS audit (Step 7c+7d, v12.4)"
echo "  H) Deploy HC-13 triage tooling (Step 11f: minimal Rprofile + r_minimal + harnesses)"
echo "  R) Master Diagnostic Report (Step 11e)"
echo "  O) Deploy Optimized Rprofile (Rust plugin + Template)"
echo "  V) Verify deployment (cgroups + Rprofile version)"
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
    setup_nodes_tmp_disk
    setup_nodes_swap
    setup_nodes_python
    setup_nodes_r_packages
    setup_nodes_local_rlibs
    setup_nodes_audit_nfs
    setup_nodes_config_files
    setup_nodes_migrate_users
    setup_nodes_logging
    setup_nodes_ollama
    setup_nodes_cgroups
    setup_nodes_orphan_cleanup
    setup_nodes_project_archiver
    setup_nodes_admin_tools
    setup_nodes_hc13_tools
    setup_nodes_blas_test
    setup_nodes_summary
    setup_nodes_master_report
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
  7)
    setup_nodes_preflight
    setup_nodes_swap
    ;;
  8)
    setup_nodes_preflight
    setup_nodes_cgroups
    ;;
  9)
    setup_nodes_preflight
    setup_nodes_orphan_cleanup
    ;;
  10)
    setup_nodes_preflight
    setup_nodes_project_archiver
    ;;
  T)
    setup_nodes_preflight
    setup_nodes_admin_tools
    ;;
  L)
    setup_nodes_preflight
    setup_nodes_local_rlibs
    setup_nodes_audit_nfs
    ;;
  H)
    setup_nodes_preflight
    setup_nodes_hc13_tools
    ;;
  R)
    setup_nodes_preflight
    setup_nodes_master_report
    ;;
  O)
    setup_nodes_preflight
    RPROFILE_TEMPLATE="${WORKSPACE_ROOT}/templates/Rprofile_site_optimized.R.template"
    setup_nodes_rust_compile
    setup_nodes_config_files
    ;;
  V)
    setup_nodes_preflight
    setup_nodes_verify_cgroups
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
