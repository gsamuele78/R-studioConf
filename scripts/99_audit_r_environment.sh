#!/usr/bin/env bash
# ==============================================================================
# 99_audit_r_environment.sh — BIOME-CALC AUDIT RUNNER
# ==============================================================================
# Deploys the parameterized audit script from templates/ and optionally
# runs it via Rscript, or prints the path for sourcing from RStudio.
#
# Part of: R-studioConf legacy deployment suite
# Depends: lib/common_utils.sh, config/setup_nodes.vars.conf
#          templates/00_audit_v26.R.template
#
# Usage:
#   sudo ./99_audit_r_environment.sh            (deploy + run as root)
#   ./99_audit_r_environment.sh --deploy-only   (deploy, print path)
#   ./99_audit_r_environment.sh --run-only      (run already-deployed audit)
#
# In RStudio console, run the audit interactively:
#   source("/etc/biome-calc/00_audit_v26.R")
#   # or after script runs:
#   status()
#
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Load legacy common utilities ──
COMMON_UTILS="${WORKSPACE_ROOT}/lib/common_utils.sh"
if [[ ! -f "${COMMON_UTILS}" ]]; then
  echo "[ERROR] Missing: ${COMMON_UTILS}" >&2
  exit 1
fi
# shellcheck source=../lib/common_utils.sh
source "${COMMON_UTILS}"

# ── Load configuration ──
VARS_CONF="${WORKSPACE_ROOT}/config/setup_nodes.vars.conf"
if [[ ! -f "${VARS_CONF}" ]]; then
  log_error "Missing config: ${VARS_CONF}"
  exit 1
fi
# shellcheck source=../config/setup_nodes.vars.conf
source "${VARS_CONF}"

AUDIT_TEMPLATE="${WORKSPACE_ROOT}/templates/00_audit_v26.R.template"
AUDIT_DEST="${BIOME_CONF}/00_audit_v26.R"

# ── Args ──
DEPLOY_ONLY=false
RUN_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --deploy-only) DEPLOY_ONLY=true ;;
    --run-only)    RUN_ONLY=true ;;
    --help|-h)
      echo "Usage: $0 [--deploy-only] [--run-only]"
      echo ""
      echo "  (no args)     Deploy audit script from template then run it"
      echo "  --deploy-only Deploy audit script, print path, exit"
      echo "  --run-only    Run the already-deployed audit (skips template step)"
      echo ""
      echo "  In RStudio, run audit interactively:"
      echo "    source(\"${BIOME_CONF}/00_audit_v26.R\")"
      exit 0
      ;;
  esac
done

# ==============================================================================
# DEPLOY AUDIT SCRIPT FROM TEMPLATE
# ==============================================================================
deploy_audit() {
  log_step "Deploying BIOME-CALC Audit Script"

  if [[ ! -f "${AUDIT_TEMPLATE}" ]]; then
    log_error "Missing template: ${AUDIT_TEMPLATE}"
    exit 1
  fi

  mkdir -p "${BIOME_CONF}"

  local ts
  ts=$(date +%Y%m%d_%H%M%S)

  # Backup existing audit if present
  if [[ -f "${AUDIT_DEST}" ]]; then
    backup_file "${AUDIT_DEST}"
    log_info "Backed up: ${AUDIT_DEST}"
  fi

  # Process template (substitutes all %%PLACEHOLDER%% values from vars.conf)
  local tmp_audit="/tmp/00_audit_v26.R.deploy.${ts}"
  process_template "${AUDIT_TEMPLATE}" "${tmp_audit}"
  execute_command cp "${tmp_audit}" "${AUDIT_DEST}"
  rm -f "${tmp_audit}"
  chmod 644 "${AUDIT_DEST}"

  log_success "Audit script deployed: ${AUDIT_DEST}"
  log_info "In RStudio, run: source(\"${AUDIT_DEST}\")"
}

# ==============================================================================
# RUN AUDIT
# ==============================================================================
run_audit_script() {
  log_step "Running BIOME-CALC Audit"

  if [[ ! -f "${AUDIT_DEST}" ]]; then
    log_error "Audit script not found: ${AUDIT_DEST}"
    log_error "Run without --run-only first to deploy the template."
    exit 1
  fi

  if ! command -v Rscript &>/dev/null; then
    log_error "Rscript not found — is R installed?"
    exit 1
  fi

  log_info "Running audit as: $(id -un) (UID=$(id -u))"
  log_info "Audit script: ${AUDIT_DEST}"
  log_info "Note: Some checks (Ollama, NFS I/O) may require root or specific mounts."
  echo ""

  # Run R audit.  Use --vanilla to avoid loading optional user .Rprofile
  # (the audit checks whether the SYSTEM Rprofile was loaded correctly).
  Rscript --no-site-file --no-init-file "${AUDIT_DEST}" 2>&1 || {
    log_warn "Rscript exited non-zero — check the FAIL/WARN output above"
  }
}

# ==============================================================================
# SUMMARY
# ==============================================================================
audit_summary() {
  echo ""
  log_success "============================================"
  log_success "AUDIT COMPLETE"
  log_success "============================================"
  echo ""
  echo "  Deployed audit: ${AUDIT_DEST}"
  echo ""
  echo "  To run the audit from RStudio console:"
  echo "    source(\"${AUDIT_DEST}\")"
  echo ""
  echo "  To run the audit on this machine:"
  echo "    sudo ./99_audit_r_environment.sh"
  echo ""
  echo "  To run from another user (without root):"
  echo "    Rscript --no-site-file --no-init-file \"${AUDIT_DEST}\""
  echo ""
  echo "  Audit log: ~/biome_audit.log (per-user)"
  echo "  System log: ${LOG_FILE}"
}

# ==============================================================================
# MAIN — INTERACTIVE MENU (legacy pattern)
# ==============================================================================
if [[ "${DEPLOY_ONLY}" == true ]]; then
  deploy_audit
  audit_summary
  exit 0
fi

if [[ "${RUN_ONLY}" == true ]]; then
  run_audit_script
  exit 0
fi

# No flags: show menu
echo ""
echo "============================================================"
echo "  BIOME-CALC AUDIT RUNNER"
echo "  Config:  ${BIOME_CONF}"
echo "  LogFile: ${LOG_FILE}"
echo "============================================================"
echo ""
echo "  1) Deploy audit script from template + run it"
echo "  2) Deploy audit script only (for RStudio use)"
echo "  3) Run already-deployed audit"
echo "  Q) Quit"
echo ""

read -r -p "  Selection [1]: " choice
choice="${choice:-1}"
choice="${choice^^}"

case "${choice}" in
  1)
    deploy_audit
    run_audit_script
    audit_summary
    ;;
  2)
    deploy_audit
    audit_summary
    ;;
  3)
    run_audit_script
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
