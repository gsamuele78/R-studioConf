#!/bin/bash
# ==============================================================================
# manage_r_sessions.sh - Safe session management for BIOME-CALC
# ==============================================================================

set -euo pipefail

log_info() { echo -e "\e[32m[INFO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

# ── Function: Close R Sessions ──
close_r_sessions() {
    log_info "Scanning for active R/rsession processes..."
    # We target both rsession (RStudio) and R (Terminal)
    local pids
    pids=$(pgrep -u "$USER" -f "R|rsession" || true)

    if [[ -z "$pids" ]]; then
        log_info "No active R sessions found for user ${USER}."
        return 0
    fi

    echo "Found PIDs: $pids"
    log_info "Attempting graceful termination (SIGTERM)..."
    # shellcheck disable=SC2086
    kill -15 $pids 2>/dev/null || true
    sleep 2

    # Verify if still alive
    local zombies
    zombies=$(pgrep -u "$USER" -f "R|rsession" || true)
    if [[ -n "$zombies" ]]; then
        log_warn "Force killing remaining sessions (SIGKILL)..."
        # shellcheck disable=SC2086
        kill -9 $zombies 2>/dev/null || true
    fi
    log_info "R sessions cleaned."
}

# ── Function: Server Control ──
control_rstudio() {
    local action="$1"
    if [[ $EUID -ne 0 ]]; then
        log_warn "Sudo required for systemctl. Skipping server $action."
        return 0
    fi

    log_info "Executing: systemctl $action rstudio-server..."
    systemctl "$action" rstudio-server
}

# ── Function: Environment Check ──
check_r_env() {
    log_info "Checking R Session Environment (LD_LIBRARY / BLAS)..."
    Rscript --vanilla -e '
        vars <- c("CFLAGS", "FLIBS", "BLAS_LIBS", "LAPACK_LIBS", "OPENBLAS_CORETYPE", "LD_LIBRARY_PATH")
        for (v in vars) {
            val <- Sys.getenv(v, unset="N/A")
            cat(sprintf("  %-25s: %s\n", v, val))
        }
    '
}

# --- Execution ---
echo "============================================================"
echo "  BIOME-CALC: R Session Manager"
echo "============================================================"

close_r_sessions
check_r_env

# Optional: restart server if root
if [[ $EUID -eq 0 ]]; then
    read -r -p "Restart RStudio Server now? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        control_rstudio "restart"
    fi
fi

echo "Done."
