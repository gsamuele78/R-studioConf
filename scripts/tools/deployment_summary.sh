#!/bin/bash
# ==============================================================================
# deployment_summary.sh - Master post-deployment report for BIOME-CALC nodes.
# Consolidates hardware, R environment, and disk usage into a single report.
# ==============================================================================

set -euo pipefail

# --- Configuration ---
# Source setup vars if possible
BIOME_CONF="/etc/biome-calc"
SCRIPT_PATH="/etc/biome-calc/script"
TOOLS_PATH="${SCRIPT_PATH}/tools"
REPORT_FILE="/tmp/node_deployment_report_$(hostname)_$(date +%Y%m%d).log"
CONF_FILE="${BIOME_CONF}/conf/r_orphan_cleanup.conf"

log() { echo -e "\e[32m[INFO]\e[0m $1"; }

# --- Header ---
{
    echo "================================================================"
    echo "         BIOME-CALC NODE DEPLOYMENT SUMMARY REPORT"
    echo "================================================================"
    echo "  Hostname:     $(hostname)"
    echo "  Date:         $(date)"
    echo "  System:       $(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
    echo "================================================================"
} > "$REPORT_FILE"

# --- 1. Integration: Captured Setup Summary ---
# (Optionally passed via pipe or extracted from log)
if [[ ! -t 0 ]]; then
    echo -e "\n### SETUP LOG SUMMARY ###" >> "$REPORT_FILE"
    cat >> "$REPORT_FILE"
fi

# --- 2. Hardware Snapshot ---
if [[ -f "${TOOLS_PATH}/hw_report.sh" ]]; then
    echo -e "\n### HARDWARE DIAGNOSTICS ###" >> "$REPORT_FILE"
    # We run it and strip some interactive elements / huge headers
    sudo "${TOOLS_PATH}/hw_report.sh" 2>/dev/null | grep -E "^(CPU Model|Total RAM|--- Disk|GPU @|--- Interface|Manufacturer|Product Name)" >> "$REPORT_FILE" || true
fi

# --- 3. R Environment & Ecosystem ---
if [[ -f "${TOOLS_PATH}/check_installed_R_Package.sh" ]]; then
    echo -e "\n### R ENVIRONMENT & ECOSYSTEMS ###" >> "$REPORT_FILE"
    # Execute the R script via the wrapper
    (cd "${TOOLS_PATH}" && ./check_installed_R_Package.sh) >> "$REPORT_FILE" 2>/dev/null || true
fi

# --- 4. Package Config (BLAS/OpenMP) ---
if [[ -f "${TOOLS_PATH}/check_pkg_config.sh" ]]; then
    echo -e "\n### PKG-CONFIG (BLAS/OpenMP) ###" >> "$REPORT_FILE"
    "${TOOLS_PATH}/check_pkg_config.sh" | grep -v "All done" >> "$REPORT_FILE" || true
fi

# --- 5. Disk Usage offenders ---
if [[ -f "${TOOLS_PATH}/bigger_usage_reports.sh" ]]; then
    echo -e "\n### DISK USAGE ALERTS (Threshold 1GB) ###" >> "$REPORT_FILE"
    # We run it with a higher threshold for the summary report
    sudo "${TOOLS_PATH}/bigger_usage_reports.sh" | grep -E "^[0-9.]+[GT]" | head -n 10 >> "$REPORT_FILE" || true
fi

# --- Final Footer ---
{
    echo -e "\n================================================================"
    echo "  Report generated at: $REPORT_FILE"
    echo "================================================================"
} >> "$REPORT_FILE"

# --- Mailing Logic ---
if [[ "$*" == *"--mail"* ]]; then
    if [[ -f "${CONF_FILE}" ]]; then
        log "Master report generated. Sending email to administrators..."
        # Extract settings from the orphan cleanup config
        # shellcheck source=/dev/null
        source "${CONF_FILE}"
        
        # Load helpers for recipient resolution
        HELPERS="${SCRIPT_PATH}/orphan_cleanup_helpers.sh"
        if [[ -f "$HELPERS" ]]; then
            # shellcheck source=/dev/null
            source "$HELPERS"
            RECIPIENTS=$(resolve_admin_recipients "$ADMIN_EMAIL")
            
            # Send via our standardized mail script
            # Subject includes [NODE-REPORT] [HOSTNAME]
            "${SEND_EMAIL_SCRIPT}" \
                --to "$RECIPIENTS" \
                --subject "[BIOME-CALC] Deployment Report: $(hostname)" \
                --body "$REPORT_FILE" \
                --from "$SENDER_EMAIL" \
                --server "${SMTP_HOST}:${SMTP_PORT}" \
                --dns "${DNS_SERVERS}"
            
            log "Email sent to: $RECIPIENTS"
        else
             echo "ERROR: Helpers file not found at ${HELPERS}" >&2
        fi
    else
        log "Mailing skipped: Config not found at ${CONF_FILE}"
    fi
fi

# Output preview to stdout
cat "$REPORT_FILE"
