#!/bin/bash
# =============================================================================
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
# Version: 1.0.0
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"

# ── Early help detection (before sourcing common_utils, which requires root) ──
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Automated post-mortem crash forensics for BIOME-CALC R sessions."
        echo "Collects all evidence, classifies crash type, checks guard coverage,"
        echo "and produces actionable diagnosis for sysadmin DevOps workflow."
        echo ""
        echo "Options:"
        echo "  --user <username>   Target user to investigate (required unless --all-recent)"
        echo "  --hours <N>         Look back N hours for crash events (default: 4)"
        echo "  --output <file>     Write report to file (also prints to stdout)"
        echo "  --all-recent        Scan all recent crashes (no specific user)"
        echo "  --quick             Skip BLAS smoke test and guard verification (faster)"
        echo "  --incident          Auto-write incident log entry"
        echo "  -h, --help          Display this help"
        echo ""
        echo "Examples:"
        echo "  # Full forensics for a specific user"
        echo "  sudo $0 --user mario.rossi --incident"
        echo ""
        echo "  # Quick scan, last 8 hours, save to file"
        echo "  sudo $0 --user anna.verdi --hours 8 --output /tmp/crash_report.txt --quick"
        echo ""
        echo "  # Scan all recent crashes (no specific user)"
        echo "  sudo $0 --all-recent --hours 2"
        exit 0
    fi
done

# Source common utilities (requires root for log directory creation)
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
# CONSTANTS (Pessimistic: all paths verified before use)
# =============================================================================

BIOME_LOG="/var/log/biome-log/r_biome_system.log"
BIOME_CONF="/etc/biome-calc"
RPROFILE_PATH="/etc/R/Rprofile.site"
RENVIRON_PATH="/etc/R/Renviron.site"
RTMP_PATH="/Rtmp"
NFS_HOME="/nfs/home"
INCIDENT_LOG="/var/log/biome-log/incident_log.txt"

# Known guarded functions (must match Rprofile_site.R.template)
GUARDED_FUNCTIONS=("solve" "dist" "outer" "expand.grid" "distm" "registerDoParallel")

# Known dangerous unguarded patterns (common in botanical R scripts)
UNGUARDED_PATTERNS=(
    "as.matrix.*dist"
    "readRDS"
    "do.call.*rbind"
    "Rcpp::sourceCpp"
    "raster::stack"
    "collect()"
    "geom_point.*aes"
    "vegdist.*hclust"
    "compileNimble"
    "merge.*by"
    "combn("
)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Safe file reader — returns content or empty string, never crashes
safe_read() {
    local filepath="$1"
    local max_lines="${2:-50}"
    if [[ -f "$filepath" && -r "$filepath" ]]; then
        head -n "$max_lines" "$filepath" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Safe command runner — returns output or empty string
safe_cmd() {
    local cmd="$1"
    local timeout_sec="${2:-10}"
    timeout "$timeout_sec" bash -c "$cmd" 2>/dev/null || echo ""
}

# Format section header
section() {
    local title="$1"
    printf "\n%s\n" "═══════════════════════════════════════════════════════════════"
    printf "  %s\n" "$title"
    printf "%s\n\n" "═══════════════════════════════════════════════════════════════"
}

# Format sub-section
subsection() {
    printf "\n  ── %s ──\n" "$1"
}

# Severity badge
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

# Write to report file (tee-style: stdout + file)
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

    subsection "Kernel Swappiness"
    local swappiness
    swappiness=$(safe_cmd "cat /proc/sys/vm/swappiness" 3)
    report "  vm.swappiness = ${swappiness:-unknown} (expected: 10)"
    if [[ -n "$swappiness" && "$swappiness" -gt 30 ]]; then
        report "  $(severity MEDIUM): Swappiness too high — should be 10 for RStudio workloads"
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
    else
        report "  $(severity HIGH): /Rtmp is NOT mounted as a separate filesystem!"
        report "  Check: Is the local virtio disk attached? Is /Rtmp in fstab?"
        # Check if it's accidentally tmpfs
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

    # dmesg OOM events
    local oom_events
    oom_events=$(safe_cmd "dmesg -T 2>/dev/null | grep -iE 'oom|killed process|out of memory' | tail -20" 10)

    if [[ -n "$oom_events" ]]; then
        report "  $(severity CRITICAL): OOM events found in kernel log!"
        report ""
        report "$oom_events"
        report ""
        # Extract killed process names and PIDs
        local killed_procs
        killed_procs=$(echo "$oom_events" | grep -oP 'Killed process \d+ \([^)]+\)' || true)
        if [[ -n "$killed_procs" ]]; then
            report "  Killed processes:"
            report "$killed_procs"
        fi
        # Extract RSS of killed processes
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
        # Classify signal types
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

    # User existence check
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
            # Check for Profile load
            if echo "$user_logs" | grep -q "Profile.*OK"; then
                report ""
                report "  $(severity OK): Rprofile loaded successfully for this user"
            else
                report ""
                report "  $(severity HIGH): No successful Rprofile load found for this user!"
                report "  Guards may NOT be active. Check .Rprofile for interference."
            fi
            # Check for guard warnings
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
        # Check for known interference patterns
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
        # Check for hardcoded thread settings (should have been migrated)
        local thread_overrides
        thread_overrides=$(grep -E '^(OMP_NUM_THREADS|OPENBLAS_NUM_THREADS|MKL_NUM_THREADS|MC_CORES)=' "$user_renviron" 2>/dev/null || true)
        if [[ -n "$thread_overrides" ]]; then
            report "  $(severity HIGH): User has hardcoded thread settings in .Renviron!"
            report "  These OVERRIDE dynamic allocation and can cause instability:"
            report "  $thread_overrides"
            report "  FIX: Remove these lines (50_setup_nodes.sh --migrate should have done this)"
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
                # Check for large suspension payloads
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

    # Also check user rstudio logs
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

    subsection "User /Rtmp Usage"
    local user_tmp="${RTMP_PATH}/biome_${target_user}"
    if [[ -d "$user_tmp" ]]; then
        local tmp_size
        tmp_size=$(safe_cmd "du -sh '$user_tmp'" 5)
        report "  $tmp_size"
        # Count files
        local tmp_files
        tmp_files=$(safe_cmd "find '$user_tmp' -type f | wc -l" 5)
        report "  Files: ${tmp_files:-unknown}"
        # Largest files
        local largest
        largest=$(safe_cmd "find '$user_tmp' -type f -exec ls -lhS {} + 2>/dev/null | head -5" 5)
        if [[ -n "$largest" ]]; then
            report "  Largest files:"
            report "$largest"
        fi
    else
        report "  No /Rtmp data for this user (no temp directory exists)"
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

    # BLAS smoke test
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
    section "6. MEMORY GUARD COVERAGE"

    subsection "Guard Installation Check"
    local guard_check
    guard_check=$(safe_cmd "timeout 15 Rscript --vanilla -e \"
        tryCatch({
            source('$RPROFILE_PATH')
            if (exists('.biome_env') && !is.null(.biome_env\\\$deferred_pkg_init)) try(.biome_env\\\$deferred_pkg_init(), silent=TRUE)
            cat('solve_guard:', isTRUE(attr(base::solve, 'biome_guard')), '\n')
            cat('dist_guard:', isTRUE(attr(stats::dist, 'biome_guard')), '\n')
            cat('outer_guard:', isTRUE(attr(base::outer, 'biome_guard')), '\n')
            cat('expand_grid_guard:', isTRUE(attr(base::expand.grid, 'biome_guard')), '\n')
        }, error = function(e) cat('GUARD_CHECK_FAILED:', e\\\$message, '\n'))
    \" 2>&1" 20)

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
            report "  FIX: Redeploy Rprofile: sudo bash scripts/50_setup_nodes.sh → option 3"
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
    local placeholders
    placeholders=$(safe_cmd "grep -cE '%%[A-Z0-9_]+%%' '$RPROFILE_PATH' 2>/dev/null" 3 | awk 'NR==1 {print $1+0}')
    if [[ -n "$placeholders" && "$placeholders" -gt 0 ]]; then
        report "  $(severity CRITICAL): Found ${placeholders} unsubstituted %%PLACEHOLDERS%% in Rprofile.site!"
        report "  Template was not processed correctly. Redeploy with 50_setup_nodes.sh → option 3."
        safe_cmd "grep -oE '%%[A-Z0-9_]+%%' '$RPROFILE_PATH' 2>/dev/null | head -5" 3 | while IFS= read -r line; do
            report "    $line"
        done
    else
        report "  $(severity OK): No unsubstituted template placeholders"
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
    # Use timeout to prevent hanging on stale NFS
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

    if [[ -n "$orphan_count" && "$orphan_count" -gt 0 ]]; then
        report "  $(severity HIGH): Found ${orphan_count} orphaned R processes (PPID=1)"
        report ""
        safe_cmd "ps -eo pid,ppid,user,rss:10,etime,args 2>/dev/null | awk '\$2 == 1' | grep -E 'Rscript|R --slave|R --no-save|R --no-echo' | sort -k4 -rn | head -10" 5 | while IFS= read -r line; do
            report "  $line"
        done
        report ""
        # Calculate total RSS of orphans
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
        
        # Check required scripts
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

    # Detect auth backend
    if systemctl list-unit-files 2>/dev/null | grep -q "sssd.service"; then
        services+=("sssd")
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "winbind.service"; then
        services+=("winbind")
    fi
    # Telemetry stack
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
}

# =============================================================================
# NEW MODULES: SSL / NGINX / TELEMETRY / RSTUDIO CONFIG / AUTH
# =============================================================================

collect_ssl_status() {
    section "10. SSL CERTIFICATE STATUS"

    # Find active SSL cert path from NGINX config
    local cert_path
    cert_path=$(safe_cmd "grep -rh 'ssl_certificate[^_]' /etc/nginx/snippets/ /etc/nginx/sites-enabled/ 2>/dev/null | grep -v '#' | head -1 | awk '{print \$2}' | tr -d ';'" 5)

    if [[ -z "$cert_path" ]]; then
        # Fallback: check common paths
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

        # Check expiry
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

        # Self-signed detection
        if echo "${cert_issuer:-}" | grep -qi "self.signed\|nginx-selfsigned"; then
            report "  $(severity MEDIUM): Self-signed certificate detected"
            report "  Browsers may show security warnings on first visit"
        fi
    else
        report "  $(severity HIGH): No SSL certificate found!"
        report "  NGINX may be serving plain HTTP or is misconfigured."
    fi

    # Let's Encrypt auto-renewal cron
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
        # Binding address
        local bind_addr
        bind_addr=$(safe_cmd "grep '^www-address=' '$rserver_conf' | cut -d= -f2" 3)
        report "  www-address = ${bind_addr:-not set}"
        if [[ "${bind_addr:-}" != "127.0.0.1" ]]; then
            report "  $(severity HIGH): RStudio should bind to 127.0.0.1 (proxied via NGINX)"
            report "  If bound to 0.0.0.0, RStudio is directly accessible bypassing NGINX auth!"
        else
            report "  $(severity OK): Bound to localhost (behind NGINX proxy)"
        fi

        # Port
        local bind_port
        bind_port=$(safe_cmd "grep '^www-port=' '$rserver_conf' | cut -d= -f2" 3)
        report "  www-port = ${bind_port:-8787}"

        # Frame origin (needed for portal iframe)
        local frame_origin
        frame_origin=$(safe_cmd "grep '^www-frame-origin=' '$rserver_conf' | cut -d= -f2" 3)
        if [[ "${frame_origin:-}" == "same" ]]; then
            report "  $(severity OK): www-frame-origin=same (iframe embedding works)"
        else
            report "  $(severity MEDIUM): www-frame-origin=${frame_origin:-not set} — portal iframe may break"
        fi

        # Encrypt password (should be 0 behind NGINX SSL)
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
# ANALYSIS ENGINE — SYNTHESIZE ALL DATA INTO DIAGNOSIS
# =============================================================================

generate_diagnosis() {
    local target_user="${1:-}"
    local hours="${2:-4}"

    section "10. AUTOMATED DIAGNOSIS"

    local diagnoses=()
    local fixes=()

    # Read back collected data flags
    local has_oom has_sigsegv has_sigill has_orphans has_pthread
    has_oom=$(safe_cmd "dmesg -T 2>/dev/null | grep -ci 'oom\|killed process'" 5 | awk 'NR==1 {print $1+0}')
    has_sigsegv=$(safe_cmd "journalctl -u rstudio-server --since '${hours} hours ago' --no-pager 2>/dev/null | grep -ci 'SIGSEGV\|segv\|signal 11'" 10 | awk 'NR==1 {print $1+0}')
    has_sigill=$(safe_cmd "journalctl -u rstudio-server --since '${hours} hours ago' --no-pager 2>/dev/null | grep -ci 'SIGILL\|signal 4'" 10 | awk 'NR==1 {print $1+0}')
    has_orphans=$(safe_cmd "ps -eo ppid,args 2>/dev/null | awk '\$1 == 1' | grep -cE 'Rscript|R --slave'" 5 | awk 'NR==1 {print $1+0}')
    has_pthread=$(safe_cmd "update-alternatives --display libblas.so.3-x86_64-linux-gnu 2>/dev/null | grep -ci pthread" 5 | awk 'NR==1 {print $1+0}')

    # Diagnosis 1: BLAS crash
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

    # Check for user-specific issues
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
        if [[ "$thread_overrides" -gt 0 ]]; then
            report "  $(severity HIGH) DIAGNOSIS: User has hardcoded thread settings"
            report "    File: ${user_home}/.Renviron"
            report "    IMPACT: Overrides dynamic allocation — can cause thread fan-out"
            report "    FIX: Remove OMP_NUM_THREADS/OPENBLAS_NUM_THREADS from user .Renviron"
            report ""
        fi

        local large_payloads=0
        if [[ -d "${user_home}/.local/share/rstudio/sessions/active" ]]; then
            large_payloads=$(safe_cmd "find '${user_home}/.local/share/rstudio/sessions/active' -type f -size +50M 2>/dev/null | wc -l" 5 | awk 'NR==1 {print $1+0}')
        fi
        
        if [[ "$large_payloads" -gt 0 ]]; then
            report "  $(severity CRITICAL) DIAGNOSIS: Massive Session Payload (Aw, Snap! Error Code 4)"
            report "    CAUSE: The R session suspend file (.env/.RData) is >50MB."
            report "    SYMPTOM: When resuming session, NGINX may drop connection, or browser tab crashes with 'Aw, Snap!' or 'Error Code: 4'"
            report "             (Browser OOM parsing the massive JSON workspace state)."
            report "    FIX: Reset user's session state by clearing the rstudio active session folder:"
            report "         sudo mv ${user_home}/.local/share/rstudio/sessions/active ${user_home}/.local/share/rstudio/sessions/active_backup_\$(date +%s)"
            report ""
        fi
    fi

    # If nothing found
    if [[ "${has_oom:-0}" -eq 0 && "${has_sigsegv:-0}" -eq 0 && "${has_sigill:-0}" -eq 0 && "${has_pthread:-0}" -eq 0 && "${large_payloads:-0}" -eq 0 ]]; then
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
Script:     99_postmortem_forensics.sh
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
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Automated post-mortem crash forensics for BIOME-CALC R sessions."
    echo "Collects all evidence, classifies crash type, checks guard coverage,"
    echo "and produces actionable diagnosis for sysadmin DevOps workflow."
    echo ""
    echo "Options:"
    echo "  --user <username>   Target user to investigate (required unless --all-recent)"
    echo "  --hours <N>         Look back N hours for crash events (default: 4)"
    echo "  --output <file>     Write report to file (also prints to stdout)"
    echo "  --all-recent        Scan all recent crashes (no specific user)"
    echo "  --quick             Skip BLAS smoke test and guard verification (faster)"
    echo "  --incident          Auto-write incident log entry"
    echo "  -h, --help          Display this help"
    echo ""
    echo "Examples:"
    echo "  # Full forensics for a specific user"
    echo "  sudo $0 --user mario.rossi --incident"
    echo ""
    echo "  # Quick scan, last 8 hours, save to file"
    echo "  sudo $0 --user anna.verdi --hours 8 --output /tmp/crash_report.txt --quick"
    echo ""
    echo "  # Scan all recent crashes (no specific user)"
    echo "  sudo $0 --all-recent --hours 2"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    # Pessimistic: require root
    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR" "This script must be run as root (sudo). Forensic data collection requires root access."
        exit 1
    fi

    # Parse arguments
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

    # Validate
    if [[ -z "$TARGET_USER" && "$ALL_RECENT" == false ]]; then
        echo "ERROR: Either --user <username> or --all-recent is required." >&2
        usage
        exit 1
    fi

    # Initialize report file
    if [[ -n "$REPORT_FILE" ]]; then
        mkdir -p "$(dirname "$REPORT_FILE")"
        : > "$REPORT_FILE"  # Truncate/create
    fi

    # Banner
    report "╔═══════════════════════════════════════════════════════════════╗"
    report "║     BIOME-CALC POST-MORTEM FORENSICS v2.0.0                 ║"
    report "║     $(date '+%Y-%m-%d %H:%M:%S')                                    ║"
    if [[ -n "$TARGET_USER" ]]; then
        report "$(printf '║     User: %-50s ║' "$TARGET_USER")"
    fi
    report "$(printf '║     Lookback: %-47s ║' "${HOURS} hours")"
    report "╚═══════════════════════════════════════════════════════════════╝"

    # Execute collection modules
    collect_system_state
    collect_oom_events "$HOURS"
    collect_crash_signals "$HOURS"

    if [[ -n "$TARGET_USER" ]]; then
        collect_user_forensics "$TARGET_USER" "$HOURS"
    fi

    collect_blas_status

    if [[ "$QUICK" == false ]]; then
        collect_guard_status
    else
        report ""
        report "  ⏩ Guard verification skipped (--quick mode)"
    fi

    collect_nfs_status
    collect_orphan_status
    collect_service_status
    collect_ssl_status
    collect_nginx_status
    collect_telemetry_status
    collect_rstudio_config
    collect_auth_status

    # Synthesize diagnosis
    generate_diagnosis "$TARGET_USER" "$HOURS"

    # Incident log
    if [[ "$DO_INCIDENT" == true ]]; then
        write_incident_log "$TARGET_USER" "Automated forensic scan"
    fi

    # Final summary
    section "REPORT COMPLETE"
    report "  Timestamp: $(date -Iseconds)"
    if [[ -n "$REPORT_FILE" ]]; then
        report "  Full report saved to: $REPORT_FILE"
    fi
    report "  Sections collected: 14"
    report "    1-3: System state, OOM, crash signals"
    report "    4: User-specific forensics"
    report "    5-6: BLAS safety, memory guard coverage"
    report "    7-8: NFS storage, orphan processes"
    report "    9: Service status (rstudio, nginx, sssd, telemetry)"
    report "    10: SSL certificate validity"
    report "    11: NGINX config, proxy timeouts, websocket"
    report "    12: Telemetry API health"
    report "    13: RStudio server configuration"
    report "    14: Authentication & Kerberos"
    report ""
    report "  Next steps:"
    report "    1. Review the AUTOMATED DIAGNOSIS section for actionable fixes"
    report "    2. If edge case found: add guard to Rprofile_site.R.template"
    report "    3. If script issue: send user the fix from troubleshooting guide"
    report "    4. If infra issue: apply DevOps fix chain from troubleshooting guide"
    report ""
}

main "$@"
