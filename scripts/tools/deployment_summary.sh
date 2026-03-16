#!/bin/bash
# ==============================================================================
# deployment_summary.sh - Master post-deployment report for BIOME-CALC nodes.
# Consolidates hardware, R environment, and disk usage into a single report.
#
# DESIGN: Senior Sysadmin Grade - Non-Optimistic, Verbose, Safe.
# ==============================================================================

set -euo pipefail

# --- Configuration ---
BIOME_CONF="/etc/biome-calc"
SCRIPT_PATH="${BIOME_CONF}/script"
TOOLS_PATH="${SCRIPT_PATH}/tools"
REPORT_FILE="/tmp/node_deployment_report_$(hostname)_$(date +%Y%m%d).log"
CONF_FILE="${BIOME_CONF}/conf/r_orphan_cleanup.conf"
TIMEOUT_SEC=60          # Diagnostic step timeout

# --- Logging Helpers ---
log_info() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') \e[32m[INFO]\e[0m $1"; }
log_warn() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') \e[33m[WARN]\e[0m $1"; }
log_error() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') \e[31m[ERROR]\e[0m $1"; }

# --- Dependency Audit (Non-Optimistic) ---
audit_dependencies() {
    log_info "Auditing reporting dependencies..."
    local deps=(lsb_release du find awk grep sed hostname date numfmt)
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Critical dependency missing: $cmd. Aborting."
            exit 1
        fi
    done
    log_info "Dependency audit passed."
}

# --- Diagnostic Wrapper (Safe) ---
run_diagnostic() {
    local phase_name="$1"
    local script_path="$2"
    local grep_filter="${3:-}"
    
    log_info ">>> Starting Phase: ${phase_name}"
    
    if [[ ! -f "$script_path" ]]; then
        log_warn "Diagnostic tool not found: ${script_path}. Skipping ${phase_name}."
        return 0
    fi

    {
        echo -e "\n### ${phase_name^^} ###"
        if [[ -n "$grep_filter" ]]; then
            # Run with timeout and capture filtered output
            timeout "${TIMEOUT_SEC}" "$script_path" 2>/dev/null | grep -E "${grep_filter}" || echo "  (Analysis timed out or returned no matching data)"
        else
            # Run with timeout and capture all output
            timeout "${TIMEOUT_SEC}" "$script_path" 2>/dev/null || echo "  (Analysis timed out or failed)"
        fi
    } >> "$REPORT_FILE" || true
    
    log_info "<<< Phase ${phase_name} complete."
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

audit_dependencies

log_info "Initializing BIOME Master Health Report for $(hostname)..."

# --- Reset Report File ---
{
    echo "================================================================"
    echo "         BIOME-CALC NODE DEPLOYMENT SUMMARY REPORT"
    echo "================================================================"
    echo "  Hostname:     $(hostname)"
    echo "  Date:         $(date)"
    echo "  System:       $(lsb_release -ds)"
    echo "  Kernel:       $(uname -r)"
    echo "================================================================"
} > "$REPORT_FILE"

# --- 1. Integration: Captured Setup Summary (from stdin) ---
if [[ ! -t 0 ]]; then
    log_info "Capturing deployment context from setup script..."
    {
        echo -e "\n### SETUP CONTEXT ###"
        cat
    } >> "$REPORT_FILE"
fi

# --- 2. Hardware Diagnostics ---
run_diagnostic "Hardware" "${TOOLS_PATH}/hw_report.sh" "^(CPU Model|Total RAM|--- Disk|GPU @|--- Interface|Manufacturer|Product Name)"

# --- 3. R Environment & Ecosystem ---
# We use a subshell to CD into the tools dir as R scripts often expect relative paths
log_info ">>> Starting Phase: R Environment"
if [[ -f "${TOOLS_PATH}/check_installed_R_Package.sh" ]]; then
    {
        echo -e "\n### R ENVIRONMENT & ECOSYSTEMS ###"
        (cd "${TOOLS_PATH}" && timeout "${TIMEOUT_SEC}" ./check_installed_R_Package.sh 2>/dev/null) || echo "  (R analysis timed out or failed)"
    } >> "$REPORT_FILE" || true
else
    log_warn "R diagnostic tool not found. Skipping."
fi
log_info "<<< Phase R Environment complete."

# --- 4. Package Config (BLAS/OpenMP) ---
run_diagnostic "Pkg-Config" "${TOOLS_PATH}/check_pkg_config.sh" ""

# --- 5. Storage Usage offenders ---
run_diagnostic "Storage Usage" "${TOOLS_PATH}/bigger_usage_reports.sh" "^[0-9.]+[GT]"

# --- Final Footer ---
{
    echo -e "\n================================================================"
    echo "  Report generated at: $REPORT_FILE"
    echo "  BIOME-CALC Administrative Suite"
    echo "================================================================"
} >> "$REPORT_FILE"

# --- Mailing Logic ---
if [[ "$*" == *"--mail"* ]]; then
    log_info "Proceeding to email delivery..."
    
    if [[ ! -f "${CONF_FILE}" ]]; then
        log_error "Configuration missing: ${CONF_FILE}. Email aborted."
        exit 1
    fi

    log_info "Sourcing project configuration..."
    # shellcheck source=/dev/null
    source "${CONF_FILE}"
    
    HELPERS="${SCRIPT_PATH}/orphan_cleanup_helpers.sh"
    if [[ ! -f "$HELPERS" ]]; then
        log_error "Helpers missing: ${HELPERS}. Email aborted."
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$HELPERS"
    RECIPIENTS=$(resolve_admin_recipients "$ADMIN_EMAIL")
    
    if [[ -z "${RECIPIENTS}" ]]; then
        log_warn "No recipients resolved from ${ADMIN_EMAIL}. Check admin_recipients.txt."
        exit 1
    fi

    log_info "Dispatching email to: ${RECIPIENTS}..."
    
    # Correct mapping for send_email.sh (Short flags required by getopts)
    # Mapping based on send_email.sh.template:
    # -s: SMTP_HOST, -p: SMTP_PORT, -f: SENDER_EMAIL, -T: RECIPIENTS_STRING
    # -u: SUBJECT, -m: MESSAGE_BODY_FILE, -d: DNS_SERVERS_CSV, -L: LOG_PREFIX
    
    # Fallback logic for DNS servers variable name mismatch
    RESOLVED_DNS="${DNS_SERVERS:-${SMTP_DNS_SERVERS:-}}"
    if [[ -z "$RESOLVED_DNS" ]]; then
        log_warn "No DNS servers found in config. Email might fail resolution."
    fi

    if ! "$SEND_EMAIL_SCRIPT" \
        -s "$SMTP_HOST" \
        -p "$SMTP_PORT" \
        -f "$SENDER_EMAIL" \
        -T "$RECIPIENTS" \
        -u "[BIOME-CALC] Node Health Report: $(hostname)" \
        -m "$REPORT_FILE" \
        -d "$RESOLVED_DNS" \
        -L "node-health-report"; then
        
        log_error "Email delivery failed (send_email.sh returned error)."
        exit 1
    fi
    
    log_info "Email dispatched successfully."
fi

# --- Preview Output ---
log_info "Master report generation finished. Previewing report content:"
echo "----------------------------------------------------------------"
cat "$REPORT_FILE"
echo "----------------------------------------------------------------"
log_info "Master Report operation complete."
