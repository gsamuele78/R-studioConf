#!/usr/bin/env bash
# scripts/99_check_pkg_drift.sh
# ============================================================================
# BIOME-CALC — Package Drift Check runner
# ----------------------------------------------------------------------------
# Wraps scripts/tools/r_pkg_drift_detector.R. Intended to be:
#   * run manually by the admin after major CRAN refresh
#   * run weekly by cron/systemd-timer to catch silent drift
#   * run after every sudo apt/install.packages batch
#
# Paradigm: PSE — fail-fast, exit-code-meaningful, no interactive input,
#           baseline stored on local disk (NOT NFS) so it survives home-dir
#           outages and belongs to the sysadmin, not the user.
#
# Usage:
#   sudo ./99_check_pkg_drift.sh                # detect, human report
#   sudo ./99_check_pkg_drift.sh --update       # refresh baseline AFTER review
#   sudo ./99_check_pkg_drift.sh --json=/tmp/drift.json
#   sudo ./99_check_pkg_drift.sh --email        # mail admin on HIGH/MEDIUM
#
# Exit: 0=no drift, 1=drift (MEDIUM/unknown), 2=HIGH risk, 3=internal
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── colors ──
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[1;33m'
CYA=$'\033[0;36m';  BLD=$'\033[1m';    NC=$'\033[0m'

# ── load common utils ──
COMMON_UTILS="${WORKSPACE_ROOT}/lib/common_utils.sh"
if [[ -f "${COMMON_UTILS}" ]]; then
  # shellcheck source=../lib/common_utils.sh disable=SC1091
  source "${COMMON_UTILS}"
fi

# ── defaults (overridable via config/setup_nodes.vars.conf) ──
VARS_CONF="${WORKSPACE_ROOT}/config/setup_nodes.vars.conf"
if [[ -f "${VARS_CONF}" ]]; then
  # shellcheck source=../config/setup_nodes.vars.conf disable=SC1091
  source "${VARS_CONF}"
fi

DRIFT_R="${WORKSPACE_ROOT}/scripts/tools/r_pkg_drift_detector.R"
BASELINE_DIR="${BIOME_STATE_DIR:-/var/lib/biome-calc}"
BASELINE="${BASELINE_DIR}/pkg_baseline.rds"
REPORT_DIR="${BIOME_STATE_DIR:-/var/lib/biome-calc}/drift_reports"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
JSON_OUT="${REPORT_DIR}/drift_${TIMESTAMP}.json"
ADMIN_RECIPIENTS="${WORKSPACE_ROOT}/config/admin_recipients.txt"

UPDATE_BASELINE=false
SEND_EMAIL=false
EXTRA_JSON=""

# ── args ──
for arg in "$@"; do
  case "$arg" in
    --update)          UPDATE_BASELINE=true ;;
    --email)           SEND_EMAIL=true ;;
    --json=*)          EXTRA_JSON="${arg#--json=}" ;;
    --help|-h)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      printf "%s[ERROR]%s Unknown arg: %s\n" "$RED" "$NC" "$arg" >&2
      exit 2
      ;;
  esac
done

# ── sanity checks (fail-fast) ──
if [[ ! -f "${DRIFT_R}" ]]; then
  printf "%s[ERROR]%s Missing: %s\n" "$RED" "$NC" "${DRIFT_R}" >&2
  exit 3
fi

if ! command -v Rscript >/dev/null 2>&1; then
  printf "%s[ERROR]%s Rscript not found (R not installed?)\n" "$RED" "$NC" >&2
  exit 3
fi

# ── ensure state dirs exist and are owned by root ──
if ! mkdir -p "${BASELINE_DIR}" "${REPORT_DIR}"; then
  printf "%s[ERROR]%s Could not create state dirs under %s\n" \
    "$RED" "$NC" "${BASELINE_DIR}" >&2
  exit 3
fi
chmod 755 "${BASELINE_DIR}" "${REPORT_DIR}" || {
  printf "%s[ERROR]%s chmod failed on %s\n" "$RED" "$NC" "${BASELINE_DIR}" >&2
  exit 1
}

printf "%s%s==============================================================%s\n" \
  "$BLD" "$CYA" "$NC"
printf "%s BIOME-CALC — Package Drift Check%s\n" "$BLD" "$NC"
printf "%s==============================================================%s\n" \
  "$CYA" "$NC"
printf "  Baseline : %s\n" "${BASELINE}"
printf "  JSON out : %s\n" "${JSON_OUT}"
printf "  Update   : %s\n" "${UPDATE_BASELINE}"
printf "  Email    : %s\n" "${SEND_EMAIL}"
printf "\n"

# ── run detector ──
RSCRIPT_ARGS=(
  --no-site-file --no-init-file
  "${DRIFT_R}"
  "--baseline=${BASELINE}"
  "--json=${JSON_OUT}"
)
if [[ "${UPDATE_BASELINE}" == true ]]; then
  RSCRIPT_ARGS+=(--update-baseline)
fi

set +e
Rscript "${RSCRIPT_ARGS[@]}"
EXIT_CODE=$?
set -e

# ── copy JSON if --json= was passed ──
if [[ -n "${EXTRA_JSON}" && -f "${JSON_OUT}" ]]; then
  cp "${JSON_OUT}" "${EXTRA_JSON}"
  printf "%s[INFO]%s JSON copied to: %s\n" "$CYA" "$NC" "${EXTRA_JSON}"
fi

# ── email admin on HIGH/MEDIUM drift ──
if [[ "${SEND_EMAIL}" == true ]] && [[ "${EXIT_CODE}" -ge 1 ]]; then
  if [[ ! -f "${ADMIN_RECIPIENTS}" ]]; then
    printf "%s[WARN]%s No recipients file at %s — skipping email\n" \
      "$YEL" "$NC" "${ADMIN_RECIPIENTS}"
  elif ! command -v mail >/dev/null 2>&1; then
    printf "%s[WARN]%s mail(1) not installed — skipping email\n" "$YEL" "$NC"
  else
    SUBJ="[BIOME-DRIFT] exit=${EXIT_CODE} host=$(hostname -s) ts=${TIMESTAMP}"
    BODY=$(cat <<EOF
BIOME-CALC package drift detector reports exit code ${EXIT_CODE}.

Host:      $(hostname -f)
Baseline:  ${BASELINE}
JSON:      ${JSON_OUT}
Timestamp: ${TIMESTAMP}

Exit codes:
  0 = no drift
  1 = drift (MEDIUM / unknown) — review recommended
  2 = HIGH risk — extend /etc/R/Rprofile_site.d/50_pkg_hooks.R

Full report attached (JSON).

This is an automated message. Do not reply.
EOF
)
    # jq used to keep the JSON attachment valid (PSE hard rule 12)
    if command -v jq >/dev/null 2>&1 && [[ -f "${JSON_OUT}" ]]; then
      jq '.' "${JSON_OUT}" >/dev/null 2>&1 || {
        printf "%s[WARN]%s JSON report is invalid — emailing without attachment\n" \
          "$YEL" "$NC"
      }
    fi
    while IFS= read -r rcpt; do
      [[ -z "${rcpt}" || "${rcpt}" =~ ^# ]] && continue
      if [[ -f "${JSON_OUT}" ]]; then
        printf "%s" "${BODY}" | mail -s "${SUBJ}" -A "${JSON_OUT}" "${rcpt}" \
          && printf "  mailed: %s\n" "${rcpt}" \
          || printf "%s[WARN]%s mail failed for %s\n" "$YEL" "$NC" "${rcpt}"
      else
        printf "%s" "${BODY}" | mail -s "${SUBJ}" "${rcpt}" \
          && printf "  mailed: %s\n" "${rcpt}" \
          || printf "%s[WARN]%s mail failed for %s\n" "$YEL" "$NC" "${rcpt}"
      fi
    done <"${ADMIN_RECIPIENTS}"
  fi
fi

# ── prune old reports (keep 30 days) ──
find "${REPORT_DIR}" -maxdepth 1 -name 'drift_*.json' -mtime +30 \
  -print -delete 2>/dev/null || true

case "${EXIT_CODE}" in
  0) printf "\n%s[OK]%s No drift.\n" "$GREEN" "$NC" ;;
  1) printf "\n%s[DRIFT]%s MEDIUM / unknown packages found.\n" "$YEL" "$NC" ;;
  2) printf "\n%s[HIGH]%s HIGH-risk packages found — extend 50_pkg_hooks.R.\n" \
       "$RED" "$NC" ;;
  *) printf "\n%s[ERROR]%s Detector failed (exit=%d).\n" "$RED" "$NC" "${EXIT_CODE}" ;;
esac

exit "${EXIT_CODE}"
