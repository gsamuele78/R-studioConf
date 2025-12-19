#!/bin/bash
# 99_health_check.sh - System Health Check Script
# Verifies all services are running, configs are valid, and AD connectivity works
# Version: 1.0.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT_PATH="${SCRIPT_DIR}/../lib/common_utils.sh"

# Source common utilities
if [[ ! -f "$UTILS_SCRIPT_PATH" ]]; then
  echo "ERROR: common_utils.sh not found at $UTILS_SCRIPT_PATH" >&2
  exit 2
fi
source "$UTILS_SCRIPT_PATH"

# =============================================================================
# HEALTH CHECK FUNCTIONS
# =============================================================================

# Check if a service is running
check_service() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        printf "  ✅ %-20s RUNNING\n" "$service"
        return 0
    else
        printf "  ❌ %-20s STOPPED\n" "$service"
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
    if systemctl list-unit-files | grep -q "sssd.service"; then
        services+=("sssd")
    fi
    if systemctl list-unit-files | grep -q "winbind.service"; then
        services+=("winbind")
    fi
    
    for svc in "${services[@]}"; do
        check_service "$svc" || ((failed++))
    done
    
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
                            local expiry_epoch
                            expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
                            local now_epoch
                            now_epoch=$(date +%s)
                            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                            
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
    
    # Check if joined to a domain
    if command -v realm &>/dev/null; then
        local domain
        domain=$(realm list --name-only 2>/dev/null | head -1)
        if [[ -n "$domain" ]]; then
            printf "  ✅ Domain joined: %s\n" "$domain"
            
            # Test DNS resolution
            if host "$domain" &>/dev/null; then
                printf "  ✅ DNS resolution: OK\n"
            else
                printf "  ❌ DNS resolution: FAILED\n"
            fi
            
            # Test Kerberos (if kinit is available)
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
    
    local -a mount_points=("/" "/var" "/home")
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
# MAIN
# =============================================================================

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║            SYSTEM HEALTH CHECK REPORT                     ║"
    echo "║            $(date '+%Y-%m-%d %H:%M:%S')                           ║"
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
    
    echo "════════════════════════════════════════════════════════════"
    echo "Health check complete."
}

main "$@"
