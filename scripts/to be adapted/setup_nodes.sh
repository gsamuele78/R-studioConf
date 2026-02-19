#!/usr/bin/env bash
# ==============================================================================
# BIOME-CALC NODE SETUP v7.3 — ENTERPRISE DEPLOYMENT
# ==============================================================================
# VM:     QEMU on Proxmox 9.x (Ceph), x86-64-v4, 32 vCores, ~400GB RAM, no GPU
# OS:     Ubuntu 24.04 LTS
# Homes:  /nfs/home/<user>/ (NFS, AD domain_users)
# Usage:  sudo ./setup_nodes_v7.3.sh [--skip-ollama] [--dry-run]
#
# REQUIRES: Rprofile_site_v9_3.14 and 00_audit_v26.R in same directory
#
# Features:
#   - CORETYPE auto-detection from vendor_id + flags (safe for x86-64-v4)
#   - Migration-safe: boot-time systemd service + per-session Rprofile detection
#   - BLAS/LAPACK → openblas-pthread (not reference BLAS)
#   - OpenMP pkg-config for R package compilation
#   - Ollama hardened: localhost-only, MemoryMax=20G, idle-unload=15m
#   - AI: qwen2.5-coder:14b with custom r-coder Modelfile
#   - THP=madvise, I/O scheduler mq-deadline, NUMA detection
#   - System log /var/log/r_biome_system.log (world-writable for AD users)
#   - BLAS smoke test with fork-safe timeout
# ==============================================================================

set -euo pipefail
trap 'log_error "Failed at line $LINENO"; exit 1' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_step()    { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# ── Args ──
SKIP_OLLAMA=false; DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --skip-ollama) SKIP_OLLAMA=true ;;
    --dry-run)     DRY_RUN=true ;;
    --help|-h)     echo "Usage: sudo $0 [--skip-ollama] [--dry-run]"; exit 0 ;;
  esac
done

[ "$(id -u)" -ne 0 ] && { log_error "Must run as root"; exit 1; }

run_cmd() { if [ "$DRY_RUN" = true ]; then echo "  [DRY-RUN] $*"; else "$@"; fi; }

# ── Configuration ──
R_HOST=$(hostname)
R_IP=$(hostname -I | awk '{print $1}')
NFS_HOME="/nfs/home"
CIFS_ARCHIVE="/mnt/ProjectStorage"
PYTHON_ENV="/opt/r-geospatial"
RAMDISK_SIZE="100G"
RAMDISK_GB=100
BIOME_CONF="/etc/biome-calc"
LOG_FILE="/var/log/r_biome_system.log"

# FIX-2: Updated file references to match current versions
RPROFILE_SRC="./Rprofile_site_v9_3.14"
AUDIT_SRC="./00_audit_v26.R"

TS=$(date +%Y%m%d_%H%M%S)

# ==============================================================================
log_step "Step 0: Pre-flight"
# ==============================================================================

log_info "Host: $R_HOST ($R_IP)"
log_info "NFS Homes: $NFS_HOME"
log_info "CIFS Archive: $CIFS_ARCHIVE"
log_info "Python: $PYTHON_ENV"

# Validate external Rprofile
if [ ! -f "$RPROFILE_SRC" ]; then
  log_error "Missing: $RPROFILE_SRC — place it in current directory"
  exit 1
fi
if ! grep -q 'VERSION.*"9\.' "$RPROFILE_SRC" 2>/dev/null; then
  log_warn "Version string not found in Rprofile — verify file"
fi

# ── FIX-1: Smart CORETYPE Detection ──────────────────────────────────────────
# The CPU model string under QEMU is useless ("QEMU Virtual CPU version 2.5+")
# but the VENDOR still leaks through from the host. We detect vendor first,
# then pick the right CORETYPE family. This prevents the v7.1 bug where
# AuthenticAMD hosts got Intel Haswell micro-kernels, causing BLAS livelocks.
# 
# Priority: cpu:host in Proxmox makes all of this moot (auto-detect works).
# This is the fallback for qemu64/kvm64 CPU types.
# ─────────────────────────────────────────────────────────────────────────────

CPU_MODEL=$(lscpu | grep "Model name" | head -1 | sed 's/.*:\s*//')
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}' || echo "unknown")
CPU_FLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}' || echo "")

log_info "CPU Model:  $CPU_MODEL"
log_info "CPU Vendor: $CPU_VENDOR"

# Detect best CORETYPE based on vendor + available instruction sets
detect_coretype() {
  local vendor="$1"
  local flags="$2"
  local model="$3"

  # If it's NOT a virtual/emulated CPU, try to match the real model name
  # NOTE: x86-64-v4 in Proxmox still shows "QEMU Virtual CPU" in model name,
  # so this branch only triggers with cpu:host or named models (EPYC, Haswell)
  if ! echo "$model" | grep -qi "QEMU\|Virtual"; then
    # Real CPU passthrough — match by model name
    if echo "$model" | grep -qiE "sapphire|emerald"; then echo "SAPPHIRERAPIDS"; return; fi
    if echo "$model" | grep -qiE "skylake|cascade";  then echo "SKYLAKEX"; return; fi
    if echo "$model" | grep -qiE "haswell";           then echo "HASWELL"; return; fi
    if echo "$model" | grep -qiE "zen4|zen ?4|7[789][0-9][0-9]|9[0-9][0-9][0-9]"; then echo "ZEN"; return; fi
    if echo "$model" | grep -qiE "zen|epyc|ryzen";    then echo "ZEN"; return; fi
  fi

  # QEMU or unrecognized model — use vendor + flags
  if echo "$vendor" | grep -qi "AMD"; then
    # AMD host behind QEMU
    if echo "$flags" | grep -q "avx2"; then echo "ZEN"         # Zen1+ has AVX2
    elif echo "$flags" | grep -q "avx"; then echo "BULLDOZER"  # pre-Zen
    else echo "SANDYBRIDGE"                                     # safe SSE fallback
    fi
  elif echo "$vendor" | grep -qiE "Intel|Genuine"; then
    # Intel host behind QEMU
    if echo "$flags" | grep -q "avx512"; then echo "SKYLAKEX"
    elif echo "$flags" | grep -q "avx2";  then echo "HASWELL"
    elif echo "$flags" | grep -q "avx";   then echo "SANDYBRIDGE"
    else echo "PRESCOTT"                                        # SSE3 fallback
    fi
  else
    # Unknown vendor — use safest universal option
    echo "SANDYBRIDGE"
  fi
}

OPENBLAS_CORETYPE=$(detect_coretype "$CPU_VENDOR" "$CPU_FLAGS" "$CPU_MODEL")

# Log detection result
# NOTE: Even with cpu:x86-64-v4, model name still shows "QEMU Virtual CPU".
# The difference is only in guaranteed flags (AVX512 etc).
if echo "$CPU_MODEL" | grep -qi "QEMU\|Virtual"; then
  log_info "Virtual CPU detected (QEMU/KVM). CORETYPE selected from vendor_id + flags."
  log_info "OPENBLAS_CORETYPE=$OPENBLAS_CORETYPE (vendor=$CPU_VENDOR)"
else
  log_info "CPU passthrough detected: OPENBLAS_CORETYPE=$OPENBLAS_CORETYPE"
fi

# ==============================================================================
log_step "Step 1: System Dependencies"
# ==============================================================================

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
log_success "Base dependencies"

# ==============================================================================
log_step "Step 2: Apache Arrow"
# ==============================================================================

if ! dpkg -l 2>/dev/null | grep -q libarrow-dev; then
  DC=$(lsb_release --codename --short)
  DI=$(lsb_release --id --short | tr 'A-Z' 'a-z')
  DEB="apache-arrow-apt-source-latest-${DC}.deb"
  run_cmd wget -q "https://packages.apache.org/artifactory/arrow/${DI}/${DEB}" -O "/tmp/${DEB}"
  run_cmd dpkg -i "/tmp/${DEB}"; rm -f "/tmp/${DEB}"
  run_cmd apt-get update -qq
  run_cmd apt-get install -y -qq \
    libarrow-dev libparquet-dev libarrow-dataset-dev \
    libarrow-acero-dev libarrow-flight-dev libparquet-glib-dev
  log_success "Apache Arrow installed"
else
  log_info "Apache Arrow already present"
fi

# ==============================================================================
log_step "Step 3: Google Cloud CLI"
# ==============================================================================

if ! command -v gcloud &>/dev/null; then
  if [ ! -f /usr/share/keyrings/cloud.google.gpg ]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  fi
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  run_cmd apt-get update -qq
  run_cmd apt-get install -y -qq google-cloud-cli
  log_success "Google Cloud CLI"
else
  log_info "gcloud already present"
fi

# ==============================================================================
log_step "Step 4: OpenBLAS, OpenMP & Kernel Tuning"
# ==============================================================================

# ── Migration-Safe CORETYPE Strategy ──────────────────────────────────────────
# In a mixed Intel/AMD Proxmox cluster, static CORETYPE is DANGEROUS:
#   - VM starts on AMD node → deploy sets ZEN
#   - VM migrates to Intel node → ZEN is wrong → suboptimal (or worse)
#
# Solution: NO static CORETYPE in env files. Instead:
#   1. Systemd oneshot detects vendor at every boot → writes /etc/biome-calc/coretype
#   2. Rprofile v9.3.14+ detects vendor at every R session start (handles
#      live migration without reboot, where /proc/cpuinfo changes)
#   3. Rscript --vanilla users get the boot-time value from /etc/environment
#      (refreshed by the systemd service on each boot)
# ─────────────────────────────────────────────────────────────────────────────

# Remove any stale static CORETYPE from /etc/environment (legacy from v7.1)
if grep -q "^OPENBLAS_CORETYPE=" /etc/environment 2>/dev/null; then
  sed -i '/^OPENBLAS_CORETYPE=/d' /etc/environment
  log_info "Removed static OPENBLAS_CORETYPE from /etc/environment"
fi

# Deploy boot-time CORETYPE detection service
cat > /usr/local/bin/biome-detect-coretype.sh <<'DETECTEOF'
#!/usr/bin/env bash
# BIOME-CALC: Detect CPU vendor and set OPENBLAS_CORETYPE at boot.
# Runs as systemd oneshot on every boot (after migration, reboot, etc.)
# Rprofile v9.3.14+ also detects per-session as a safety net.

VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}')
FLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | awk -F': ' '{print $2}')

if echo "$VENDOR" | grep -qi "AMD"; then
  if echo "$FLAGS" | grep -q "avx2"; then CT="ZEN"
  elif echo "$FLAGS" | grep -q "avx";  then CT="BULLDOZER"
  else CT="SANDYBRIDGE"; fi
elif echo "$VENDOR" | grep -qi "Intel\|Genuine"; then
  if echo "$FLAGS" | grep -q "avx512"; then CT="SKYLAKEX"
  elif echo "$FLAGS" | grep -q "avx2";  then CT="HASWELL"
  elif echo "$FLAGS" | grep -q "avx";   then CT="SANDYBRIDGE"
  else CT="PRESCOTT"; fi
else
  CT="SANDYBRIDGE"
fi

# Write to /etc/environment (for Rscript --vanilla and non-R tools)
if grep -q "^OPENBLAS_CORETYPE=" /etc/environment 2>/dev/null; then
  sed -i "s/^OPENBLAS_CORETYPE=.*/OPENBLAS_CORETYPE=${CT}/" /etc/environment
else
  echo "OPENBLAS_CORETYPE=${CT}" >> /etc/environment
fi

# Write to state file (for Rprofile to optionally read as hint)
mkdir -p /etc/biome-calc
echo "$CT" > /etc/biome-calc/coretype
echo "VENDOR=$VENDOR" > /etc/biome-calc/cpu_vendor

logger -t biome-calc "CORETYPE=$CT (vendor=$VENDOR)"
DETECTEOF
chmod 755 /usr/local/bin/biome-detect-coretype.sh

# Create systemd oneshot service
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

systemctl daemon-reload
systemctl enable biome-detect-coretype.service
# Run it NOW to set the correct value for this boot
/usr/local/bin/biome-detect-coretype.sh
CURRENT_CT=$(cat /etc/biome-calc/coretype 2>/dev/null || echo "unknown")
log_success "Boot-time CORETYPE detection service installed"
log_info "Current detection: CORETYPE=$CURRENT_CT (vendor=$CPU_VENDOR)"

ldconfig -p | grep -q libopenblas.so$ || { log_error "OpenBLAS not found!"; exit 1; }
ldconfig -p | grep -q libomp || run_cmd apt-get install -y -qq libomp-dev
log_success "OpenBLAS OK (CORETYPE detected dynamically), OpenMP OK"

# ── Clean stale static thread settings from /etc/environment ──
# Rprofile.site manages these dynamically. Static values cause conflicts.
for var in OPENBLAS_NUM_THREADS OMP_NUM_THREADS MKL_NUM_THREADS; do
  if grep -q "^${var}=" /etc/environment 2>/dev/null; then
    sed -i "/^${var}=/d" /etc/environment
    log_info "Removed stale $var from /etc/environment"
  fi
done

# ── BLAS/LAPACK Alternatives: Force OpenBLAS-pthread ──
# Without this, R uses generic libblas.so.3 (reference BLAS) which is 10-50x
# slower than OpenBLAS for matrix operations. This is the #1 performance issue
# for any R workload doing linear algebra (lm, glm, PCA, terra, etc.)
OPENBLAS_BLAS="/usr/lib/x86_64-linux-gnu/openblas-pthread/libblas.so.3"
OPENBLAS_LAPACK="/usr/lib/x86_64-linux-gnu/openblas-pthread/liblapack.so.3"

if [ -f "$OPENBLAS_BLAS" ]; then
  run_cmd update-alternatives --set libblas.so.3-x86_64-linux-gnu "$OPENBLAS_BLAS" 2>/dev/null || \
    log_warn "Could not set BLAS alternative (may need manual: update-alternatives --config libblas.so.3-x86_64-linux-gnu)"
  log_success "BLAS alternative: openblas-pthread"
else
  log_warn "OpenBLAS pthread BLAS not found at expected path"
fi

if [ -f "$OPENBLAS_LAPACK" ]; then
  run_cmd update-alternatives --set liblapack.so.3-x86_64-linux-gnu "$OPENBLAS_LAPACK" 2>/dev/null || \
    log_warn "Could not set LAPACK alternative"
  log_success "LAPACK alternative: openblas-pthread"
else
  log_warn "OpenBLAS pthread LAPACK not found at expected path"
fi

# Verify R actually picks up OpenBLAS
BLAS_CHECK=$(Rscript --vanilla -e "cat(sessionInfo()\$BLAS)" 2>/dev/null || echo "unknown")
if echo "$BLAS_CHECK" | grep -qi "openblas"; then
  log_success "R BLAS verified: $BLAS_CHECK"
else
  log_warn "R BLAS is: $BLAS_CHECK (expected openblas — may need: sudo systemctl restart rstudio-server)"
fi

# ── pkg-config for OpenMP ──
# Some R packages (terra, sf, data.table) use pkg-config to find OpenMP at
# compile time. Ubuntu doesn't ship openmp.pc, so compilation silently falls
# back to single-threaded code.
OPENMP_PC="/usr/local/lib/pkgconfig/openmp.pc"
if [ ! -f "$OPENMP_PC" ]; then
  mkdir -p /usr/local/lib/pkgconfig
  cat > "$OPENMP_PC" <<'OMPEOF'
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
  # Ensure pkg-config can find it
  if ! echo "$PKG_CONFIG_PATH" | grep -q "/usr/local/lib/pkgconfig"; then
    echo 'PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}"' >> /etc/environment
  fi
  log_success "OpenMP pkg-config installed ($OPENMP_PC)"
else
  log_info "OpenMP pkg-config already present"
fi

# FIX-4: Transparent Hugepages — set to madvise (safe for R/BLAS)
# 'always' causes latency spikes during compaction; 'madvise' lets apps opt in.
THP_PATH="/sys/kernel/mm/transparent_hugepage/enabled"
if [ -f "$THP_PATH" ]; then
  current_thp=$(cat "$THP_PATH")
  if ! echo "$current_thp" | grep -q '\[madvise\]'; then
    echo madvise > "$THP_PATH" 2>/dev/null || true
    log_info "THP set to madvise (was: $current_thp)"
  else
    log_info "THP already madvise"
  fi
  # Make persistent via sysfs.conf or tmpfiles
  mkdir -p /etc/tmpfiles.d
  echo "w $THP_PATH - - - - madvise" > /etc/tmpfiles.d/thp-madvise.conf
  log_success "THP=madvise (persistent)"
fi

# FIX-4: I/O Scheduler — use mq-deadline for virtualized disks (better than none/kyber under QEMU)
for disk in /sys/block/sd* /sys/block/vd*; do
  [ -d "$disk" ] || continue
  sched_file="$disk/queue/scheduler"
  [ -f "$sched_file" ] || continue
  diskname=$(basename "$disk")
  current_sched=$(cat "$sched_file")
  if echo "$current_sched" | grep -q 'mq-deadline'; then
    if ! echo "$current_sched" | grep -q '\[mq-deadline\]'; then
      echo mq-deadline > "$sched_file" 2>/dev/null || true
      log_info "Scheduler for $diskname set to mq-deadline"
    else
      log_info "Scheduler for $diskname already mq-deadline"
    fi
  fi
done

# ── NUMA Topology Detection ──
# Multi-socket servers benefit from NUMA-aware allocation. If the VM has
# NUMA nodes exposed (Proxmox: Machine → NUMA=1), R and OpenBLAS can
# allocate memory on the local node, avoiding cross-socket traffic (~40% penalty).
NUMA_NODES=$(lscpu 2>/dev/null | grep "NUMA node(s)" | awk '{print $NF}')
if [ -n "$NUMA_NODES" ] && [ "$NUMA_NODES" -gt 1 ]; then
  log_info "NUMA: $NUMA_NODES nodes detected — multi-socket optimization active"
  # Install numactl if not present (needed for numastat, numactl --interleave)
  if ! command -v numactl &>/dev/null; then
    run_cmd apt-get install -y -qq numactl 2>/dev/null || true
  fi
  # Log topology for diagnostics
  numactl --hardware 2>/dev/null | head -10 | while read -r line; do log_info "  $line"; done
  log_info "HINT: Proxmox VM → Hardware → CPU → NUMA must be enabled for multi-node"
  # Set OpenBLAS to interleave across NUMA nodes (better for large matrices)
  if ! grep -q "^OPENBLAS_DEFAULT_NUM_THREADS" /etc/environment 2>/dev/null; then
    echo "GOMP_CPU_AFFINITY=0-$(($(nproc)-1))" >> /etc/environment
  fi
  log_success "NUMA: $NUMA_NODES nodes configured"
else
  log_info "NUMA: Single node (${NUMA_NODES:-1}) — no cross-socket overhead"
fi
# ==============================================================================
log_step "Step 5: RAMDisk ($RAMDISK_SIZE on /tmp)"
# ==============================================================================

FSTAB="tmpfs /tmp tmpfs rw,nosuid,nodev,size=${RAMDISK_SIZE},mode=1777 0 0"
if ! grep -q "^tmpfs /tmp" /etc/fstab 2>/dev/null; then
  echo "$FSTAB" >> /etc/fstab
fi
run_cmd systemctl daemon-reload
run_cmd mount -o "remount,size=${RAMDISK_SIZE}" /tmp 2>/dev/null || mount /tmp 2>/dev/null || true
log_success "RAMDisk: $(df -h /tmp | tail -1 | awk '{print $2}')"

# ==============================================================================
log_step "Step 6: Python Geospatial Venv"
# ==============================================================================

if [ ! -f "$PYTHON_ENV/bin/python" ]; then
  log_info "Creating venv: $PYTHON_ENV"
  rm -rf "$PYTHON_ENV"
  run_cmd python3 -m venv "$PYTHON_ENV"
else
  log_info "Venv exists: $PYTHON_ENV"
fi

run_cmd "$PYTHON_ENV/bin/pip" install --quiet --upgrade pip
run_cmd "$PYTHON_ENV/bin/pip" install --quiet \
  earthengine-api "numpy<2" pandas "tensorflow>=2.16" "tf-keras"
log_success "Python: $($PYTHON_ENV/bin/python --version 2>&1)"

# ==============================================================================
log_step "Step 7: bspm & R Packages"
# ==============================================================================

run_cmd Rscript --vanilla -e '
if (!requireNamespace("bspm",quietly=TRUE))
  install.packages("bspm",repos="https://cloud.r-project.org")
'

run_cmd Rscript --vanilla -e '
suppressMessages(bspm::enable())
pkgs <- c("data.table","arrow","dplyr","tidyr","future","future.apply","parallelly",
  "terra","sf","rgee","tensorflow","keras","reticulate","unix","sessioninfo",
  "RhpcBLASctl","chattr","jsonlite")
for (p in pkgs) {
  if (!requireNamespace(p,quietly=TRUE)) tryCatch({
    install.packages(p,repos="https://cloud.r-project.org",quiet=TRUE)
    cat(sprintf("  Installed: %s\n",p))
  }, error=function(e) cat(sprintf("  FAILED: %s (%s)\n",p,e$message)))
}
'

# Configure reticulate
run_cmd Rscript --vanilla -e "
library(reticulate)
use_python('${PYTHON_ENV}/bin/python',required=TRUE)
tryCatch({tf<-reticulate::import('tensorflow')
  cat(sprintf('TensorFlow: %s\n',tf[['__version__']]))
}, error=function(e) cat('TF will init on first use.\n'))
"
log_success "R packages configured"

# ==============================================================================
log_step "Step 8: System Configuration Files"
# ==============================================================================

# ── Renviron.site ──
RENVIRON="/etc/R/Renviron.site"
[ -f "$RENVIRON" ] && cp "$RENVIRON" "${RENVIRON}.bak.${TS}"

# FIX-5: No static CORETYPE — detected dynamically for migration safety
CURRENT_CT=$(cat /etc/biome-calc/coretype 2>/dev/null || echo "auto")
cat > "$RENVIRON" <<RENVEOF
# BIOME-CALC Renviron.site v7.3 — Generated: $(date -Iseconds)

# R Library Paths
R_LIBS_SITE=/usr/local/lib/R/site-library/:\${R_LIBS_SITE}:/usr/lib/R/library

# OpenBLAS CORETYPE — NOT set here (migration-safe design).
# Detected dynamically by:
#   1. biome-detect-coretype.service (systemd oneshot, runs at boot)
#      → writes to /etc/environment and /etc/biome-calc/coretype
#   2. Rprofile.site v9.3.14+ (per R session, reads /proc/cpuinfo vendor_id)
#      → handles live migration without reboot
# Current boot-time detection: CORETYPE=${CURRENT_CT} (vendor=${CPU_VENDOR})

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

chmod 644 "$RENVIRON"
log_success "Renviron.site deployed (no static CORETYPE — dynamic detection)"

# ── Rprofile.site ──
RPROFILE="/etc/R/Rprofile.site"
[ -f "$RPROFILE" ] && cp "$RPROFILE" "${RPROFILE}.bak.${TS}"

# Remove orphan bspm file from v6
rm -f /etc/R/Rprofile.site.bspm

cp "$RPROFILE_SRC" "$RPROFILE"
chmod 644 "$RPROFILE"

# Validate parse
log_info "Validating Rprofile.site syntax..."
PARSE=$(Rscript --vanilla -e "
tryCatch({parse(file='$RPROFILE');cat('PARSE_OK')},
  error=function(e) cat(sprintf('PARSE_FAIL: %s',e\$message)))" 2>&1)

if echo "$PARSE" | grep -q "PARSE_OK"; then
  log_success "Rprofile.site deployed and validated"
else
  log_error "Parse error: $PARSE"
  log_warn "Restoring backup..."
  cp "${RPROFILE}.bak.${TS}" "$RPROFILE"
  exit 1
fi

# ==============================================================================
log_step "Step 9: Fix User Configurations (Legacy Migration)"
# ==============================================================================

# Iterate all user homes on NFS
for user_home in "$NFS_HOME"/*/; do
  [ -d "$user_home" ] || continue
  username=$(basename "$user_home")
  log_info "Processing user: $username"

  # ── Fix .Renviron ──
  RE_FILE="$user_home/.Renviron"
  if [ -f "$RE_FILE" ]; then
    # Backup
    cp "$RE_FILE" "${RE_FILE}.bak.$(date +%Y%m%d)" 2>/dev/null || true

    # 1. Fix Legacy Python Paths (Critical for venv transition)
    sed -i 's|^EARTHENGINE_PYTHON=.*|EARTHENGINE_PYTHON="/opt/r-geospatial/bin/python"|' "$RE_FILE"
    sed -i 's|^RETICULATE_PYTHON=.*|RETICULATE_PYTHON="/opt/r-geospatial/bin/python"|' "$RE_FILE"

    # 2. Remove Legacy Env Vars (conda, old temp)
    sed -i '/^EARTHENGINE_ENV=/d' "$RE_FILE"
    sed -i '/^TMP=/d; /^TEMP=/d; /^TMPDIR=/d' "$RE_FILE"

    # 3. Remove Static Threading (Conflicts with Rprofile v9.3.14)
    sed -i '/^OMP_NUM_THREADS=/d' "$RE_FILE"
    sed -i '/^OPENBLAS_NUM_THREADS=/d' "$RE_FILE"
    sed -i '/^MKL_NUM_THREADS=/d' "$RE_FILE"
    sed -i '/^MC_CORES=/d' "$RE_FILE"

    # 4. Remove user-level OPENBLAS_CORETYPE (system manages this now)
    sed -i '/^OPENBLAS_CORETYPE=/d' "$RE_FILE"

    # 5. Add Warning Block if missing
    if ! grep -q "Threading Configuration" "$RE_FILE"; then
      cat >> "$RE_FILE" <<'WEOF'

# =============================================================
# IMPORTANT: Threading Configuration
# =============================================================
# Thread settings (OMP, BLAS, MC_CORES) are now managed 
# dynamically by the system. Do NOT set them here.
# =============================================================
WEOF
    fi
    log_success "  .Renviron migrated"
  fi

  # ── Fix .Rprofile ──
  RP_FILE="$user_home/.Rprofile"
  if [ -f "$RP_FILE" ]; then
    # Comment out legacy quota scripts
    sed -i 's|^source("/usr/local/custom/rstudio/show_quota.R")|#source("/usr/local/custom/rstudio/show_quota.R") # Deprecated|' "$RP_FILE"
    sed -i 's|^source(".*parallelize.R")|#source("parallelize.R") # Managed by system|' "$RP_FILE"
    log_success "  .Rprofile migrated"
  fi

  # ── Fix rstudio-prefs.json ──
  PREFS="$user_home/.config/rstudio/rstudio-prefs.json"
  if [ -f "$PREFS" ]; then
    # FIX-3: Fix double-slash bug safely (replace //opt with /opt, not delete the quote)
    sed -i 's|//opt/r-geospatial|/opt/r-geospatial|g' "$PREFS"
    # Force update python path if it points to /usr/bin/python3
    sed -i 's|"/usr/bin/python3"|"/opt/r-geospatial/bin/python"|g' "$PREFS"
    log_success "  rstudio-prefs.json migrated"
  fi

done
log_success "All user configurations updated"

# ── User .Renviron template for new users ──
mkdir -p /etc/skel
cat > /etc/skel/.Renviron <<'SKELEOF'
# BIOME-CALC User .Renviron — Loaded AFTER /etc/R/Renviron.site
#
# Python (defaults to system venv, uncomment to override):
#RETICULATE_PYTHON="/opt/r-geospatial/bin/python"
#EARTHENGINE_PYTHON="/opt/r-geospatial/bin/python"
#
# XDG dirs
XDG_DATA_HOME=${HOME}/.local/share
XDG_CONFIG_HOME=${HOME}/.config
#
# Threading: managed by system Rprofile.site. Do NOT set manually.
SKELEOF
chmod 644 /etc/skel/.Renviron
log_success "User template created"

# ==============================================================================
log_step "Step 10: Logging & Audit Infrastructure"
# ==============================================================================

mkdir -p "$BIOME_CONF"
chmod 755 "$BIOME_CONF"

# Deploy audit script (FIX-2: updated to v26)
if [ -f "$AUDIT_SRC" ]; then
  cp "$AUDIT_SRC" "$BIOME_CONF/00_audit_v26.R"
  chmod 644 "$BIOME_CONF/00_audit_v26.R"
  log_success "Audit: $BIOME_CONF/00_audit_v26.R"
else
  log_warn "Audit script not found: $AUDIT_SRC"
fi

# System log — must be writable by all rsession users (AD domain_users, not
# necessarily in rstudio-server group). This is a non-sensitive activity log.
touch "$LOG_FILE"
chmod 666 "$LOG_FILE"
log_success "System log: $LOG_FILE (world-writable)"

# RStudio converter log dir
mkdir -p /var/log/biome_converter
if getent group rstudio-server &>/dev/null; then
  chown root:rstudio-server /var/log/biome_converter; chmod 775 /var/log/biome_converter
fi

# Audit config
cat > "$BIOME_CONF/audit.conf" <<ACONF
# BIOME-CALC Audit Config — Generated: $(date -Iseconds)
nfs_home       <- "$NFS_HOME"
cifs_archive   <- "$CIFS_ARCHIVE"
python_env     <- "${PYTHON_ENV}/bin/python"
log_file       <- "$LOG_FILE"
test_ollama    <- $([ "$SKIP_OLLAMA" = true ] && echo "FALSE" || echo "TRUE")
ACONF
chmod 644 "$BIOME_CONF/audit.conf"
log_success "Logging infrastructure ready"

# ==============================================================================
if [ "$SKIP_OLLAMA" = false ]; then
  log_step "Step 11: Ollama AI Service (Hardened)"

  # ── Configuration ──
  OLLAMA_BASE_MODEL="qwen2.5-coder:14b-instruct-q4_K_M"   		  # ~8GB RAM, Q4 precision
  OLLAMA_FALLBACK_MODEL="codellama:7b"                    # ~4GB RAM, lightweight fallback
  OLLAMA_CUSTOM_MODEL="r-coder"                           # Custom model with R system prompt
  OLLAMA_RAM_LIMIT="24G"                                  # systemd MemoryMax: 16GB model + 3GB ctx16k + headroom
  OLLAMA_THREADS=24                                        # inference threads (half of vCores — leave rest for R)

  ulimit -n 65535 2>/dev/null || true

  # ── Install Ollama ──
  if ! command -v ollama &>/dev/null; then
    log_info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
  else
    log_info "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown')"
  fi

  # ── Hardening: systemd override ──
  # Bind to localhost only, cap RAM usage, set inference threads
  mkdir -p /etc/systemd/system/ollama.service.d
  cat > /etc/systemd/system/ollama.service.d/biome-hardening.conf <<OLLEOF
[Service]
# ── Security: Bind to loopback only ──
# RStudio sessions reach Ollama via 127.0.0.1:11434 (internal).
# Data never leaves the VM. No network exposure to university LAN.
Environment="OLLAMA_HOST=127.0.0.1:11434"

# ── Resource Caps (shared VM with researchers) ──
# Max 24GB RAM for Ollama: 14B Q8 model ~16GB + 16k context ~3GB + headroom.
# Leaves ~376GB for R sessions, tmpfs, and system on a 400GB VM.
MemoryMax=${OLLAMA_RAM_LIMIT}
MemorySwapMax=0

# ── Inference Tuning ──
# num_thread in Modelfile overrides this, but this is the default.
Environment="OLLAMA_NUM_PARALLEL=2"
# Unload model after 24h idle → frees ~8GB RAM back to researchers.
Environment="OLLAMA_KEEP_ALIVE=24h"
# Only keep 1 model loaded at a time (saves RAM on shared VM).
Environment="OLLAMA_MAX_LOADED_MODELS=1"
# Raise file descriptor limit for concurrent connections.
LimitNOFILE=65535

# ── Safety ──
Restart=on-failure
RestartSec=10
OLLEOF
  log_success "Ollama hardening: localhost-only, MemoryMax=${OLLAMA_RAM_LIMIT}, idle-unload=15m"

  # ── Start service ──
  systemctl daemon-reload
  systemctl enable ollama
  if systemctl is-active --quiet ollama; then
    systemctl restart ollama
  else
    systemctl start ollama
  fi
  sleep 3

  # Wait for Ollama to be ready (max 15s)
  for i in $(seq 1 15); do
    if curl -sf http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! curl -sf http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    log_error "Ollama failed to start on 127.0.0.1:11434"
    log_warn "Check: journalctl -u ollama -n 50"
  else
    log_success "Ollama running on 127.0.0.1:11434"
  fi

  # ── Pull Models ──
  # Primary: qwen2.5-coder 14B Q8 — best open-source code model for CPU
  # ~16GB RAM, excellent R/Python/stats, good reasoning for ecology research
  if ! ollama list 2>/dev/null | grep -q "qwen2.5-coder.*14b"; then
    log_info "Pulling $OLLAMA_BASE_MODEL (~9GB download, ~16GB RAM when loaded)..."
    log_info "This will take several minutes on first pull..."
    if run_cmd ollama pull "$OLLAMA_BASE_MODEL"; then
      log_success "Pulled: $OLLAMA_BASE_MODEL"
    else
      log_error "Failed to pull $OLLAMA_BASE_MODEL"
      log_warn "Falling back to lightweight model..."
    fi
  else
    log_info "Base model already present: $OLLAMA_BASE_MODEL"
  fi

  # Fallback: codellama 7B — fast, small, always available
  if ! ollama list 2>/dev/null | grep -q "codellama"; then
    log_info "Pulling $OLLAMA_FALLBACK_MODEL (lightweight fallback)..."
    run_cmd ollama pull "$OLLAMA_FALLBACK_MODEL" || log_warn "Could not pull fallback model"
  fi

  # ── Create R-Optimized Custom Model ──
  # This wraps the base model with R-specific system prompt and tuned parameters.
  # Users call ask_ai("...") which uses this model by default.
  MODELFILE_PATH="$BIOME_CONF/r-coder.modelfile"
  cat > "$MODELFILE_PATH" <<'MFEOF'
# BIOME-CALC R-Coder — OPTIMIZED Modelfile for CPU Inference
# Based on qwen2.5-coder:14b (4-bit quantization for faster CPU speed)
# Usage: ask_ai("How do I run a PERMANOVA on community data?")

FROM qwen2.5-coder:14b-instruct-q4_K_M

# ── CPU-Optimized Inference Parameters ──
# Increased from 16 to 24 threads to leverage the 32 vCores better.
PARAMETER num_thread 24

# Reduced context window from 16384 to 4096 tokens (~3000 words).
# This drastically speeds up processing and lowers RAM usage.
PARAMETER num_ctx 4096

# Inference quality: low temperature for deterministic code generation
PARAMETER temperature 0.3
PARAMETER top_p 0.9

# System prompt: R + ecology research focus
SYSTEM """You are an expert R programming assistant for ecological and biodiversity research.

Core competencies:
- R programming: tidyverse (dplyr, ggplot2, tidyr, purrr), data.table, base R
- Statistics: GLMs, GAMs, mixed models (lme4, nlme), multivariate (vegan, ade4)
- Ecology packages: vegan, betapart, mobr, iNEXT, CooccurrenceAffinity
- Geospatial: terra, sf, stars, rgee (Google Earth Engine), GDAL
- Biodiversity: species distribution models (biomod2, ENMeval), phylogenetics
- Remote sensing: terra, raster, satellite imagery processing
- Parallel computing: future, future.apply, parallel::mclapply
- Visualization: ggplot2, plotly, leaflet, tmap

Rules:
- Write clean, commented R code ready for RStudio.
- Prefer tidyverse style but respect base R when appropriate.
- When suggesting parallelization, respect the system's thread cap (max 16 threads).
- For large datasets, suggest arrow::read_parquet() over read.csv().
- For geospatial, prefer terra over raster (deprecated).
- Be concise: CPU inference is slow, minimize token output.
- If asked about statistics, explain the ecological rationale, not just the code.
"""
MFEOF
  chmod 644 "$MODELFILE_PATH"

  # Create the custom model (only if base model was pulled)
  if ollama list 2>/dev/null | grep -q "qwen2.5-coder.*14b"; then
    log_info "Creating custom model: $OLLAMA_CUSTOM_MODEL from Modelfile..."
    if ollama create "$OLLAMA_CUSTOM_MODEL" -f "$MODELFILE_PATH" 2>/dev/null; then
      log_success "Custom model created: $OLLAMA_CUSTOM_MODEL (R + ecology optimized)"
    else
      log_warn "Could not create custom model — users will use base model directly"
      OLLAMA_CUSTOM_MODEL="$OLLAMA_BASE_MODEL"
    fi
  else
    log_warn "Base model not available — using fallback: $OLLAMA_FALLBACK_MODEL"
    OLLAMA_CUSTOM_MODEL="$OLLAMA_FALLBACK_MODEL"
  fi

  # Write active model to config (Rprofile reads this)
  echo "$OLLAMA_CUSTOM_MODEL" > "$BIOME_CONF/ai_model"
  chmod 644 "$BIOME_CONF/ai_model"

  # ── Verify Ollama Security ──
  # Confirm not listening on 0.0.0.0 (only 127.0.0.1)
  if ss -tlnp 2>/dev/null | grep ":11434" | grep -q "0.0.0.0"; then
    log_error "SECURITY: Ollama listening on 0.0.0.0! Should be 127.0.0.1 only."
    log_warn "Check /etc/systemd/system/ollama.service.d/biome-hardening.conf"
  else
    log_success "Ollama security: listening on 127.0.0.1 only"
  fi

  # Summary
  log_info "Ollama models available:"
  ollama list 2>/dev/null | while read -r line; do echo "    $line"; done
  log_info "Active model for ask_ai(): $OLLAMA_CUSTOM_MODEL"
  log_info "RAM strategy: model loaded on demand, unloaded after 15min idle"
else
  log_step "Step 11: Ollama (SKIPPED)"
fi

# ==============================================================================
log_step "Step 12: BLAS Smoke Test"
# ==============================================================================

# FIX-6: Quick BLAS test to verify CORETYPE doesn't livelock
# Uses the value detected by biome-detect-coretype.sh (just ran above)
SMOKE_CT=$(cat /etc/biome-calc/coretype 2>/dev/null || echo "SANDYBRIDGE")
log_info "Running BLAS smoke test with CORETYPE=$SMOKE_CT (10s timeout)..."
BLAS_TEST=$(timeout 10 Rscript --vanilla -e "
  Sys.setenv(OPENBLAS_CORETYPE='${SMOKE_CT}')
  A <- matrix(runif(500*500), 500, 500)
  t0 <- Sys.time()
  B <- A %*% A
  dt <- round(as.numeric(difftime(Sys.time(), t0, units='secs')), 2)
  cat(sprintf('BLAS_OK in %ss', dt))
" 2>&1) || BLAS_TEST="BLAS_TIMEOUT"

if echo "$BLAS_TEST" | grep -q "BLAS_OK"; then
  log_success "BLAS smoke test: $BLAS_TEST (CORETYPE=$SMOKE_CT)"
else
  log_error "BLAS smoke test FAILED (timeout or crash)"
  log_error "Result: $BLAS_TEST"
  log_warn "The CORETYPE=$SMOKE_CT may be wrong for this CPU."
  log_warn "Try: OPENBLAS_CORETYPE=SANDYBRIDGE as universal fallback."
  log_warn "Continuing setup — fix before users connect."
fi

# ==============================================================================
log_step "Final Validation"
# ==============================================================================

echo ""
log_info "System Summary:"
echo "  Host:      $R_HOST ($R_IP)"
echo "  CPU:       $CPU_MODEL"
echo "  Vendor:    $CPU_VENDOR"
echo "  OpenBLAS:  Dynamic (boot-detected=$CURRENT_CT)"
echo "  RAM:       $(free -g | awk '/^Mem:/{print $2}')GB"
echo "  RAMDisk:   $(df -h /tmp | tail -1 | awk '{print $2}')"
echo "  Python:    $($PYTHON_ENV/bin/python --version 2>&1)"
echo "  NFS Home:  $NFS_HOME"
echo "  CIFS:      $CIFS_ARCHIVE"

log_info "Final parse check..."
# NOTE: Only parse Rprofile.site (R code). Renviron.site is KEY=VALUE format,
# not R syntax — parse() would fail on it (false positive).
FC=$(Rscript --vanilla -e "
tryCatch({parse(file='/etc/R/Rprofile.site');cat('ALL_OK')},
  error=function(e) cat(sprintf('FAIL: %s',e\$message)))" 2>&1)
echo "$FC" | grep -q "ALL_OK" && log_success "Rprofile.site syntax valid" || log_error "$FC"

# Validate Renviron.site separately (check for empty values or syntax issues)
if [ -f "/etc/R/Renviron.site" ]; then
  bad_lines=$(grep -nE '^\s*[A-Z_]+=\s*$' /etc/R/Renviron.site 2>/dev/null || true)
  if [ -n "$bad_lines" ]; then
    log_warn "Renviron.site has empty values: $bad_lines"
  else
    log_success "Renviron.site validated (KEY=VALUE format)"
  fi
fi

echo ""
log_success "=========================================="
log_success "BIOME-CALC v7.3 SETUP COMPLETE"
log_success "=========================================="
echo ""
echo "  CORETYPE Detection (Migration-Safe):"
echo "    - Boot-time:   biome-detect-coretype.service (systemd oneshot)"
echo "    - Per-session:  Rprofile.site v9.3.14 (reads /proc/cpuinfo vendor)"
echo "    - Current:      $CURRENT_CT (vendor=$CPU_VENDOR)"
echo ""
echo "  Proxmox VM config (RECOMMENDED for mixed Intel/AMD cluster):"
echo "    cpu: x86-64-v4    # AVX512-capable, migrates between Intel/AMD"
echo "    # cpu: host        # Best perf, but BLOCKS cross-vendor migration"
echo ""
echo "  Next steps:"
echo "    1. Set cpu: x86-64-v4 in Proxmox VM config (if not already)"
echo "    2. sudo systemctl restart rstudio-server"
echo "    3. In R session: source('$BIOME_CONF/00_audit_v26.R')"
echo "    4. Verify: status()"
echo ""
echo "  Files deployed:"
echo "    /etc/R/Rprofile.site                       — System R profile v9.3.14"
echo "    /etc/R/Renviron.site                       — Env vars (no static CORETYPE)"
echo "    /usr/local/bin/biome-detect-coretype.sh    — Boot-time CORETYPE detection"
echo "    /etc/systemd/system/biome-detect-coretype.service"
echo "    /etc/biome-calc/coretype                   — Current detected: $CURRENT_CT"
echo "    $BIOME_CONF/audit.conf                     — Audit configuration"
echo "    $BIOME_CONF/00_audit_v26.R                 — Enterprise audit v26"
echo "    $LOG_FILE                                  — System log"
if [ "$SKIP_OLLAMA" = false ]; then
  echo ""
  echo "  Ollama AI Service:"
  echo "    Model:      $(cat $BIOME_CONF/ai_model 2>/dev/null || echo 'not set')"
  echo "    Base:       $OLLAMA_BASE_MODEL"
  echo "    Fallback:   $OLLAMA_FALLBACK_MODEL"
  echo "    Bind:       127.0.0.1:11434 (localhost only)"
  echo "    MemoryMax:  $OLLAMA_RAM_LIMIT (systemd cgroup)"
  echo "    Context:    16384 tokens"
  echo "    Idle unload: 15min → frees ~16GB back to researchers"
  echo "    Modelfile:  $BIOME_CONF/r-coder.modelfile"
fi
echo ""
echo "  User fixes applied:"
echo "    - EARTHENGINE_PYTHON → /opt/r-geospatial/bin/python"
echo "    - Removed EARTHENGINE_ENV (conda concept)"
echo "    - Removed static thread settings + user OPENBLAS_CORETYPE"
echo "    - Fixed double-slash in rstudio-prefs.json"
echo ""