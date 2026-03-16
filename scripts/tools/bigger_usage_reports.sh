#!/bin/bash
# ==============================================================================
# bigger_usage_reports.sh - Safe, high-performance disk usage diagnostics.
# Optimized for BIOME-CALC (NFSv4/Samba/CIFS friendly)
# ==============================================================================

set -euo pipefail

# --- Configuration ---
THRESHOLD="500M"       # Only report items larger than this
MAX_DEPTH_REMOTE=2     # Limit depth on network shares to avoid metadata storm
MAX_DEPTH_LOCAL=4      # More depth for local filesystems
TOP_N=10               # Show top 10 offenders

log_info() { echo -e "\e[32m[INFO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

# --- Root Check ---
[[ $EUID -ne 0 ]] && { log_warn "Running without sudo - some paths will be skipped."; }

# --- Identification of Mounts ---
# We prioritize local filesystems to avoid network overhead unless requested.
LOCALS=$(df -h --local | awk 'NR>1 {print $6}' | grep -v "^/boot" | tr '\n' ' ')

echo "============================================================"
echo "  BIOME-CALC: Optimized Storage Usage Report"
echo "  Threshold: >${THRESHOLD} | Priority: IDLE (ionice -c3)"
echo "============================================================"

# --- 1. Top Directories (Local Only) ---
echo -e "\n--- Top ${TOP_N} Largest Local Directories ---"
# shellcheck disable=SC2086
ionice -c3 du -hxd "${MAX_DEPTH_LOCAL}" $LOCALS 2>/dev/null | grep -E "^[0-9.]+[MG]" | sort -rh | head -n ${TOP_N}

# --- 2. Top Large Files (Scanning Local /home, /var, /opt) ---
echo -e "\n--- Top ${TOP_N} Largest Local Files (> ${THRESHOLD}) ---"
# Using find with -xdev to stay on one filesystem and -printf for speed
ionice -c3 find /home /var /opt -xdev -type f -size +${THRESHOLD} -printf "%s %p\n" 2>/dev/null \
    | sort -rn | head -n ${TOP_N} \
    | while read -r sz path; do
        printf "%-10s %s\n" "$(numfmt --to=iec-i --suffix=B "$sz")" "$path"
    done

# --- 3. Network Shares (NFS/CIFS) - Extra Safe Mode ---
echo -e "\n--- Network Share Analysis (NFS/SMB/CIFS) ---"
grep -E "nfs|cifs|smb" /proc/mounts | awk '{print $2}' | while read -r mnt; do
    log_info "Safe-scanning mount: ${mnt} (depth=${MAX_DEPTH_REMOTE})..."
    ionice -c3 du -h --max-depth=${MAX_DEPTH_REMOTE} --threshold=${THRESHOLD} "${mnt}" 2>/dev/null | sort -rh | head -n 5 || echo "  (Empty or access denied)"
done

echo -e "\nDone."
