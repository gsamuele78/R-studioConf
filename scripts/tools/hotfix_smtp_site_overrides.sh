#!/usr/bin/env bash
# scripts/tools/hotfix_smtp_site_overrides.sh
# ==============================================================================
# Targeted production hotfix: patches ONLY the 6 sensitive mail/SMTP keys
# (SMTP_HOST, SENDER_EMAIL, MAIL_DOMAIN, MAIL_DOMAINS_USER, SMTP_DNS_SERVERS,
# BIOME_CONTACT — see config/SITE_OVERRIDE.md) into the already-deployed
# /etc/biome-calc/conf/setup_nodes.vars.conf, using the real values from
# config/site/setup_nodes.site.vars.conf.
#
# WHY THIS EXISTS: 50_setup_nodes.sh used to `cp` the committed, sanitized
# setup_nodes.vars.conf straight to /etc/biome-calc/conf/ without folding in
# the site override, so telemetry_api.py (Problem Reporter) always read
# placeholder SMTP_HOST=smtp.example.org and failed with "[Errno -5] No
# address associated with hostname". 50_setup_nodes.sh is fixed to patch this
# on every run — use THIS script when you only need that patch applied to an
# already-running host right now, without re-running the full node setup
# (kernel tuning, R packages, Ollama, cron reinstall, etc.).
#
# No service restart required: telemetry_api.py re-reads this file on every
# /api/v1/report-problem request — it does not cache config at startup.
#
# Usage:
#   sudo ./scripts/tools/hotfix_smtp_site_overrides.sh              (interactive, asks to confirm)
#   sudo ./scripts/tools/hotfix_smtp_site_overrides.sh --dry-run    (show what would change, no writes)
#   sudo ./scripts/tools/hotfix_smtp_site_overrides.sh --yes        (skip confirmation, for automation)
# ==============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
NC='\033[0m'

# --- Resolve script location ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Load common utilities (log(), patch_deployed_mail_overrides()) ---
COMMON_UTILS="${WORKSPACE_ROOT}/lib/common_utils.sh"
if [[ ! -f "${COMMON_UTILS}" ]]; then
  echo -e "${RED}[ERROR]${NC} Missing: ${COMMON_UTILS}" >&2
  exit 1
fi
# shellcheck source=../../lib/common_utils.sh disable=SC1091
source "${COMMON_UTILS}"

DRY_RUN=false
ASSUME_YES=false
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    *)
      log "ERROR" "Unknown argument: ${arg}"
      echo "Usage: $0 [--dry-run] [--yes]" >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  log "ERROR" "Must run as root (target file is root-owned, mode 600). Re-run with sudo."
  exit 1
fi

DEPLOYED_CONF="/etc/biome-calc/conf/setup_nodes.vars.conf"
VARS_CONF="${WORKSPACE_ROOT}/config/setup_nodes.vars.conf"
SITE_VARS_CONF="${WORKSPACE_ROOT}/config/site/setup_nodes.site.vars.conf"

if [[ ! -f "${DEPLOYED_CONF}" ]]; then
  log "ERROR" "Not found: ${DEPLOYED_CONF} — nothing to patch. Has 50_setup_nodes.sh ever run on this host?"
  exit 1
fi
if [[ ! -f "${VARS_CONF}" ]]; then
  log "ERROR" "Missing: ${VARS_CONF}"
  exit 1
fi
if [[ ! -f "${SITE_VARS_CONF}" ]]; then
  log "ERROR" "No site override at ${SITE_VARS_CONF} — nothing real to patch with. See config/SITE_OVERRIDE.md."
  exit 1
fi

# shellcheck source=../../config/setup_nodes.vars.conf disable=SC1091
source "${VARS_CONF}"
# shellcheck source=../../config/site/setup_nodes.site.vars.conf disable=SC1091
source "${SITE_VARS_CONF}"

log "INFO" "Target: ${DEPLOYED_CONF}"
log "INFO" "Will set: SMTP_HOST=${SMTP_HOST}  SENDER_EMAIL=${SENDER_EMAIL}  MAIL_DOMAIN=${MAIL_DOMAIN}"
log "INFO" "          MAIL_DOMAINS_USER=${MAIL_DOMAINS_USER}  SMTP_DNS_SERVERS=${SMTP_DNS_SERVERS}  BIOME_CONTACT=${BIOME_CONTACT}"

if [[ "${DRY_RUN}" == true ]]; then
  log "INFO" "[DRY-RUN] Would patch ${DEPLOYED_CONF} with the values above. No changes made."
  exit 0
fi

if [[ "${ASSUME_YES}" != true ]]; then
  read -rp "Patch ${DEPLOYED_CONF} on $(hostname) now? [type 'yes' to confirm] " confirm
  if [[ "${confirm}" != "yes" ]]; then
    log "WARN" "Aborted by operator."
    exit 1
  fi
fi

patch_deployed_mail_overrides "${DEPLOYED_CONF}" || exit 1

log "INFO" "Done. No service restart needed — telemetry_api.py re-reads this file on every /api/v1/report-problem request."
