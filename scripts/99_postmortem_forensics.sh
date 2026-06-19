#!/bin/bash
# 99_postmortem_forensics.sh — BIOME-CALC Post-Mortem Crash Forensics
# =============================================================================
# Automated data collection and crash analysis for R session failures.
# Designed for sysadmins supporting non-technical botanical researchers
# who report: "it crashed", "it doesn't work", "on the old server it ran".
#
# This script collects ALL forensic evidence, classifies the crash type,
# checks guard coverage, identifies unguarded edge cases, and produces
# a structured diagnosis with actionable fix recommendations.
#
# Usage:
#   sudo bash 99_postmortem_forensics.sh --user <username>
#   sudo bash 99_postmortem_forensics.sh --user <username> --hours 4
#   sudo bash 99_postmortem_forensics.sh --user <username> --output /tmp/report.txt
#   sudo bash 99_postmortem_forensics.sh --all-recent
#
# Design: Pessimistic PRD (every read can fail, every path can be missing)
#
# Version: 2.1.0
#   - v2.1.0 fixes:
#     * BUG: duplicate section [10] (SSL collided with DIAGNOSIS) → renumbered
#       SSL=10, Nginx=11, Telemetry=12, RStudio=13, Auth=14, Diagnosis=15
#     * BUG: duplicate swappiness report lines in collect_system_state
#     * BUG: generate_diagnosis() redefined patched counters via legacy code
#       → removed legacy has_sigsegv/has_sigill/has_orphans overwrites
#     * BUG: version string mismatch (header said 1.0.0, banner said 2.0.0)
#     * RESTORED: GUARDED_FUNCTIONS + UNGUARDED_PATTERNS arrays (were in the
#       original v1.0.0, dropped in the first v2.1.0 rewrite, now re-added
#       with v11.0-aware content and wired into generate_diagnosis via new
#       print_unguarded_patterns_table() helper so the "unguarded patterns
#       table" reference in the diagnosis text is no longer orphan.
#   - v2.1.0 alignment with Rprofile v11.0 + audit v28:
#     * User forensics: check /Rtmp/biome_<user>/ v11.0 subdirs and cluster_logs
#     * Guard status: check biome_future_plan + biome_worker_diagnostics in tools:biome_calc
#     * NIMBLE routing: v11.0 expects /Rtmp, NOT NFS $HOME (invert old check)
#     * NEW section [15]: top-level return() bug detection (v10.0 regression)
#     * BIOME_USER_TMP env + .biome_env$USER_TMP_ROOT checks
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"

# =============================================================================
# ROBUST COUNT HELPERS
# =============================================================================
count_lines() {
    local cmd="$1"
    local out
    out=$(safe_cmd "$cmd" 5 2>/dev/null || true)
    if [[ -z "$out" ]]; then
        echo 0
    else
        printf '%s\n' "$out" | wc -l | tr -d " \n\r"
    fi
}

safe_number() {
    local val="$1"
    [[ "$val" =~ ^[0-9]+$ ]] && echo "$val" || echo 0
}

# =============================================================================
# EARLY HELP (before sourcing common_utils, which requires root)
# =============================================================================
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        cat <<'HELPEND'
Usage: 99_postmortem_forensics.sh [OPTIONS]

Automated post-mortem crash forensics for BIOME-CALC R sessions.
Collects all evidence, classifies crash type, checks guard coverage,
and produces actionable diagnosis for sysadmin DevOps workflow.

Options:
  --user <username>   Target user to investigate (required unless --all-recent)
  --hours <N>         Look back N hours for crash events (default: 4)
  --output <file>     Write report to file (also prints to stdout)
  --all-recent        Scan all recent crashes (no specific user)
  --quick             Skip BLAS smoke test and guard verification (faster)
  --incident          Auto-write incident log entry
  -h, --help          Display this help

Examples:
  sudo $0 --user mario.rossi --incident
  sudo $0 --user anna.verdi --hours 8 --output /tmp/crash_report.txt --quick
  sudo $0 --all-recent --hours 2
HELPEND
        exit 0
    fi
done

# Source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
    echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
    exit 2
fi
# shellcheck source=../lib/common_utils.sh disable=SC1091
source "$UTILS_SCRIPT_PATH"

# =============================================================================
# PESSIMISTIC ENGINEERING CONTROLS
# =============================================================================

GLOBAL_TEMP_DIR=""
REPORT_FILE=""

cleanup() {
    local rc=$?
    if [[ -n "${GLOBAL_TEMP_DIR:-}" && -d "$GLOBAL_TEMP_DIR" ]]; then
        rm -rf "$GLOBAL_TEMP_DIR"
    fi
    exit $rc
}
trap cleanup EXIT ERR INT TERM

# =============================================================================
# CONSTANTS
# =============================================================================

BIOME_LOG="/var/log/biome-log/r_biome_system.log"
BIOME_CONF="/etc/biome-calc"
RPROFILE_PATH="/etc/R/Rprofile.site"
RENVIRON_PATH="/etc/R/Renviron.site"
RTMP_PATH="/Rtmp"
NFS_HOME="/nfs/home"
INCIDENT_LOG="/var/log/biome-log/incident_log.txt"

# v11.0 expected per-user subdirs under /Rtmp/biome_<user>/
V11_USER_SUBDIRS=(nimble_compile tmb_compile stan_compile rcpp_cache cluster_logs keras_cache plot_cache)

# Known guarded functions (must match Rprofile_site.R.template v11.0)
# — Used by generate_diagnosis to tell the sysadmin which primitives are
#   actively wrapped. If a user OOMs on one of these, the guard fired and
#   they ignored it; if they OOM on something NOT in this list, it's an
#   unguarded pattern and the guard needs to be extended.
GUARDED_FUNCTIONS=(
    # Base memory sentinels (v9.6+)
    "solve" "dist" "outer" "expand.grid" "read.csv"
    # Geosphere (v9.6)
    "distm"
    # Parallel safeguards (v11.0 [N4][N5])
    "parallel::makeCluster" "doSNOW::registerDoSNOW" "doParallel::registerDoParallel"
    # Compile routing hooks (v11.0 [N1][N2][N7])
    "nimble::compileNimble" "TMB::compile" "rstan" "cmdstanr"
)

# Known dangerous unguarded patterns (common in botanical R scripts —
# these are NOT intercepted by any wrapper; they require script rewrite
# or a new guard if they show up in repeated OOMs).
UNGUARDED_PATTERNS=(
    "as.matrix(dist(...))          # doubles RAM footprint"
    "readRDS(huge_file)            # no size check before load"
    "do.call(rbind, list_of_dfs)   # O(n^2) mem for many dfs"
    "Rcpp::sourceCpp               # compile + JIT allocations"
    "raster::stack(many_files)     # loads all rasters to RAM"
    "dplyr::collect()              # pulls full DB table in-memory"
    "geom_point(aes(...))          # >10k points = huge SVG/PNG"
    "vegan::vegdist -> hclust      # N^2 dist + full dendrogram"
    "compileNimble(...)            # C++ compile scratch (routed to /Rtmp in v11.0)"
    "merge(x, y, by=...)           # inner join can blow up via cartesian"
    "combn(n, k)                   # factorial growth for k>4, n>20"
)

# Helper to print the patterns table (called from diagnosis when relevant)
print_unguarded_patterns_table() {
    report "  UNGUARDED PATTERNS TABLE (check if user's script contains any):"
    local pat
    for pat in "${UNGUARDED_PATTERNS[@]}"; do
        report "    • $pat"
    done
    report ""
    report "  GUARDED (wrapped by Rprofile v11.0 — these DO warn/block):"
    report "    ${GUARDED_FUNCTIONS[*]}"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

safe_read() {
    local filepath="$1"
    local max_lines="${2:-50}"
    if [[ -f "$filepath" && -r "$filepath" ]]; then
        head -n "$max_lines" "$filepath" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

safe_cmd() {
    local cmd="$1"
    local timeout_sec="${2:-10}"
    timeout "$timeout_sec" bash -c "$cmd" 2>/dev/null || echo ""
}

section() {
    local title="$1"
    printf "\n%s\n" "═══════════════════════════════════════════════════════════════"
    printf "  %s\n" "$title"
    printf "%s\n\n" "═══════════════════════════════════════════════════════════════"
}

subsection() {
    printf "\n  ── %s ──\n" "$1"
}

severity() {
    local level="$1"
    case "$level" in
        CRITICAL) printf "🔴 CRITICAL" ;;
        HIGH)     printf "🟠 HIGH" ;;
        MEDIUM)   printf "🟡 MEDIUM" ;;
        LOW)      printf "🟢 LOW" ;;
        OK)       printf "✅ OK" ;;
        UNKNOWN)  printf "❓ UNKNOWN" ;;
    esac
}

report() {
    if [[ -n "${REPORT_FILE:-}" ]]; then
        printf "%s\n" "$*" | tee -a "$REPORT_FILE"
    else
        printf "%s\n" "$*"
    fi
}

# =============================================================================
# DATA COLLECTION MODULES
# =============================================================================

collect_system_state() {
    section "1. SYSTEM STATE SNAPSHOT"

    subsection "Memory"
    local mem_info
    mem_info=$(safe_cmd "free -h" 5)
    report "$mem_info"

    local mem_avail_kb mem_total_kb swap_free_kb swap_total_kb
    mem_avail_kb=$(safe_cmd "awk '/MemAvailable/{print \$2}' /proc/meminfo" 3)
    mem_total_kb=$(safe_cmd "awk '/MemTotal/{print \$2}' /proc/meminfo" 3)
    swap_free_kb=$(safe_cmd "awk '/SwapFree/{print \$2}' /proc/meminfo" 3)
    swap_total_kb=$(safe_cmd "awk '/SwapTotal/{print \$2}' /proc/meminfo" 3)

    if [[ -n "$mem_avail_kb" && -n "$mem_total_kb" ]]; then
        local mem_pct=$(( (mem_total_kb - mem_avail_kb) * 100 / mem_total_kb ))
        report "  RAM Usage: ${mem_pct}% (Available: $((mem_avail_kb / 1024)) MB / Total: $((mem_total_kb / 1024)) MB)"
        if [[ $mem_pct -gt 90 ]]; then
            report "  $(severity CRITICAL): RAM usage above 90% — OOM risk is HIGH"
        elif [[ $mem_pct -gt 75 ]]; then
            report "  $(severity HIGH): RAM usage above 75% — approaching danger zone"
        else
            report "  $(severity OK): RAM usage normal"
        fi
    fi

    if [[ -n "$swap_total_kb" && "$swap_total_kb" -gt 0 ]]; then
        local swap_used_kb=$((swap_total_kb - swap_free_kb))
        local swap_pct=$((swap_used_kb * 100 / swap_total_kb))
        report "  Swap Usage: ${swap_pct}% (Used: $((swap_used_kb / 1024)) MB / Total: $((swap_total_kb / 1024)) MB)"
        if [[ $swap_pct -gt 50 ]]; then
            report "  $(severity HIGH): Swap heavily used — system under memory pressure"
        fi
    fi

    # BUG FIX v2.1.0: previously printed swappiness lines twice.
    subsection "Kernel Swappiness"
    local swappiness sysctl_target
    swappiness=$(safe_cmd "cat /proc/sys/vm/swappiness" 3)
    sysctl_target=$(sysctl -n vm.swappiness 2>/dev/null || echo 30)
    report "  vm.swappiness (runtime): ${swappiness:-unknown}"
    report "  vm.swappiness (sysctl target): ${sysctl_target}"
    if [[ -n "$swappiness" && "$swappiness" -gt 30 ]]; then
        report "  $(severity MEDIUM): Swappiness too high — should be ≤10 for RStudio workloads"
    fi

    subsection "/Rtmp Local Disk"
    if mountpoint -q "$RTMP_PATH" 2>/dev/null; then
        local rtmp_info
        rtmp_info=$(safe_cmd "df -h $RTMP_PATH" 5)
        report "$rtmp_info"
        local rtmp_pct
        rtmp_pct=$(safe_cmd "df -P $RTMP_PATH | awk 'NR==2{gsub(/%/,\"\"); print \$5}'" 3)
        if [[ -n "$rtmp_pct" && "$rtmp_pct" -gt 80 ]]; then
            report "  $(severity MEDIUM): /Rtmp at ${rtmp_pct}% — consider cleanup"
        else
            report "  $(severity OK): /Rtmp disk healthy"
        fi
        # v2.1.0: verify it's NOT tmpfs (v11.0 requirement)
        local is_tmpfs
        is_tmpfs=$(safe_cmd "df -T $RTMP_PATH | awk 'NR==2 {print \$2}'" 3)
        if [[ "$is_tmpfs" == "tmpfs" ]]; then
            report "  $(severity CRITICAL): /Rtmp is tmpfs — v11.0 requires ext4/xfs local disk!"
        fi
    else
        report "  $(severity HIGH): /Rtmp is NOT mounted as a separate filesystem!"
        report "  Check: Is the local virtio disk attached? Is /Rtmp in fstab?"
        local is_tmpfs
        is_tmpfs=$(safe_cmd "mount | grep 'on /Rtmp' | grep tmpfs" 3)
        if [[ -n "$is_tmpfs" ]]; then
            report "  $(severity CRITICAL): /Rtmp is mounted as TMPFS — this eats RAM!"
        fi
    fi

    subsection "CPU & Load"
    local load_avg
    load_avg=$(safe_cmd "uptime" 3)
    report "  $load_avg"
    local ncpus
    ncpus=$(safe_cmd "nproc" 3)
    report "  CPU Cores: ${ncpus:-unknown}"

    subsection "Top R Processes by Memory"
    local r_procs
    r_procs=$(safe_cmd "ps -eo pid,user,%mem,rss:10,etime,args --sort=-%mem 2>/dev/null | head -1; ps -eo pid,user,%mem,rss:10,etime,args --sort=-%mem 2>/dev/null | grep -E 'rsession|Rscript|R --' | head -10" 5)
    if [[ -n "$r_procs" ]]; then
        report "$r_procs"
    else
        report "  No active R processes found."
    fi

    subsection "Active RStudio Sessions"
    local active_sessions
    active_sessions=$(safe_cmd "rstudio-server active-sessions 2>/dev/null" 5)
    if [[ -n "$active_sessions" ]]; then
        report "$active_sessions"
    else
        report "  Could not query active sessions (rstudio-server may not be running)"
    fi
}

collect_oom_events() {
    local hours="${1:-4}"

    section "2. KERNEL OOM EVENTS (last ${hours}h)"

    local oom_events
    oom_events=$(safe_cmd "dmesg -T 2>/dev/null | grep -iE 'oom|killed process|out of memory' | tail -20" 10)

    if [[ -n "$oom_events" ]]; then
        report "  $(severity CRITICAL): OOM events found in kernel log!"
        report ""
        report "$oom_events"
        report ""
        local killed_procs
        killed_procs=$(echo "$oom_events" | grep -oP 'Killed process \d+ \([^)]+\)' || true)
        if [[ -n "$killed_procs" ]]; then
            report "  Killed processes:"
            report "$killed_procs"
        fi
        local rss_info
        rss_info=$(echo "$oom_events" | grep -oP 'rss:\d+' || true)
        if [[ -n "$rss_info" ]]; then
            report ""
            report "  Memory at kill time:"
            while IFS= read -r line; do
                local rss_pages
                rss_pages=$(echo "$line" | grep -oP '\d+')
                if [[ -n "$rss_pages" ]]; then
                    local rss_gb=$(( rss_pages * 4 / 1024 / 1024 ))
                    report "    $line → ~${rss_gb} GB"
                fi
            done <<< "$rss_info"
        fi
    else
        report "  $(severity OK): No OOM events found in kernel log."
    fi
}

collect_crash_signals() {
    local hours="${1:-4}"

    section "3. RSESSION CRASH SIGNALS (last ${hours}h)"

    local journal_crashes
    journal_crashes=$(safe_cmd "journalctl -u rstudio-server --since '${hours} hours ago' --no-pager 2>/dev/null | grep -iE 'segv|sigill|sigsegv|sigabrt|signal|crash|abort|killed|exit code|fatal'" 10)

    if [[ -n "$journal_crashes" ]]; then
        report "  $(severity CRITICAL): RStudio session crash signals detected!"
        report ""
        report "$journal_crashes"
        report ""
        if echo "$journal_crashes" | grep -qi "SIGSEGV\|signal 11\|segv"; then
            report "  DIAGNOSIS: SIGSEGV (Segmentation Fault)"
            report "  LIKELY CAUSE: OpenBLAS-pthread thread collision during solve()/crossprod()"
            report "  FIX: Verify openblas-serial is installed:"
            report "    dpkg -l | grep openblas"
            report "    update-alternatives --display libblas.so.3-x86_64-linux-gnu"
        fi
        if echo "$journal_crashes" | grep -qi "SIGILL\|signal 4"; then
            report "  DIAGNOSIS: SIGILL (Illegal Instruction)"
            report "  LIKELY CAUSE: OPENBLAS_CORETYPE mismatch after VM migration"
            report "  FIX: sudo bash scripts/50_setup_nodes.sh → option 2 (BLAS/CORETYPE detection)"
        fi
    else
        report "  $(severity OK): No crash signals found in journalctl."
    fi
}

collect_user_forensics() {
    local target_user="$1"
    local hours="${2:-4}"

    section "4. USER-SPECIFIC FORENSICS: ${target_user}"

    local user_info
    user_info=$(safe_cmd "getent passwd '$target_user'" 5)
    if [[ -z "$user_info" ]]; then
        report "  $(severity HIGH): User '$target_user' not found via getent!"
        report "  Check: AD/SSSD connectivity, user account status"
        return
    fi

    local user_home user_uid
    user_home=$(echo "$user_info" | cut -d: -f6)
    user_uid=$(echo "$user_info" | cut -d: -f3)
    report "  User:     $target_user"
    report "  UID:      $user_uid"
    report "  Home:     $user_home"

    subsection "User Session in BIOME Syslog"
    if [[ -f "$BIOME_LOG" ]]; then
        local user_logs
        user_logs=$(safe_cmd "grep '$target_user' '$BIOME_LOG' | tail -30" 10)
        if [[ -n "$user_logs" ]]; then
            report "$user_logs"
            if echo "$user_logs" | grep -q "Profile.*OK"; then
                report ""
                report "  $(severity OK): Rprofile loaded successfully for this user"
            else
                report ""
                report "  $(severity HIGH): No successful Rprofile load found for this user!"
                report "  Guards may NOT be active. Check .Rprofile for interference."
            fi
            local guard_warns
            guard_warns=$(echo "$user_logs" | grep -iE "solve|dist|outer|expand|distm|WARN" || true)
            if [[ -n "$guard_warns" ]]; then
                report ""
                report "  Guard activity detected:"
                report "$guard_warns"
            fi
        else
            report "  No entries found for user '$target_user' in BIOME syslog."
            report "  $(severity MEDIUM): Either user never logged in, or syslog is missing."
        fi
    else
        report "  $(severity HIGH): BIOME syslog not found at $BIOME_LOG"
    fi

    subsection "OOM Crash Marker"
    local crash_file="${user_home}/ULTIMO_CRASH_RAM.txt"
    if [[ -f "$crash_file" ]]; then
        report "  $(severity CRITICAL): OOM crash marker found!"
        report "  File: $crash_file"
        report "  Content:"
        safe_read "$crash_file" 5 | while IFS= read -r line; do report "    $line"; done
    else
        report "  $(severity OK): No OOM crash marker file."
    fi

    subsection "User Active Processes"
    local user_procs
    user_procs=$(safe_cmd "ps -u '$target_user' -o pid,rss:10,%mem,etime,args --sort=-%mem 2>/dev/null | head -15" 5)
    if [[ -n "$user_procs" ]]; then
        report "$user_procs"
    else
        report "  No active processes for $target_user (session may have been killed)"
    fi

    subsection "User .Rprofile Interference Check"
    local user_rprofile="${user_home}/.Rprofile"
    if [[ -f "$user_rprofile" ]]; then
        report "  User has a custom .Rprofile:"
        report "  $(safe_read "$user_rprofile" 20)"
        local interference=false
        if grep -qE 'options\(error.*=.*recover\)' "$user_rprofile" 2>/dev/null; then
            report "  $(severity MEDIUM): User has options(error=recover) — may hang sessions"
            interference=true
        fi
        if grep -qE 'source\(' "$user_rprofile" 2>/dev/null; then
            report "  $(severity MEDIUM): User sources external scripts — may error before system profile loads"
            interference=true
        fi
        if [[ "$interference" == false ]]; then
            report "  $(severity OK): No obvious interference patterns found."
        fi
    else
        report "  $(severity OK): No custom .Rprofile (system Rprofile.site is authoritative)"
    fi

    subsection "User .Renviron Check"
    local user_renviron="${user_home}/.Renviron"
    if [[ -f "$user_renviron" ]]; then
        local thread_overrides
        thread_overrides=$(grep -E '^(OMP_NUM_THREADS|OPENBLAS_NUM_THREADS|MKL_NUM_THREADS|MC_CORES)=' "$user_renviron" 2>/dev/null || true)
        if [[ -n "$thread_overrides" ]]; then
            report "  $(severity HIGH): User has hardcoded thread settings in .Renviron!"
            report "  These OVERRIDE dynamic allocation and can cause instability:"
            report "  $thread_overrides"
            report "  FIX: Remove these lines"
        else
            report "  $(severity OK): No hardcoded thread settings in .Renviron"
        fi
    fi

    subsection "User RStudio State & Crash Loops"
    local rstudio_active="${user_home}/.local/share/rstudio/sessions/active"
    if [[ -d "$rstudio_active" ]]; then
        local active_sessions
        active_sessions=$(safe_cmd "ls -1 '$rstudio_active' 2>/dev/null" 5)
        if [[ -n "$active_sessions" ]]; then
            report "  Active/Suspended sessions found:"
            while IFS= read -r sess; do
                local sess_dir="${rstudio_active}/${sess}"
                local sess_size
                sess_size=$(safe_cmd "du -sh '$sess_dir' 2>/dev/null" 5)
                report "    $sess_size"
                local large_files
                large_files=$(safe_cmd "find '$sess_dir' -type f -size +50M -exec ls -lh {} + 2>/dev/null" 5)
                if [[ -n "$large_files" ]]; then
                    report "    $(severity HIGH): Large workspace/session payloads detected!"
                    report "    $large_files"
                    report "    These cause crash loops (RStudio OOMs while trying to restore)."
                    report "    FIX: run 'mv ${user_home}/.local/share/rstudio ${user_home}/.local/share/rstudio-backup'"
                fi
            done <<< "$active_sessions"
        else
            report "  No active/suspended sessions found."
        fi
    else
        report "  $(severity OK): No RStudio state directory found for user."
    fi

    local rstudio_logs="${user_home}/.local/share/rstudio/log"
    if [[ -d "$rstudio_logs" ]]; then
        local recent_log
        recent_log=$(safe_cmd "find '$rstudio_logs' -type f -mtime -1 -exec tail -n 5 {} + 2>/dev/null" 5)
        if [[ -n "$recent_log" ]]; then
            report ""
            report "  Recent user RStudio logs (last 24h):"
            report "$recent_log"
        fi
    fi

    # v2.1.0: v11.0-aware /Rtmp layout inspection
    subsection "User /Rtmp Usage (v11.0 layout)"
    local user_tmp="${RTMP_PATH}/biome_${target_user}"
    if [[ -d "$user_tmp" ]]; then
        local tmp_size
        tmp_size=$(safe_cmd "du -sh '$user_tmp'" 5)
        report "  $tmp_size"
        local tmp_files
        tmp_files=$(safe_cmd "find '$user_tmp' -type f | wc -l" 5)
        report "  Files: ${tmp_files:-unknown}"
        # Check v11.0 subdirs
        local missing=()
        for sub in "${V11_USER_SUBDIRS[@]}"; do
            [[ -d "$user_tmp/$sub" ]] || missing+=("$sub")
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            report "  $(severity MEDIUM): v11.0 subdirs missing: ${missing[*]}"
            report "  → User may have a stale pre-v11.0 layout. Clean up:"
            report "    sudo rm -rf '$user_tmp' ; triggers fresh init on next rsession"
        else
            report "  $(severity OK): All 7 v11.0 subdirs present"
        fi
        # Legacy NFS NIMBLE path (v10 fallback): should NOT be populated in v11.0
        local legacy_nimble="${user_home}/.nimble_compile"
        if [[ -d "$legacy_nimble" ]]; then
            local legacy_size
            legacy_size=$(safe_cmd "du -sh '$legacy_nimble' 2>/dev/null | awk '{print \$1}'" 5)
            report "  $(severity MEDIUM): Legacy v10 NIMBLE dir on NFS: $legacy_nimble ($legacy_size)"
            report "  → v11.0 routes to /Rtmp; this dir is orphan. Safe to remove."
        fi
        local largest
        largest=$(safe_cmd "find '$user_tmp' -type f -exec ls -lhS {} + 2>/dev/null | head -5" 5)
        if [[ -n "$largest" ]]; then
            report "  Largest files:"
            report "$largest"
        fi
    else
        report "  No /Rtmp data for this user (no temp directory exists — never triggered Rprofile?)"
    fi

    # v2.1.0: cluster_logs — the core of Martina-class diagnostics
    subsection "User cluster_logs/ (PSOCK worker post-mortem)"
    local cl_dir="${user_tmp}/cluster_logs"
    if [[ -d "$cl_dir" ]]; then
        local log_count
        log_count=$(safe_cmd "find '$cl_dir' -name 'psock_*.log' | wc -l" 5)
        log_count="${log_count//[^0-9]/}"
        report "  Total worker logs: ${log_count:-0}"
        # Recent logs with errors
        local error_logs
        error_logs=$(safe_cmd "find '$cl_dir' -name 'psock_*.log' -mmin -$((hours * 60)) -exec grep -l -iE 'error|SIGSEGV|SIGKILL|unserialize|fatal' {} + 2>/dev/null" 10)
        if [[ -n "$error_logs" ]]; then
            report "  $(severity HIGH): Recent worker logs with errors (last ${hours}h):"
            while IFS= read -r log; do
                report "    $(basename "$log"):"
                safe_cmd "grep -iE 'error|SIGSEGV|unserialize|fatal' '$log' | head -3" 5 | while IFS= read -r l; do
                    [[ -n "$l" ]] && report "      $l"
                done
            done <<< "$error_logs"
        else
            report "  $(severity OK): No recent worker errors"
        fi
    else
        report "  $(severity LOW): No cluster_logs/ dir (never used PSOCK workers, or pre-v11.0 layout)"
    fi
}

collect_blas_status() {
    section "5. BLAS / OPENBLAS STATUS"

    subsection "BLAS Alternative"
    local blas_alt
    blas_alt=$(safe_cmd "update-alternatives --display libblas.so.3-x86_64-linux-gnu 2>/dev/null | head -5" 5)
    if [[ -n "$blas_alt" ]]; then
        report "$blas_alt"
        if echo "$blas_alt" | grep -q "pthread"; then
            report "  $(severity CRITICAL): openblas-PTHREAD is active! This WILL cause SIGSEGV!"
            report "  FIX: sudo apt-get remove libopenblas0-pthread && sudo apt-get install libopenblas-serial-dev"
        elif echo "$blas_alt" | grep -q "serial"; then
            report "  $(severity OK): openblas-serial is active (safe)"
        fi
    fi

    subsection "Installed OpenBLAS Packages"
    local openblas_pkgs
    openblas_pkgs=$(safe_cmd "dpkg -l 2>/dev/null | grep openblas" 5)
    report "${openblas_pkgs:-  No OpenBLAS packages found}"
    if echo "${openblas_pkgs:-}" | grep -q "pthread"; then
        report "  $(severity HIGH): libopenblas0-pthread is still installed (should be removed)"
    fi

    subsection "CORETYPE Detection"
    local coretype
    coretype=$(safe_read "${BIOME_CONF}/coretype" 1)
    local cpu_model
    cpu_model=$(safe_cmd "grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //'" 3)
    report "  Detected CORETYPE: ${coretype:-not detected}"
    report "  CPU Model: ${cpu_model:-unknown}"

    subsection "BLAS Smoke Test"
    local smoke_result
    smoke_result=$(safe_cmd "timeout 10 Rscript --vanilla -e \"
        A <- matrix(runif(500*500), 500, 500)
        t0 <- Sys.time()
        B <- A %*% A
        dt <- round(as.numeric(difftime(Sys.time(), t0, units='secs')), 3)
        cat(sprintf('BLAS_OK in %ss', dt))
    \" 2>&1" 15)

    if echo "$smoke_result" | grep -q "BLAS_OK"; then
        report "  $(severity OK): $smoke_result"
    elif echo "$smoke_result" | grep -qi "segv\|segfault\|abort"; then
        report "  $(severity CRITICAL): BLAS smoke test CRASHED with signal!"
        report "  Output: $smoke_result"
    else
        report "  $(severity HIGH): BLAS smoke test failed or timed out"
        report "  Output: ${smoke_result:-<no output>}"
    fi
}

collect_guard_status() {
    section "6. MEMORY GUARD COVERAGE + v11.0 TOOLS"

    subsection "Guard Installation Check"
    local guard_check
    guard_check=$(safe_cmd "timeout 20 Rscript --vanilla -e \"
        tryCatch({
            source('$RPROFILE_PATH')
            if (exists('.biome_env') && is.function(.biome_env\\\$deferred_pkg_init)) try(.biome_env\\\$deferred_pkg_init(), silent=TRUE)
            cat('solve_guard:', isTRUE(attr(base::solve, 'biome_guard')), '\n')
            cat('dist_guard:', isTRUE(attr(stats::dist, 'biome_guard')), '\n')
            cat('outer_guard:', isTRUE(attr(base::outer, 'biome_guard')), '\n')
            cat('expand_grid_guard:', isTRUE(attr(base::expand.grid, 'biome_guard')), '\n')
        }, error = function(e) cat('GUARD_CHECK_FAILED:', e\\\$message, '\n'))
    \" 2>&1" 30)

    if [[ -n "$guard_check" ]]; then
        local all_ok=true
        while IFS= read -r line; do
            if echo "$line" | grep -q "TRUE"; then
                report "  $(severity OK): $line"
            elif echo "$line" | grep -q "FALSE"; then
                report "  $(severity CRITICAL): $line ← GUARD NOT INSTALLED!"
                all_ok=false
            elif echo "$line" | grep -q "GUARD_CHECK_FAILED"; then
                report "  $(severity CRITICAL): $line"
                all_ok=false
            fi
        done <<< "$guard_check"
        if [[ "$all_ok" == true ]]; then
            report ""
            report "  All base guards are installed and functional."
        else
            report ""
            report "  FIX: Redeploy Rprofile v11.0: sudo bash scripts/50_setup_nodes.sh → option 3"
        fi
    else
        report "  $(severity HIGH): Could not verify guard status (Rscript timed out or failed)"
    fi

    subsection "Rprofile Syntax Validation"
    local syntax_check
    syntax_check=$(safe_cmd "Rscript --vanilla -e \"
        tryCatch({parse(file='$RPROFILE_PATH');cat('PARSE_OK')},
            error=function(e) cat(sprintf('PARSE_FAIL: %s', e\\\$message)))
    \" 2>&1" 10)

    if echo "$syntax_check" | grep -q "PARSE_OK"; then
        report "  $(severity OK): Rprofile.site syntax is valid"
    else
        report "  $(severity CRITICAL): Rprofile.site has PARSE ERROR!"
        report "  $syntax_check"
        report "  FIX: Restore backup: sudo cp /etc/R/Rprofile.site.bak /etc/R/Rprofile.site"
    fi

    subsection "Template Placeholders"
    local placeholder_count
    placeholder_count=$(safe_cmd "grep -cE '%%[A-Z0-9_]+%%' '$RPROFILE_PATH' 2>/dev/null" 3 | awk 'NR==1 {print $1+0}')
    if [[ -n "$placeholder_count" && "$placeholder_count" -gt 0 ]]; then
        report "  $(severity CRITICAL): Found ${placeholder_count} unsubstituted %%PLACEHOLDERS%% in Rprofile.site!"
        report "  Template was not processed correctly. Redeploy with 50_setup_nodes.sh → option 3."
        safe_cmd "grep -oE '%%[A-Z0-9_]+%%' '$RPROFILE_PATH' 2>/dev/null | head -5" 3 | while IFS= read -r line; do
            report "    $line"
        done
    else
        report "  $(severity OK): No unsubstituted template placeholders"
    fi

    # v2.1.0: v11.0 tools (biome_future_plan, biome_worker_diagnostics)
    subsection "v11.0 Tools in tools:biome_calc"
    local tools_check
    tools_check=$(safe_cmd "timeout 30 Rscript --vanilla -e \"
        suppressMessages(try(source('$RPROFILE_PATH'), silent = TRUE))
        if (exists('.biome_env')) {
          cat(sprintf('VERSION: %s\n', .biome_env\\\$VERSION %||% 'unknown'))
          cat(sprintf('API_VERSION: %s\n', .biome_env\\\$API_VERSION %||% 0))
        }
        if ('tools:biome_calc' %in% search()) {
          tools <- ls(as.environment('tools:biome_calc'))
          cat(sprintf('TOOLS_TOTAL: %d\n', length(tools)))
          for (t in c('biome_make_cluster','biome_future_plan','biome_worker_diagnostics','biome_plot_budget','status')) {
            cat(sprintf('TOOL_%s: %s\n', t, t %in% tools))
          }
        } else cat('tools:biome_calc: NOT_ATTACHED\n')
    \" 2>&1" 35)

    if [[ -n "$tools_check" ]]; then
        report "$tools_check" | sed 's/^/  /'
        if echo "$tools_check" | grep -qE "TOOL_biome_future_plan: TRUE" && \
           echo "$tools_check" | grep -qE "TOOL_biome_worker_diagnostics: TRUE"; then
            report "  $(severity OK): v11.0 tools attached"
        else
            report "  $(severity MEDIUM): v11.0 tools missing (biome_future_plan / biome_worker_diagnostics)"
            report "  → Rprofile likely pre-v11.0"
        fi
    fi

    # v2.1.0: NIMBLE routing — v11.0 expects /Rtmp, not NFS
    subsection "NIMBLE Routing (v11.0 expects /Rtmp, NOT NFS)"
    local nimble_route
    nimble_route=$(safe_cmd "timeout 15 Rscript --vanilla -e \"
        suppressMessages(try(source('$RPROFILE_PATH'), silent = TRUE))
        if ('nimble' %in% rownames(installed.packages())) {
          suppressMessages(try(library(nimble), silent = TRUE))
          if (exists('.biome_env') && is.function(.biome_env\\\$deferred_pkg_hooks)) try(.biome_env\\\$deferred_pkg_hooks(), silent = TRUE)
          nd <- getOption('nimble.dirName', '')
          bnd <- Sys.getenv('BIOME_NIMBLE_DIR', '')
          cat('nimble.dirName:', nd, '\n')
          cat('BIOME_NIMBLE_DIR:', bnd, '\n')
          cat('routed_to_rtmp:', (startsWith(nd, '/Rtmp/') || startsWith(bnd, '/Rtmp/')), '\n')
        } else cat('nimble: NOT_INSTALLED\n')
    \" 2>&1" 20)

    if [[ -n "$nimble_route" ]]; then
        report "$nimble_route" | sed 's/^/  /'
        if echo "$nimble_route" | grep -q "routed_to_rtmp: TRUE"; then
            report "  $(severity OK): NIMBLE routed to /Rtmp (v11.0 local-disk)"
        elif echo "$nimble_route" | grep -q "nimble: NOT_INSTALLED"; then
            report "  $(severity LOW): nimble not installed — skipped"
        else
            report "  $(severity HIGH): NIMBLE routing not on /Rtmp — v10.0 NFS-race pattern"
            report "  → Concurrent compileNimble() in parLapply workers can produce unserialize() crashes"
        fi
    fi
}

collect_nfs_status() {
    section "7. NFS STORAGE HEALTH"

    subsection "NFS Mounts"
    local nfs_mounts
    nfs_mounts=$(safe_cmd "mount | grep -E 'nfs|cifs'" 5)
    if [[ -n "$nfs_mounts" ]]; then
        report "$nfs_mounts"
    else
        report "  $(severity HIGH): No NFS/CIFS mounts detected!"
    fi

    subsection "NFS Accessibility"
    local nfs_test
    nfs_test=$(safe_cmd "timeout 5 ls $NFS_HOME/ 2>&1 | head -5" 8)
    if [[ -n "$nfs_test" ]]; then
        local user_count
        user_count=$(safe_cmd "timeout 5 ls -1 $NFS_HOME/ 2>/dev/null | wc -l" 8)
        report "  $(severity OK): NFS accessible (${user_count:-?} user directories)"
    else
        report "  $(severity CRITICAL): NFS home directory NOT accessible!"
        report "  This means ALL users cannot log in."
        report "  Check: TrueNAS connectivity, NFS server status, network"
    fi

    subsection "NFS Disk Space"
    local nfs_df
    nfs_df=$(safe_cmd "timeout 5 df -h $NFS_HOME 2>/dev/null" 8)
    if [[ -n "$nfs_df" ]]; then
        report "$nfs_df"
    else
        report "  Could not query NFS disk space (mount may be stale)"
    fi
}

collect_orphan_status() {
    section "8. ORPHAN PROCESS CHECK"

    local orphan_count
    orphan_count=$(safe_cmd "ps -eo pid,ppid,user,rss,args 2>/dev/null | awk '\$2 == 1' | grep -cE 'Rscript|R --slave|R --no-save|R --no-echo'" 5)
    orphan_count=$(safe_number "${orphan_count//[^0-9]/}")

    if [[ "$orphan_count" -gt 0 ]]; then
        report "  $(severity HIGH): Found ${orphan_count} orphaned R processes (PPID=1)"
        report ""
        safe_cmd "ps -eo pid,ppid,user,rss:10,etime,args 2>/dev/null | awk '\$2 == 1' | grep -E 'Rscript|R --slave|R --no-save|R --no-echo' | sort -k4 -rn | head -10" 5 | while IFS= read -r line; do
            report "  $line"
        done
        report ""
        local total_rss_kb
        total_rss_kb=$(safe_cmd "ps -eo ppid,rss 2>/dev/null | awk '\$1 == 1' | awk '{sum += \$2} END {print sum}'" 5)
        if [[ -n "$total_rss_kb" && "$total_rss_kb" -gt 0 ]]; then
            local total_rss_mb=$((total_rss_kb / 1024))
            report "  Total orphan RAM: ~${total_rss_mb} MB"
            if [[ $total_rss_mb -gt 4096 ]]; then
                report "  $(severity HIGH): Orphans consuming >4GB RAM — run cleanup!"
                report "  FIX: sudo bash /etc/biome-calc/script/cleanup_r_orphans.sh"
            fi
        fi
    else
        report "  $(severity OK): No orphaned R processes found."
    fi

    subsection "Cleanup Cron Status"
    if [[ -f /etc/cron.d/r_orphan_cleanup ]]; then
        report "  $(severity OK): Orphan cleanup cron installed"
        safe_read /etc/cron.d/r_orphan_cleanup 3 | while IFS= read -r line; do
            report "    $line"
        done
        local script_missing=false
        for s in cleanup_r_orphans.sh notify_r_orphans.sh r_orphan_report.sh; do
            if [[ ! -x "/etc/biome-calc/script/$s" ]]; then
                report "  $(severity CRITICAL): Required script missing or not executable: /etc/biome-calc/script/$s"
                script_missing=true
            fi
        done
        if [[ "$script_missing" == false ]]; then
            report "  $(severity OK): All cleanup daemon scripts are installed and executable"
        else
            report "  FIX: Redeploy orphan cleanup scripts: sudo bash scripts/50_setup_nodes.sh → option 8"
        fi
    else
        report "  $(severity MEDIUM): Orphan cleanup cron NOT found!"
        report "  FIX: sudo bash scripts/50_setup_nodes.sh → option 8"
    fi
}

collect_service_status() {
    section "9. SERVICE STATUS"

    local -a services=("rstudio-server" "nginx")

    if systemctl list-unit-files 2>/dev/null | grep -q "sssd.service"; then
        services+=("sssd")
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "winbind.service"; then
        services+=("winbind")
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "botanical-telemetry.service"; then
        services+=("botanical-telemetry")
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "prometheus-node-exporter.service"; then
        services+=("prometheus-node-exporter")
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "ollama.service"; then
        services+=("ollama")
    fi

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            report "  $(severity OK): $svc is RUNNING"
        else
            report "  $(severity CRITICAL): $svc is STOPPED/FAILED"
            local svc_status
            svc_status=$(safe_cmd "systemctl status '$svc' --no-pager 2>/dev/null | tail -5" 5)
            if [[ -n "$svc_status" ]]; then
                report "$svc_status"
            fi
        fi
    done

    # v2.1.0: biome-cleanup-orphans.timer
    if systemctl list-unit-files 2>/dev/null | grep -q "biome-cleanup-orphans.timer"; then
        if systemctl is-active --quiet biome-cleanup-orphans.timer 2>/dev/null; then
            report "  $(severity OK): biome-cleanup-orphans.timer is ACTIVE"
        else
            report "  $(severity MEDIUM): biome-cleanup-orphans.timer is INACTIVE"
        fi
    fi
}

# =============================================================================
# BUG FIX v2.1.0: renumbered sections — SSL=10, Nginx=11, Telemetry=12,
# RStudio=13, Auth=14, Diagnosis=15, v11.0 Integrity=16
# =============================================================================

collect_ssl_status() {
    section "10. SSL CERTIFICATE STATUS"

    local cert_path
    cert_path=$(safe_cmd "grep -rh 'ssl_certificate[^_]' /etc/nginx/snippets/ /etc/nginx/sites-enabled/ 2>/dev/null | grep -v '#' | head -1 | awk '{print \$2}' | tr -d ';'" 5)

    if [[ -z "$cert_path" ]]; then
        for p in /etc/letsencrypt/live/*/fullchain.pem /etc/ssl/certs/nginx-selfsigned.crt; do
            if [[ -f "$p" ]]; then
                cert_path="$p"
                break
            fi
        done
    fi

    if [[ -n "$cert_path" && -f "$cert_path" ]]; then
        report "  Certificate: $cert_path"

        local cert_subject cert_issuer cert_notafter cert_notbefore
        cert_subject=$(safe_cmd "openssl x509 -in '$cert_path' -noout -subject 2>/dev/null" 5)
        cert_issuer=$(safe_cmd "openssl x509 -in '$cert_path' -noout -issuer 2>/dev/null" 5)
        cert_notafter=$(safe_cmd "openssl x509 -in '$cert_path' -noout -enddate 2>/dev/null | cut -d= -f2" 5)
        cert_notbefore=$(safe_cmd "openssl x509 -in '$cert_path' -noout -startdate 2>/dev/null | cut -d= -f2" 5)

        report "  Subject:    ${cert_subject:-unknown}"
        report "  Issuer:     ${cert_issuer:-unknown}"
        report "  Valid From: ${cert_notbefore:-unknown}"
        report "  Expires:    ${cert_notafter:-unknown}"

        if [[ -n "$cert_notafter" ]]; then
            local expiry_epoch now_epoch days_left
            expiry_epoch=$(safe_cmd "date -d '$cert_notafter' +%s 2>/dev/null" 3)
            now_epoch=$(date +%s)
            if [[ -n "$expiry_epoch" ]]; then
                days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                report "  Days until expiry: ${days_left}"
                if [[ $days_left -lt 0 ]]; then
                    report "  $(severity CRITICAL): SSL certificate has EXPIRED!"
                    report "  Users see browser security warnings = 'it crashed'"
                    report "  FIX: sudo bash scripts/32_setup_letsencrypt.sh → option 6"
                elif [[ $days_left -lt 14 ]]; then
                    report "  $(severity HIGH): SSL certificate expires in ${days_left} days!"
                    report "  FIX: sudo certbot renew --post-hook 'systemctl reload nginx'"
                elif [[ $days_left -lt 30 ]]; then
                    report "  $(severity MEDIUM): SSL certificate expires in ${days_left} days"
                else
                    report "  $(severity OK): Certificate valid for ${days_left} more days"
                fi
            fi
        fi

        if echo "${cert_issuer:-}" | grep -qi "self.signed\|nginx-selfsigned"; then
            report "  $(severity MEDIUM): Self-signed certificate detected"
            report "  Browsers may show security warnings on first visit"
        fi
    else
        report "  $(severity HIGH): No SSL certificate found!"
        report "  NGINX may be serving plain HTTP or is misconfigured."
    fi

    subsection "Auto-Renewal Cron"
    if [[ -f /etc/cron.d/certbot-renew ]] || crontab -l 2>/dev/null | grep -q certbot; then
        report "  $(severity OK): Certbot auto-renewal is configured"
    elif [[ -f /etc/cron.d/certbot ]]; then
        report "  $(severity OK): System certbot cron exists"
    else
        if command -v certbot &>/dev/null; then
            report "  $(severity MEDIUM): Certbot installed but no auto-renewal cron found"
            report "  FIX: sudo bash scripts/32_setup_letsencrypt.sh → option 4"
        else
            report "  $(severity LOW): Certbot not installed (self-signed cert, no renewal needed)"
        fi
    fi
}

collect_nginx_status() {
    section "11. NGINX CONFIGURATION HEALTH"

    subsection "Config Syntax"
    local nginx_test
    nginx_test=$(safe_cmd "nginx -t 2>&1" 5)
    if echo "$nginx_test" | grep -q "syntax is ok"; then
        report "  $(severity OK): NGINX config syntax is valid"
    else
        report "  $(severity CRITICAL): NGINX config has SYNTAX ERRORS!"
        report "  $nginx_test"
        report "  FIX: Check /etc/nginx/sites-enabled/ for broken configs"
    fi

    subsection "Proxy Timeout (RStudio)"
    local proxy_timeout
    proxy_timeout=$(safe_cmd "grep -rh 'proxy_read_timeout' /etc/nginx/sites-enabled/ /etc/nginx/snippets/ 2>/dev/null | grep -v '#' | head -1 | grep -oP '\d+'" 5)
    if [[ -n "$proxy_timeout" ]]; then
        report "  proxy_read_timeout = ${proxy_timeout}s"
        if [[ "$proxy_timeout" -lt 300 ]]; then
            report "  $(severity HIGH): Timeout too short for NIMBLE MCMC / long R jobs!"
            report "  Long computations will be killed by NGINX before completing."
            report "  Users will report: 'RStudio disconnected' or 'it crashed'"
            report "  FIX: Increase RSESSION_TIMEOUT_SECONDS in config/install_nginx.vars.conf"
        elif [[ "$proxy_timeout" -lt 3600 ]]; then
            report "  $(severity MEDIUM): Timeout OK for typical jobs, may be short for NIMBLE"
        else
            report "  $(severity OK): Proxy timeout generous enough for long R sessions"
        fi
    else
        report "  $(severity MEDIUM): Could not detect proxy_read_timeout in NGINX config"
    fi

    subsection "WebSocket Support"
    local ws_upgrade
    ws_upgrade=$(safe_cmd "grep -rh 'proxy_set_header Upgrade' /etc/nginx/sites-enabled/ 2>/dev/null | grep -v '#' | head -1" 5)
    if [[ -n "$ws_upgrade" ]]; then
        report "  $(severity OK): WebSocket upgrade headers present"
    else
        report "  $(severity HIGH): WebSocket upgrade headers NOT found!"
        report "  RStudio IDE requires WebSocket for real-time updates."
        report "  FIX: Ensure nginx_proxy_location.conf.template is deployed"
    fi

    subsection "Portal Files"
    if [[ -f /var/www/html/index.html ]]; then
        report "  $(severity OK): Portal index.html is deployed"
    else
        report "  $(severity MEDIUM): Portal index.html missing — users see default NGINX page"
        report "  FIX: sudo bash scripts/31_setup_web_portal.sh"
    fi
    if [[ -f /var/www/html/biome-portal.js ]]; then
        report "  $(severity OK): biome-portal.js is deployed"
    else
        report "  $(severity MEDIUM): biome-portal.js missing — portal nav/telemetry broken"
    fi
}

collect_telemetry_status() {
    section "12. TELEMETRY API HEALTH"

    subsection "FastAPI Health Endpoint"
    local api_health
    api_health=$(safe_cmd "curl -sf --max-time 5 http://127.0.0.1:8000/api/v1/health 2>&1" 8)
    if [[ -n "$api_health" ]]; then
        report "  $(severity OK): /api/v1/health → $api_health"
    else
        report "  $(severity MEDIUM): Telemetry API not responding on port 8000"
        report "  Portal telemetry strip will show 'offline'"
        report "  FIX: sudo systemctl restart botanical-telemetry"
        report "  DEBUG: journalctl -u botanical-telemetry -n 20"
    fi

    subsection "Node Exporter"
    local node_exp
    node_exp=$(safe_cmd "curl -sf --max-time 5 http://127.0.0.1:9100/metrics 2>&1 | head -1" 8)
    if [[ -n "$node_exp" ]]; then
        report "  $(severity OK): Node Exporter responding on port 9100"
    else
        report "  $(severity LOW): Node Exporter not responding on port 9100"
        report "  FIX: sudo systemctl restart prometheus-node-exporter"
    fi

    subsection "Telemetry Venv"
    local venv_path="/opt/botanical-telemetry"
    if [[ -f "${venv_path}/bin/python3" ]]; then
        local venv_python_ver
        venv_python_ver=$(safe_cmd "${venv_path}/bin/python3 --version 2>&1" 3)
        report "  $(severity OK): Telemetry venv exists (${venv_python_ver:-unknown})"
    else
        report "  $(severity MEDIUM): Telemetry venv not found at ${venv_path}"
        report "  FIX: sudo bash scripts/40_install_telemetry.sh"
    fi
}

collect_rstudio_config() {
    section "13. RSTUDIO SERVER CONFIGURATION"

    local rserver_conf="/etc/rstudio/rserver.conf"
    local rsession_conf="/etc/rstudio/rsession.conf"

    subsection "rserver.conf"
    if [[ -f "$rserver_conf" ]]; then
        local bind_addr
        bind_addr=$(safe_cmd "grep '^www-address=' '$rserver_conf' | cut -d= -f2" 3)
        report "  www-address = ${bind_addr:-not set}"
        if [[ "${bind_addr:-}" != "127.0.0.1" ]]; then
            report "  $(severity HIGH): RStudio should bind to 127.0.0.1 (proxied via NGINX)"
            report "  If bound to 0.0.0.0, RStudio is directly accessible bypassing NGINX auth!"
        else
            report "  $(severity OK): Bound to localhost (behind NGINX proxy)"
        fi

        local bind_port
        bind_port=$(safe_cmd "grep '^www-port=' '$rserver_conf' | cut -d= -f2" 3)
        report "  www-port = ${bind_port:-8787}"

        local frame_origin
        frame_origin=$(safe_cmd "grep '^www-frame-origin=' '$rserver_conf' | cut -d= -f2" 3)
        if [[ "${frame_origin:-}" == "same" ]]; then
            report "  $(severity OK): www-frame-origin=same (iframe embedding works)"
        else
            report "  $(severity MEDIUM): www-frame-origin=${frame_origin:-not set} — portal iframe may break"
        fi

        local encrypt_pw
        encrypt_pw=$(safe_cmd "grep '^auth-encrypt-password=' '$rserver_conf' | cut -d= -f2" 3)
        if [[ "${encrypt_pw:-}" == "0" ]]; then
            report "  $(severity OK): auth-encrypt-password=0 (NGINX handles SSL)"
        elif [[ -n "${encrypt_pw:-}" ]]; then
            report "  $(severity MEDIUM): auth-encrypt-password=${encrypt_pw} — may cause 'system error 74'"
        fi
    else
        report "  $(severity HIGH): rserver.conf not found at $rserver_conf"
    fi

    subsection "rsession.conf"
    if [[ -f "$rsession_conf" ]]; then
        report "  $(safe_read "$rsession_conf" 15)"
    else
        report "  rsession.conf not found (using defaults)"
    fi

    subsection "RStudio Verify Installation"
    local rstudio_ver
    rstudio_ver=$(safe_cmd "rstudio-server version 2>/dev/null" 5)
    if [[ -n "$rstudio_ver" ]]; then
        report "  $(severity OK): RStudio Server version: $rstudio_ver"
    else
        report "  $(severity CRITICAL): rstudio-server binary not found or not responding!"
    fi

    local verify_result
    verify_result=$(safe_cmd "rstudio-server verify-installation 2>&1" 10)
    if echo "$verify_result" | grep -qi "error\|fail"; then
        report "  $(severity HIGH): Installation verification issues:"
        report "  $verify_result"
    else
        report "  $(severity OK): Installation verification passed"
    fi
}

collect_auth_status() {
    section "14. AUTHENTICATION & KERBEROS"

    subsection "Auth Backend Detection"
    local auth_backend="none"
    if systemctl is-active --quiet sssd 2>/dev/null; then
        auth_backend="SSSD"
        report "  $(severity OK): SSSD is active"
    elif systemctl is-active --quiet winbind 2>/dev/null; then
        auth_backend="Winbind/Samba"
        report "  $(severity OK): Winbind is active"
    else
        report "  $(severity MEDIUM): No AD auth backend detected (local auth only)"
    fi

    subsection "PAM Configuration"
    local pam_rstudio="/etc/pam.d/rstudio"
    if [[ -f "$pam_rstudio" ]]; then
        local pam_content
        pam_content=$(safe_read "$pam_rstudio" 10)
        report "  $pam_content"
        if echo "$pam_content" | grep -q "common-auth"; then
            report "  $(severity OK): PAM delegates to system auth stack"
        else
            report "  $(severity HIGH): PAM config may not use system auth — login issues possible"
        fi
    else
        report "  $(severity MEDIUM): /etc/pam.d/rstudio not found (RStudio uses default PAM)"
    fi

    if [[ "$auth_backend" != "none" ]]; then
        subsection "Kerberos Ticket"
        local krb_list
        krb_list=$(safe_cmd "klist -l 2>/dev/null | head -5" 5)
        if [[ -n "$krb_list" ]]; then
            report "  $krb_list"
        else
            report "  No Kerberos tickets found (machine may need rejoin)"
        fi

        subsection "Domain Join Status"
        local realm_list
        realm_list=$(safe_cmd "realm list --name-only 2>/dev/null" 5)
        if [[ -n "$realm_list" ]]; then
            report "  $(severity OK): Joined to realm: $realm_list"
        else
            report "  $(severity HIGH): Not joined to any realm!"
            report "  FIX: sudo bash scripts/10_join_domain_sssd.sh or 11_join_domain_samba.sh"
        fi

        subsection "Name Resolution"
        local nss_test
        nss_test=$(safe_cmd "getent passwd | head -3" 5)
        if [[ -n "$nss_test" ]]; then
            local nss_count
            nss_count=$(safe_cmd "getent passwd | wc -l" 5)
            report "  $(severity OK): NSS resolving users (${nss_count:-?} entries)"
        else
            report "  $(severity CRITICAL): getent passwd returns nothing!"
            report "  Users cannot authenticate. Check SSSD/Winbind/nsswitch.conf"
        fi
    fi
}

# =============================================================================
# v2.1.0 NEW SECTION: v11.0 integrity + return() bug detection
# =============================================================================
collect_v11_integrity() {
    section "15. BIOME v11.0 INTEGRITY CHECK"

    subsection "OpenMP Infrastructure"
    if dpkg -l libgomp1 2>/dev/null | grep -q '^ii'; then
        report "  $(severity OK): libgomp1 installed"
    else
        report "  $(severity HIGH): libgomp1 NOT installed — OpenMP unavailable"
    fi
    if [[ -f /usr/local/lib/pkgconfig/openmp.pc ]]; then
        report "  $(severity OK): /usr/local/lib/pkgconfig/openmp.pc present"
    else
        report "  $(severity MEDIUM): openmp.pc missing (R packages won't compile with -fopenmp)"
    fi
    if command -v pkg-config &>/dev/null; then
        local omp_cflags
        omp_cflags=$(pkg-config --cflags openmp 2>/dev/null || true)
        if echo "$omp_cflags" | grep -q -- '-fopenmp'; then
            report "  $(severity OK): pkg-config --cflags openmp → $omp_cflags"
        else
            report "  $(severity MEDIUM): pkg-config --cflags openmp → '${omp_cflags:-<empty>}'"
        fi
    fi

    subsection "v11.0 Top-Level return() Bug Detection"
    # Spawn Rscript with BIOME_WORKER_MODE=1 and verify -e body runs.
    # If Rscript aborts (v10.0 bug present), worker PSOCK nodes die at handshake.
    if command -v Rscript &>/dev/null && [[ -f "$RPROFILE_PATH" ]]; then
        local marker
        marker=$(mktemp -t biome_v11_check.XXXXXX)
        BIOME_WORKER_MODE=1 BIOME_WORKER_THREADS=1 \
            R_PROFILE="$RPROFILE_PATH" \
            timeout 20 Rscript --no-init-file --no-save --no-restore --no-echo \
                -e "cat('ALIVE=', Sys.getpid(), sep='', file='$marker')" >/dev/null 2>&1 || true

        if [[ -s "$marker" ]]; then
            report "  $(severity OK): Worker Rscript body executed ($(cat "$marker"))"
            report "    → return() bug fix is in place (v11.0+)"
        else
            report "  $(severity CRITICAL): Worker Rscript ABORTED during Rprofile load"
            report "    → v10.0 top-level return() BUG PRESENT"
            report "    → SYMPTOM: PSOCK workers die at handshake (unserialize(node\$con))"
            report "    → FIX: Deploy Rprofile v11.0"
        fi
        rm -f "$marker"
    else
        report "  $(severity MEDIUM): Cannot run Rscript detection (missing Rscript or Rprofile)"
    fi

    subsection "BIOME_USER_TMP Env Var (v11.0)"
    # The current user (root, likely) may not have BIOME_USER_TMP set. This is
    # expected — we're checking whether the Rprofile SETS it during load.
    local but
    but=$(safe_cmd "timeout 10 Rscript --vanilla -e \"
        suppressMessages(try(source('$RPROFILE_PATH'), silent = TRUE))
        cat(Sys.getenv('BIOME_USER_TMP'))
    \" 2>/dev/null" 15)
    if [[ -n "$but" ]]; then
        if [[ "$but" == /Rtmp/biome_* ]]; then
            report "  $(severity OK): BIOME_USER_TMP=$but (v11.0 layout)"
        else
            report "  $(severity MEDIUM): BIOME_USER_TMP=$but (expected /Rtmp/biome_<user>)"
        fi
    else
        report "  $(severity MEDIUM): Rprofile does not set BIOME_USER_TMP (pre-v11.0)"
    fi
}

# =============================================================================
# ANALYSIS ENGINE — SYNTHESIZE ALL DATA INTO DIAGNOSIS
# =============================================================================

generate_diagnosis() {
    local target_user="${1:-}"
    local hours="${2:-4}"

    section "16. AUTOMATED DIAGNOSIS"

    # BUG FIX v2.1.0: previously, robust patched counters were overwritten
    # by legacy safe_cmd + awk code. That has been REMOVED. The patched
    # helpers are authoritative.
    local has_oom has_sigsegv has_sigill has_orphans has_pthread
    has_oom=$(safe_number "$(count_lines "dmesg -T 2>/dev/null | grep -iE 'oom|killed process'")")
    has_sigsegv=$(safe_number "$(count_lines "journalctl -u rstudio-server --since '${hours} hours ago' --no-pager 2>/dev/null | grep -iE 'SIGSEGV|segv|signal 11'")")
    has_sigill=$(safe_number "$(count_lines "journalctl -u rstudio-server --since '${hours} hours ago' --no-pager 2>/dev/null | grep -iE 'SIGILL|signal 4'")")
    has_orphans=$(safe_number "$(count_lines "ps -eo ppid,args 2>/dev/null | awk '\$1 == 1' | grep -E 'Rscript|R --slave'")")
    has_pthread=$(safe_number "$(count_lines "update-alternatives --display libblas.so.3-x86_64-linux-gnu 2>/dev/null | grep -i pthread")")

    # v2.1.0: detect top-level return() bug
    local has_return_bug=0
    if command -v Rscript &>/dev/null && [[ -f "$RPROFILE_PATH" ]]; then
        local bug_marker
        bug_marker=$(mktemp -t biome_diag.XXXXXX)
        BIOME_WORKER_MODE=1 BIOME_WORKER_THREADS=1 \
            R_PROFILE="$RPROFILE_PATH" \
            timeout 20 Rscript --no-init-file --no-save --no-restore --no-echo \
                -e "cat('ALIVE', file='$bug_marker')" >/dev/null 2>&1 || true
        if [[ ! -s "$bug_marker" ]]; then
            has_return_bug=1
        fi
        rm -f "$bug_marker"
    fi

    if [[ "${has_pthread:-0}" -gt 0 ]]; then
        report "  $(severity CRITICAL) DIAGNOSIS: OpenBLAS-pthread is active"
        report "    CAUSE: pthread BLAS thread pool races with rsession pthreads"
        report "    SYMPTOM: Random SIGSEGV during solve()/crossprod()"
        report "    FIX: sudo apt-get remove libopenblas0-pthread && sudo apt-get install libopenblas-serial-dev"
        report ""
    fi

    if [[ "${has_sigsegv:-0}" -gt 0 ]]; then
        report "  $(severity CRITICAL) DIAGNOSIS: SIGSEGV detected in last ${hours}h"
        report "    CAUSE: BLAS thread collision or memory corruption"
        report "    FIX: Check BLAS variant (section 5 above), rebuild if pthread"
        report ""
    fi

    if [[ "${has_sigill:-0}" -gt 0 ]]; then
        report "  $(severity CRITICAL) DIAGNOSIS: SIGILL detected — CPU instruction mismatch"
        report "    CAUSE: OPENBLAS_CORETYPE set for a CPU that was live-migrated away"
        report "    FIX: sudo bash scripts/50_setup_nodes.sh → option 2"
        report ""
    fi

    if [[ "${has_oom:-0}" -gt 0 ]]; then
        report "  $(severity CRITICAL) DIAGNOSIS: Kernel OOM kills detected"
        report "    CAUSE: R session(s) allocated more RAM than available"
        report "    CHECK: Did the guard fire? (look for BIOME-CALC warnings in section 4)"
        report "    IF GUARD FIRED: User ignored warning. Consider making guard BLOCKING (stop() vs warning())"
        report "    IF GUARD DID NOT FIRE: Unguarded operation — check the unguarded patterns table"
        report ""
        print_unguarded_patterns_table
        report ""
        report "    FIX OPTIONS:"
        report "      1. Rewrite user's script to use sparse/chunked methods"
        report "      2. Add a new guard for the unguarded pattern"
        report "      3. Increase VM RAM or swap"
        report ""
    fi

    if [[ "${has_orphans:-0}" -gt 3 ]]; then
        report "  $(severity HIGH) DIAGNOSIS: ${has_orphans} orphaned R processes"
        report "    CAUSE: User sessions crashed/disconnected without cleanup"
        report "    IMPACT: Memory leak — orphans consume RAM indefinitely"
        report "    FIX: sudo bash /etc/biome-calc/script/cleanup_r_orphans.sh"
        report ""
    fi

    # v2.1.0: top-level return() bug diagnosis
    if [[ "${has_return_bug:-0}" -gt 0 ]]; then
        report "  $(severity CRITICAL) DIAGNOSIS: v10.0 top-level return() bug present"
        report "    CAUSE: Rprofile.site has a top-level return() that aborts Rscript"
        report "    SYMPTOM: parLapply/makeClusterPSOCK workers die at handshake →"
        report "             'Error in unserialize(node\$con) : error reading from connection'"
        report "    DETECTION: Spawned Rscript with BIOME_WORKER_MODE=1 and -e body failed to execute"
        report "    FIX: Deploy Rprofile v11.0"
        report ""
    fi

    # User-specific issues
    local large_payloads=0
    if [[ -n "$target_user" ]]; then
        local user_home
        user_home=$(safe_cmd "getent passwd '$target_user' | cut -d: -f6" 3)

        if [[ -n "$user_home" && -f "${user_home}/ULTIMO_CRASH_RAM.txt" ]]; then
            report "  $(severity CRITICAL) DIAGNOSIS: User '$target_user' experienced OOM crash"
            report "    Evidence: ULTIMO_CRASH_RAM.txt marker file present"
            report "    FIX: Review user's script, check guard coverage, estimate memory need"
            report ""
        fi

        local thread_overrides
        thread_overrides=$(grep -cE '^(OMP_NUM_THREADS|OPENBLAS_NUM_THREADS)=' "${user_home}/.Renviron" 2>/dev/null || echo "0")
        thread_overrides="${thread_overrides//[^0-9]/}"
        if [[ "${thread_overrides:-0}" -gt 0 ]]; then
            report "  $(severity HIGH) DIAGNOSIS: User has hardcoded thread settings"
            report "    File: ${user_home}/.Renviron"
            report "    IMPACT: Overrides dynamic allocation — can cause thread fan-out"
            report "    FIX: Remove OMP_NUM_THREADS/OPENBLAS_NUM_THREADS from user .Renviron"
            report ""
        fi

        if [[ -d "${user_home}/.local/share/rstudio/sessions/active" ]]; then
            large_payloads=$(safe_cmd "find '${user_home}/.local/share/rstudio/sessions/active' -type f -size +50M 2>/dev/null | wc -l" 5 | awk 'NR==1 {print $1+0}')
        fi

        if [[ "${large_payloads:-0}" -gt 0 ]]; then
            report "  $(severity CRITICAL) DIAGNOSIS: Massive Session Payload (Aw, Snap! Error Code 4)"
            report "    CAUSE: The R session suspend file (.env/.RData) is >50MB."
            report "    SYMPTOM: When resuming session, NGINX may drop connection, or browser tab crashes"
            report "             with 'Aw, Snap!' or 'Error Code: 4' (Browser OOM parsing workspace state)."
            report "    FIX: Reset user's session state by clearing the rstudio active session folder:"
            report "         sudo mv ${user_home}/.local/share/rstudio/sessions/active \\"
            report "                 ${user_home}/.local/share/rstudio/sessions/active_backup_\$(date +%s)"
            report ""
        fi

        # v2.1.0: user-specific worker error aggregation
        local user_tmp="${RTMP_PATH}/biome_${target_user}"
        if [[ -d "${user_tmp}/cluster_logs" ]]; then
            local worker_errors
            worker_errors=$(safe_cmd "find '${user_tmp}/cluster_logs' -name 'psock_*.log' -mmin -$((hours * 60)) -exec grep -c -iE 'unserialize|SIGSEGV|fatal' {} + 2>/dev/null | awk -F: '{sum+=\$2} END {print sum+0}'" 10)
            worker_errors=$(safe_number "${worker_errors//[^0-9]/}")
            if [[ "${worker_errors:-0}" -gt 0 ]]; then
                report "  $(severity HIGH) DIAGNOSIS: ${worker_errors} PSOCK worker error(s) in last ${hours}h"
                report "    FILE: ${user_tmp}/cluster_logs/"
                report "    CAUSE: Typically unserialize(node\$con) from NFS race OR top-level return() bug"
                report "    FIX: Verify Rprofile v11.0 deployed; use biome_worker_diagnostics() to inspect"
                report ""
            fi
        fi
    fi

    # If nothing found
    if [[ "${has_oom:-0}" -eq 0 && "${has_sigsegv:-0}" -eq 0 && "${has_sigill:-0}" -eq 0 \
          && "${has_pthread:-0}" -eq 0 && "${large_payloads:-0}" -eq 0 \
          && "${has_return_bug:-0}" -eq 0 ]]; then
        report "  $(severity OK): No critical crash indicators found in the last ${hours}h."
        report ""
        report "  POSSIBLE NON-CRASH CAUSES:"
        report "    - Browser/VPN disconnection (session is still alive, user thinks it crashed)"
        report "    - NGINX proxy_read_timeout exceeded during long computation"
        report "    - User confusion about warning messages (guard fired, they think it's an error)"
        report "    - Browser Tab Crash 'Error code: 4' (run this script for specific user to check for massive state payloads)"
        report "    CHECK: ps aux | grep 'rsession.*<username>' — session may still be running"
    fi
}

# =============================================================================
# INCIDENT LOG WRITER
# =============================================================================

write_incident_log() {
    local target_user="${1:-unknown}"
    local diagnosis_summary="${2:-automated collection}"

    mkdir -p "$(dirname "$INCIDENT_LOG")"

    cat >> "$INCIDENT_LOG" << EOF
=== INCIDENT: $(date -Iseconds) ===
User:       ${target_user}
Collected:  $(date '+%Y-%m-%d %H:%M:%S')
Script:     99_postmortem_forensics.sh v2.1.0
Report:     ${REPORT_FILE:-stdout}
Summary:    ${diagnosis_summary}
=======================================
EOF
    report ""
    report "  📝 Incident logged to: $INCIDENT_LOG"
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<'USAGEEND'
Usage: 99_postmortem_forensics.sh [OPTIONS]

Automated post-mortem crash forensics for BIOME-CALC R sessions.
Collects all evidence, classifies crash type, checks guard coverage,
and produces actionable diagnosis for sysadmin DevOps workflow.

Options:
  --user <username>   Target user to investigate (required unless --all-recent)
  --hours <N>         Look back N hours for crash events (default: 4)
  --output <file>     Write report to file (also prints to stdout)
  --all-recent        Scan all recent crashes (no specific user)
  --quick             Skip BLAS smoke test and guard verification (faster)
  --incident          Auto-write incident log entry
  -h, --help          Display this help

Examples:
  sudo $0 --user mario.rossi --incident
  sudo $0 --user anna.verdi --hours 8 --output /tmp/crash_report.txt --quick
  sudo $0 --all-recent --hours 2
USAGEEND
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR" "This script must be run as root (sudo). Forensic data collection requires root access."
        exit 1
    fi

    local TARGET_USER=""
    local HOURS=4
    local QUICK=false
    local ALL_RECENT=false
    local DO_INCIDENT=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                if [[ -n "${2:-}" && ! "$2" == --* ]]; then
                    TARGET_USER="$2"
                    shift 2
                else
                    echo "ERROR: --user requires a username." >&2
                    exit 1
                fi
                ;;
            --hours)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                    HOURS="$2"
                    shift 2
                else
                    echo "ERROR: --hours requires a number." >&2
                    exit 1
                fi
                ;;
            --output)
                if [[ -n "${2:-}" ]]; then
                    REPORT_FILE="$2"
                    shift 2
                else
                    echo "ERROR: --output requires a file path." >&2
                    exit 1
                fi
                ;;
            --all-recent) ALL_RECENT=true; shift ;;
            --quick)      QUICK=true; shift ;;
            --incident)   DO_INCIDENT=true; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$TARGET_USER" && "$ALL_RECENT" == false ]]; then
        echo "ERROR: Either --user <username> or --all-recent is required." >&2
        usage
        exit 1
    fi

    if [[ -n "$REPORT_FILE" ]]; then
        mkdir -p "$(dirname "$REPORT_FILE")"
        : > "$REPORT_FILE"
    fi

    report "╔═══════════════════════════════════════════════════════════════╗"
    report "║     BIOME-CALC POST-MORTEM FORENSICS v2.1.0                 ║"
    report "║     $(date '+%Y-%m-%d %H:%M:%S')                                    ║"
    if [[ -n "$TARGET_USER" ]]; then
        report "$(printf '║     User: %-50s ║' "$TARGET_USER")"
    fi
    report "$(printf '║     Lookback: %-47s ║' "${HOURS} hours")"
    report "╚═══════════════════════════════════════════════════════════════╝"

    # Sections 1-3
    collect_system_state
    collect_oom_events "$HOURS"
    collect_crash_signals "$HOURS"

    # Section 4
    if [[ -n "$TARGET_USER" ]]; then
        collect_user_forensics "$TARGET_USER" "$HOURS"
    fi

    # Section 5-6
    collect_blas_status
    if [[ "$QUICK" == false ]]; then
        collect_guard_status
    else
        report ""
        report "  ⏩ Guard verification skipped (--quick mode)"
    fi

    # Sections 7-14
    collect_nfs_status
    collect_orphan_status
    collect_service_status
    collect_ssl_status
    collect_nginx_status
    collect_telemetry_status
    collect_rstudio_config
    collect_auth_status

    # Section 15 (v2.1.0 new)
    collect_v11_integrity

    # Section 16 — Diagnosis
    generate_diagnosis "$TARGET_USER" "$HOURS"

    if [[ "$DO_INCIDENT" == true ]]; then
        write_incident_log "$TARGET_USER" "Automated forensic scan"
    fi

    section "REPORT COMPLETE"
    report "  Timestamp: $(date -Iseconds)"
    if [[ -n "$REPORT_FILE" ]]; then
        report "  Full report saved to: $REPORT_FILE"
    fi
    report "  Sections collected: 16"
    report "    1-3: System state, OOM, crash signals"
    report "    4: User-specific forensics (incl. v11.0 layout + cluster_logs)"
    report "    5-6: BLAS safety, memory guard coverage + v11.0 tools + NIMBLE routing"
    report "    7-8: NFS storage, orphan processes"
    report "    9: Service status (rstudio, nginx, sssd, telemetry, biome-cleanup-orphans)"
    report "    10: SSL certificate validity"
    report "    11: NGINX config, proxy timeouts, websocket"
    report "    12: Telemetry API health"
    report "    13: RStudio server configuration"
    report "    14: Authentication & Kerberos"
    report "    15: v11.0 integrity (OpenMP, return() bug, BIOME_USER_TMP)"
    report "    16: Automated diagnosis"
    report ""
    report "  Next steps:"
    report "    1. Review the AUTOMATED DIAGNOSIS section (16) for actionable fixes"
    report "    2. If return() bug detected: priority deploy Rprofile v11.0"
    report "    3. If user has worker errors: inspect cluster_logs/ via biome_worker_diagnostics()"
    report "    4. If infra issue: apply DevOps fix chain from troubleshooting guide"
    report ""
}

main "$@"
