#!/bin/bash
# 99_health_check.sh - System Health Check Script
# Verifies all services are running, configs are valid, and AD connectivity works.
# Extended with BIOME-CALC v11.0 Rprofile + audit v28 infrastructure checks.
# Version: 1.1.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"

# Source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
  echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
  exit 2
fi
# shellcheck source=../lib/common_utils.sh disable=SC1091
source "$UTILS_SCRIPT_PATH"

# =============================================================================
# HEALTH CHECK FUNCTIONS
# =============================================================================

# Check if a service is running
check_service() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        printf "  ✅ %-30s RUNNING\n" "$service"
        return 0
    else
        printf "  ❌ %-30s STOPPED\n" "$service"
        return 1
    fi
}

# Check services
check_services() {
    log "INFO" "=== Checking Services ==="
    local failed=0

    # Core services
    local -a services=("nginx" "rstudio-server")

    # Auth services (check which is configured)
    if systemctl list-unit-files 2>/dev/null | grep -q "sssd.service"; then
        services+=("sssd")
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "winbind.service"; then
        services+=("winbind")
    fi

    # BIOME v11.0: additional services
    if systemctl list-unit-files 2>/dev/null | grep -q "ollama.service"; then
        services+=("ollama")
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "botanical-telemetry.service"; then
        services+=("botanical-telemetry")
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "prometheus-node-exporter.service"; then
        services+=("prometheus-node-exporter")
    fi

    for svc in "${services[@]}"; do
        check_service "$svc" || ((failed++))
    done

    # BIOME orphan-cleanup timer (systemd .timer unit)
    if systemctl list-unit-files 2>/dev/null | grep -q "biome-cleanup-orphans.timer"; then
        if systemctl is-active --quiet biome-cleanup-orphans.timer 2>/dev/null; then
            printf "  ✅ %-30s ACTIVE\n" "biome-cleanup-orphans.timer"
        else
            printf "  ⚠️  %-30s INACTIVE\n" "biome-cleanup-orphans.timer"
            ((failed++))
        fi
    fi

    [[ $failed -eq 0 ]] && return 0 || return 1
}

# Check SSL certificates
check_ssl_certs() {
    log "INFO" "=== Checking SSL Certificates ==="
    local cert_dirs=("/etc/nginx/ssl" "/etc/letsencrypt/live")
    local found_certs=0

    for dir in "${cert_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local certs
            certs=$(find "$dir" -name "*.crt" -o -name "*.pem" 2>/dev/null | head -5)
            if [[ -n "$certs" ]]; then
                while IFS= read -r cert; do
                    if [[ -f "$cert" && "$cert" != *"privkey"* ]]; then
                        local expiry
                        expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
                        if [[ -n "$expiry" ]]; then
                            local expiry_epoch now_epoch days_left
                            expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
                            now_epoch=$(date +%s)
                            days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

                            if [[ $days_left -lt 7 ]]; then
                                printf "  ⚠️  %-40s EXPIRES in %d days!\n" "$(basename "$cert")" "$days_left"
                            elif [[ $days_left -lt 30 ]]; then
                                printf "  🔶 %-40s Expires in %d days\n" "$(basename "$cert")" "$days_left"
                            else
                                printf "  ✅ %-40s Valid (%d days)\n" "$(basename "$cert")" "$days_left"
                            fi
                            ((found_certs++))
                        fi
                    fi
                done <<< "$certs"
            fi
        fi
    done

    if [[ $found_certs -eq 0 ]]; then
        printf "  ⚠️  No SSL certificates found\n"
    fi
    return 0
}

# Check AD connectivity
check_ad_connectivity() {
    log "INFO" "=== Checking AD Connectivity ==="

    if command -v realm &>/dev/null; then
        local domain
        domain=$(realm list --name-only 2>/dev/null | head -1)
        if [[ -n "$domain" ]]; then
            printf "  ✅ Domain joined: %s\n" "$domain"

            if host "$domain" &>/dev/null; then
                printf "  ✅ DNS resolution: OK\n"
            else
                printf "  ❌ DNS resolution: FAILED\n"
            fi

            if [[ -f /etc/krb5.keytab ]]; then
                printf "  ✅ Kerberos keytab: Present\n"
            else
                printf "  ⚠️  Kerberos keytab: Missing\n"
            fi
        else
            printf "  ⚠️  Not joined to any domain\n"
        fi
    else
        printf "  ⚠️  realm command not found\n"
    fi
    return 0
}

# Check Nginx configuration
check_nginx_config() {
    log "INFO" "=== Checking Nginx Configuration ==="

    if command -v nginx &>/dev/null; then
        if nginx -t 2>&1 | grep -q "syntax is ok"; then
            printf "  ✅ Nginx config syntax: OK\n"
        else
            printf "  ❌ Nginx config syntax: INVALID\n"
            nginx -t 2>&1 | head -5
            return 1
        fi
    else
        printf "  ⚠️  Nginx not installed\n"
    fi
    return 0
}

# Check disk space
check_disk_space() {
    log "INFO" "=== Checking Disk Space ==="

    # Include /Rtmp (v11.0 local disk) if present
    local -a mount_points=("/" "/var" "/home")
    if mountpoint -q /Rtmp 2>/dev/null; then
        mount_points+=("/Rtmp")
    fi

    for mp in "${mount_points[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null || [[ "$mp" == "/" ]]; then
            local used_pct
            used_pct=$(df "$mp" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
            if [[ -n "$used_pct" ]]; then
                if [[ $used_pct -ge 90 ]]; then
                    printf "  ❌ %-10s %3d%% used (CRITICAL)\n" "$mp" "$used_pct"
                elif [[ $used_pct -ge 80 ]]; then
                    printf "  ⚠️  %-10s %3d%% used (WARNING)\n" "$mp" "$used_pct"
                else
                    printf "  ✅ %-10s %3d%% used\n" "$mp" "$used_pct"
                fi
            fi
        fi
    done
    return 0
}

# Check time synchronization
check_time_sync() {
    log "INFO" "=== Checking Time Synchronization ==="

    local sync_status
    sync_status=$(timedatectl status 2>/dev/null | grep -i "synchronized" | awk '{print $NF}')
    if [[ "$sync_status" == "yes" ]]; then
        printf "  ✅ System clock synchronized\n"
    else
        printf "  ⚠️  System clock NOT synchronized\n"
    fi
    return 0
}

# =============================================================================
# BIOME-CALC v11.0 INFRASTRUCTURE CHECKS (new in v1.1.0)
# =============================================================================

# Check /Rtmp is a real local disk (not tmpfs, not missing)
check_biome_rtmp() {
    log "INFO" "=== Checking /Rtmp Local Disk (v11.0) ==="

    if ! mountpoint -q /Rtmp 2>/dev/null && ! [[ -d /Rtmp ]]; then
        printf "  ❌ /Rtmp not present (v11.0 requires dedicated local disk)\n"
        return 1
    fi

    local fs_type
    fs_type=$(df -T /Rtmp 2>/dev/null | awk 'NR==2 {print $2}')
    if [[ "$fs_type" == "tmpfs" ]]; then
        printf "  ❌ /Rtmp is TMPFS — v11.0 requires ext4/xfs (eats RAM, guards misfire)\n"
        return 1
    fi
    printf "  ✅ /Rtmp filesystem: %s\n" "$fs_type"

    # Sticky bit (1777 for multi-user tmp)
    local perms
    perms=$(stat -c '%a' /Rtmp 2>/dev/null || echo "unknown")
    if [[ "$perms" == "1777" ]]; then
        printf "  ✅ /Rtmp permissions: 1777 (sticky, world-writable)\n"
    else
        printf "  ⚠️  /Rtmp permissions: %s (expected 1777)\n" "$perms"
    fi

    # Size sanity check
    local size_gb
    size_gb=$(df -BG /Rtmp 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $2}')
    if [[ -n "$size_gb" && "$size_gb" -lt 100 ]]; then
        printf "  ⚠️  /Rtmp only %s GB (recommended 400 GB)\n" "$size_gb"
    else
        printf "  ✅ /Rtmp size: %s GB\n" "${size_gb:-unknown}"
    fi

    # systemd-tmpfiles cleanup rule
    if [[ -f /etc/tmpfiles.d/biome-rtmp-cleanup.conf ]]; then
        printf "  ✅ systemd-tmpfiles rule: biome-rtmp-cleanup.conf present\n"
    else
        printf "  ⚠️  systemd-tmpfiles rule missing: /etc/tmpfiles.d/biome-rtmp-cleanup.conf\n"
    fi

    return 0
}

# Check Rprofile v11.0 is deployed and syntactically valid
check_biome_rprofile() {
    log "INFO" "=== Checking Rprofile v11.0 ==="

    local rprofile=/etc/R/Rprofile.site
    if [[ ! -f "$rprofile" ]]; then
        printf "  ❌ Rprofile.site not found at %s\n" "$rprofile"
        return 1
    fi

    # Unsubstituted placeholders indicate a template deploy failure
    local placeholders
    placeholders=$(grep -cE '%%[A-Z0-9_]+%%' "$rprofile" 2>/dev/null || echo 0)
    placeholders="${placeholders//[^0-9]/}"
    if [[ -n "$placeholders" && "$placeholders" -gt 0 ]]; then
        printf "  ❌ Rprofile.site contains %s unsubstituted %%PLACEHOLDERS%% (deploy broken)\n" "$placeholders"
        return 1
    fi
    printf "  ✅ Rprofile.site: no template placeholders\n"

    # Syntax check via R parse
    if command -v Rscript &>/dev/null; then
        if Rscript --vanilla -e "parse(file='$rprofile')" &>/dev/null; then
            printf "  ✅ Rprofile.site: R syntax valid\n"
        else
            printf "  ❌ Rprofile.site: R syntax INVALID\n"
            return 1
        fi
    fi

    # Version header — v11.0 marker
    if grep -qE 'v11\.0|LOCAL-DISK ARCHITECTURE' "$rprofile"; then
        printf "  ✅ Rprofile version: v11.0 marker found\n"
    elif grep -qE 'v10\.|v9\.' "$rprofile"; then
        local found_ver
        found_ver=$(grep -oE 'v[0-9]+\.[0-9]+' "$rprofile" | head -1)
        printf "  ⚠️  Rprofile version: %s (v11.0 fixes NFS races + top-level return() bug)\n" "$found_ver"
    else
        printf "  ⚠️  Rprofile version: could not detect in header\n"
    fi

    # v11.0 top-level return() bug detection — spawn Rscript with BIOME_WORKER_MODE=1
    # If the body runs, the fix is in place. If Rscript aborts, the bug is present.
    if command -v Rscript &>/dev/null; then
        local marker
        marker=$(mktemp)
        BIOME_WORKER_MODE=1 BIOME_WORKER_THREADS=1 \
            R_PROFILE="$rprofile" \
            Rscript --no-init-file --no-save --no-restore --no-echo \
                -e "cat('ALIVE', file='$marker')" &>/dev/null || true
        if [[ -s "$marker" ]]; then
            printf "  ✅ Worker Rscript survives Rprofile load (return() bug not present)\n"
        else
            printf "  ❌ Worker Rscript aborted during Rprofile load — v10.0 top-level return() BUG PRESENT\n"
            rm -f "$marker"
            return 1
        fi
        rm -f "$marker"
    fi

    return 0
}

# Check BLAS is openblas-serial (not pthread which causes SIGSEGV)
check_biome_blas() {
    log "INFO" "=== Checking OpenBLAS Variant (v11.0 requires serial) ==="

    if ! command -v dpkg &>/dev/null; then
        printf "  ⚠️  dpkg not available — cannot verify BLAS packages\n"
        return 0
    fi

    local has_serial has_pthread
    has_serial=$(dpkg -l libopenblas0-serial 2>/dev/null | grep -c '^ii' || echo 0)
    has_pthread=$(dpkg -l libopenblas0-pthread 2>/dev/null | grep -c '^ii' || echo 0)
    has_serial="${has_serial//[^0-9]/}"
    has_pthread="${has_pthread//[^0-9]/}"

    if [[ "${has_pthread:-0}" -gt 0 ]]; then
        printf "  ❌ libopenblas0-pthread INSTALLED — causes SIGSEGV in RStudio rsession\n"
        printf "      Fix: sudo apt-get remove libopenblas0-pthread && sudo apt-get install libopenblas0-serial\n"
        return 1
    fi
    if [[ "${has_serial:-0}" -eq 0 ]]; then
        printf "  ⚠️  libopenblas0-serial NOT installed — BLAS may default to reference (10-50x slower)\n"
        return 0
    fi
    printf "  ✅ libopenblas0-serial installed, libopenblas0-pthread absent\n"

    # Active BLAS alternative
    if command -v update-alternatives &>/dev/null; then
        local active_blas
        active_blas=$(update-alternatives --display libblas.so.3-x86_64-linux-gnu 2>/dev/null \
                      | grep 'currently points to' | awk '{print $NF}')
        if [[ -n "$active_blas" ]]; then
            if echo "$active_blas" | grep -q "serial"; then
                printf "  ✅ Active BLAS: %s\n" "$(basename "$active_blas")"
            elif echo "$active_blas" | grep -q "pthread"; then
                printf "  ❌ Active BLAS: %s (pthread — SIGSEGV risk)\n" "$(basename "$active_blas")"
                return 1
            else
                printf "  ⚠️  Active BLAS: %s\n" "$(basename "$active_blas")"
            fi
        fi
    fi
    return 0
}

# Check OpenMP infrastructure (libgomp + pkg-config openmp.pc)
check_biome_openmp() {
    log "INFO" "=== Checking OpenMP Infrastructure (v11.0 [N8]) ==="

    # libgomp1 package
    if command -v dpkg &>/dev/null; then
        if dpkg -l libgomp1 2>/dev/null | grep -q '^ii'; then
            printf "  ✅ libgomp1 installed\n"
        else
            printf "  ❌ libgomp1 NOT installed — OpenMP unavailable\n"
            return 1
        fi
    fi

    # Runtime library
    local gomp_count
    gomp_count=$(find /usr/lib/x86_64-linux-gnu -maxdepth 1 -name 'libgomp.so*' 2>/dev/null | wc -l)
    if [[ "${gomp_count:-0}" -gt 0 ]]; then
        printf "  ✅ libgomp.so runtime: %d file(s) in /usr/lib/x86_64-linux-gnu\n" "$gomp_count"
    else
        printf "  ⚠️  libgomp.so.* not found in /usr/lib/x86_64-linux-gnu\n"
    fi

    # Custom openmp.pc deployed by 50_setup_nodes.sh
    if [[ -f /usr/local/lib/pkgconfig/openmp.pc ]]; then
        printf "  ✅ /usr/local/lib/pkgconfig/openmp.pc: present\n"
    else
        printf "  ⚠️  openmp.pc missing (R packages using pkg-config won't find -fopenmp)\n"
    fi

    # pkg-config openmp resolves
    if command -v pkg-config &>/dev/null; then
        local omp_flags
        omp_flags=$(pkg-config --cflags openmp 2>/dev/null || true)
        if echo "$omp_flags" | grep -q -- '-fopenmp'; then
            printf "  ✅ pkg-config --cflags openmp → %s\n" "$omp_flags"
        else
            printf "  ⚠️  pkg-config openmp does not yield -fopenmp\n"
        fi
    fi

    return 0
}

# Check /Rtmp/biome_<user>/ per-user layout and cluster_logs health
check_biome_user_layout() {
    log "INFO" "=== Checking /Rtmp per-user layout (v11.0) ==="

    if ! [[ -d /Rtmp ]]; then
        printf "  ⚠️  /Rtmp missing — skipping per-user check\n"
        return 0
    fi

    local -a biome_dirs
    mapfile -t biome_dirs < <(find /Rtmp -maxdepth 1 -type d -name 'biome_*' 2>/dev/null)
    if [[ ${#biome_dirs[@]} -eq 0 ]]; then
        printf "  ⚠️  No biome_<user> dirs under /Rtmp (no user has triggered Rprofile yet)\n"
        return 0
    fi

    printf "  ✅ Users with /Rtmp init: %d\n" "${#biome_dirs[@]}"

    # v11.0 expected subdirs
    local -a expected=(nimble_compile tmb_compile stan_compile rcpp_cache cluster_logs keras_cache plot_cache)
    local sample_dir="${biome_dirs[0]}"
    local missing=()
    for sub in "${expected[@]}"; do
        if [[ ! -d "$sample_dir/$sub" ]]; then
            missing+=("$sub")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf "  ⚠️  Sample user (%s) missing v11.0 subdirs: %s\n" \
               "$(basename "$sample_dir")" "${missing[*]}"
    else
        printf "  ✅ Sample user has all 7 v11.0 subdirs: %s\n" "$(basename "$sample_dir")"
    fi

    # Recent worker errors across all users
    local recent_errors
    recent_errors=$(find /Rtmp -path '*/cluster_logs/psock_*.log' -mmin -1440 2>/dev/null \
                    | xargs -r grep -l -iE 'error|SIGSEGV|SIGKILL|unserialize' 2>/dev/null \
                    | wc -l)
    recent_errors="${recent_errors//[^0-9]/}"
    if [[ "${recent_errors:-0}" -gt 0 ]]; then
        printf "  ⚠️  %d worker log(s) with errors in last 24h (use biome_worker_diagnostics())\n" "$recent_errors"
    else
        printf "  ✅ No recent worker errors in cluster_logs/\n"
    fi

    return 0
}

check_biome_cgroups() {
    log "INFO" "=== Checking cgroup v2 user slice limits (v12.0) ==="

    # cgroup v2 active?
    local cg_type
    cg_type=$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null)
    if [[ "$cg_type" == "cgroup2fs" ]]; then
        printf "  ✅ cgroup v2 active\n"
    else
        printf "  ❌ cgroup v2 NOT active (got: %s)\n" "$cg_type"
        return 1
    fi

    # User slice template deployed?
    if [[ -f /etc/systemd/system/user-.slice.d/50-biome-limits.conf ]]; then
        printf "  ✅ user-.slice template deployed\n"
        # Show effective values
        local mem_high mem_max cpu_weight
        mem_high=$(grep '^MemoryHigh=' /etc/systemd/system/user-.slice.d/50-biome-limits.conf | cut -d= -f2)
        mem_max=$(grep '^MemoryMax=' /etc/systemd/system/user-.slice.d/50-biome-limits.conf | cut -d= -f2)
        cpu_weight=$(grep '^CPUWeight=' /etc/systemd/system/user-.slice.d/50-biome-limits.conf | cut -d= -f2)
        printf "      MemoryHigh=%s, MemoryMax=%s, CPUWeight=%s\n" "$mem_high" "$mem_max" "$cpu_weight"
        if grep -q '^CPUQuota=' /etc/systemd/system/user-.slice.d/50-biome-limits.conf; then
            printf "  ⚠️  CPUQuota present — defeats dynamic fair-share\n"
        fi
        # v12.4: LimitSTACK does NOT belong in user-.slice (slice manages cgroups, not RLIMITs).
        # Stale presence here means the deployment was done before the v12.4 fix.
        if grep -q '^LimitSTACK=' /etc/systemd/system/user-.slice.d/50-biome-limits.conf; then
            printf "  ⚠️  Stale LimitSTACK in user-.slice (ignored by systemd) — re-run Step 11A to update\n"
        fi
    else
        printf "  ❌ user-.slice template NOT deployed\n"
        printf "      Run: sudo bash scripts/50_setup_nodes.sh, option C\n"
    fi

    # RStudio Server stack limit (v12.4 — geospatial guard)
    if [[ -f /etc/systemd/system/rstudio-server.service.d/50-biome-stack.conf ]]; then
        if grep -q '^LimitSTACK=33554432' /etc/systemd/system/rstudio-server.service.d/50-biome-stack.conf; then
            printf "  ✅ rstudio-server LimitSTACK=33554432 (32 MB)\n"
        else
            printf "  ⚠️  rstudio-server stack drop-in present but LimitSTACK mismatch\n"
        fi
    else
        printf "  ⚠️  rstudio-server stack drop-in missing — geospatial C stack errors likely\n"
        printf "      Run: sudo bash scripts/50_setup_nodes.sh, option 8\n"
    fi

    # System slice protection?
    if [[ -f /etc/systemd/system/system.slice.d/50-biome-reserve.conf ]]; then
        local sys_min
        sys_min=$(cat /sys/fs/cgroup/system.slice/memory.min 2>/dev/null)
        if [[ -n "$sys_min" && "$sys_min" -gt 0 ]]; then
            printf "  ✅ system.slice protected: %d GB floor\n" "$((sys_min / 1024 / 1024 / 1024))"
        else
            printf "  ⚠️  system.slice memory.min is 0 — services unprotected\n"
        fi
    else
        printf "  ❌ system.slice protection NOT deployed\n"
    fi

    # Live status — show top 3 user slices by memory
    local user_slices
    user_slices=$(systemctl list-units --type=slice --no-legend 2>/dev/null | awk '/user-[0-9]+\.slice/ {print $1}')
    if [[ -n "$user_slices" ]]; then
        printf "  ── Active user slices ──\n"
        while IFS= read -r slice; do
            [[ -z "$slice" ]] && continue
            local uid user mem_current
            uid=$(echo "$slice" | sed 's/user-//;s/.slice//')
            user=$(getent passwd "$uid" | cut -d: -f1)
            mem_current=$(cat "/sys/fs/cgroup/user.slice/${slice}/memory.current" 2>/dev/null)
            if [[ -n "$mem_current" ]]; then
                printf "      %-20s using %d GB\n" "${user:-uid=$uid}" "$((mem_current / 1024 / 1024 / 1024))"
            fi
        done <<< "$user_slices"
    else
        printf "  ── No active user sessions ──\n"
    fi

    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║            SYSTEM HEALTH CHECK REPORT                      ║"
    echo "║            $(date '+%Y-%m-%d %H:%M:%S')                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    check_services
    echo ""
    check_nginx_config
    echo ""
    check_ssl_certs
    echo ""
    check_ad_connectivity
    echo ""
    check_disk_space
    echo ""
    check_time_sync
    echo ""
    check_biome_rtmp
    echo ""
    check_biome_rprofile
    echo ""
    check_biome_blas
    echo ""
    check_biome_openmp
    echo ""
    check_biome_user_layout
    echo ""
    check_biome_cgroups
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "Health check complete."
}

main "$@"
