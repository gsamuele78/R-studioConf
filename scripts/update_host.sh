#!/usr/bin/env bash
set -euo pipefail
# scripts/update_host.sh — update a live T1 host in place, without reinstalling.
#
# ADR-0003. Read-only by default. Renders the managed files from THIS checkout
# with the same render functions the installer uses, compares them with what is
# deployed, and only on --apply replaces them: backup + journal, atomic swap,
# validator BEFORE the service reloads, automatic restore if the validator fails.
#
# Components managed today:
#   nginx   /etc/nginx/templates/*.conf + sites-available/<domain>.conf
#           validator: nginx -t   service action: systemctl reload nginx
#           (replaces scripts/update_nginx_templates.sh, which had no backup,
#            left a broken config on disk, and restarted rstudio-server)
# Out of scope until each has a validator and a VM test: SSSD, Samba, PAM, Kerberos.
#
# Usage:
#   sudo scripts/update_host.sh                      # same as --plan
#   sudo scripts/update_host.sh --plan  [--component nginx]
#   sudo scripts/update_host.sh --apply [--component nginx] [--allow-untagged]
#   sudo scripts/update_host.sh --rollback /var/backups/biome-calc/update-...
#   sudo scripts/update_host.sh --status
#
# Exit: 0 nothing to do / applied | 10 changes pending (--plan) | 1 failure
#       (on --apply the previous files are back in place) | 2 usage | 3 precondition

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_RST=""
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/templates"
readonly SCRIPT_DIR REPO_ROOT TEMPLATE_DIR

MODE="plan"
COMPONENT="nginx"
ROLLBACK_DIR=""
ALLOW_UNTAGGED=0
NGINX_VARS="${REPO_ROOT}/config/install_nginx.vars.conf"
RSTUDIO_VARS="${REPO_ROOT}/config/configure_rstudio.vars.conf"

# Test hooks (see lib/host_update.sh). On a host these stay at their defaults.
: "${HU_NGINX_BIN:=nginx}"
: "${HU_SYSTEMCTL_BIN:=systemctl}"
: "${HU_SKIP_ROOT_CHECK:=0}"

usage() { sed -n '2,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

while (( $# )); do
    case "$1" in
        --plan)            MODE="plan" ;;
        --apply)           MODE="apply" ;;
        --status)          MODE="status" ;;
        --rollback)        MODE="rollback"; ROLLBACK_DIR="${2:-}"; shift ;;
        --component)       COMPONENT="${2:-}"; shift ;;
        --nginx-vars)      NGINX_VARS="${2:-}"; shift ;;
        --allow-untagged)  ALLOW_UNTAGGED=1 ;;
        -h|--help)         usage ;;
        *) printf '%sunknown argument: %s%s\n' "${C_RED}" "$1" "${C_RST}" >&2; usage ;;
    esac
    shift
done

[[ "${COMPONENT}" == "nginx" ]] || { printf '%sunknown component: %s (managed: nginx)%s\n' "${C_RED}" "${COMPONENT}" "${C_RST}" >&2; exit 2; }

# common_utils must not write to /var/log during a plan run as non-root tests.
export LOG_FILE="${LOG_FILE:-${HU_ROOT:-}/var/log/biome-log/update_host.log}"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || export LOG_FILE=/dev/null
# shellcheck source=../lib/common_utils.sh disable=SC1091
source "${REPO_ROOT}/lib/common_utils.sh"
# shellcheck source=../lib/host_update.sh disable=SC1091
source "${REPO_ROOT}/lib/host_update.sh"
# shellcheck source=../lib/render_nginx.sh disable=SC1091
source "${REPO_ROOT}/lib/render_nginx.sh"

if [[ "${HU_SKIP_ROOT_CHECK}" != "1" && "$(id -u)" -ne 0 ]]; then
    hu_log ERROR "must run as root (reads deployed config, writes /etc on --apply)"
    exit 3
fi
hu_require_cmds jq flock sha256sum diff cmp git || exit 3

# --- status ---------------------------------------------------------------------
if [[ "${MODE}" == "status" ]]; then
    f="$(hu_path "${HU_RELEASE_FILE}")"
    if [[ -s "${f}" ]]; then jq . "${f}"; else hu_log WARN "no ${HU_RELEASE_FILE}: this host was never updated with update_host.sh"; fi
    exit 0
fi

# --- rollback -------------------------------------------------------------------
if [[ "${MODE}" == "rollback" ]]; then
    [[ -n "${ROLLBACK_DIR}" && -d "$(hu_path "${ROLLBACK_DIR}")" ]] || { hu_log ERROR "--rollback needs an existing journal directory"; exit 2; }
    hu_lock || exit 3
    rc=0
    jdir="$(hu_path "${ROLLBACK_DIR}")"
    hu_rollback "${jdir}" || rc=1
    # Put back the release record as it was before that apply.
    if [[ -f "${jdir}/release.json.before" ]]; then
        cp -p "${jdir}/release.json.before" "$(hu_path "${HU_RELEASE_FILE}")"
    elif [[ -f "${jdir}/release.json.absent" ]]; then
        rm -f "$(hu_path "${HU_RELEASE_FILE}")"
    fi
    if "${HU_NGINX_BIN}" -t >/dev/null 2>&1; then
        "${HU_SYSTEMCTL_BIN}" reload nginx
        hu_log OK "rollback done, nginx reloaded"
    else
        hu_log ERROR "nginx -t fails AFTER rollback: nginx NOT reloaded, the running config is still the old one. Investigate before any restart."
        rc=1
    fi
    exit "${rc}"
fi

# --- render (plan and apply share this) -------------------------------------------
[[ -f "${NGINX_VARS}" ]] || { hu_log ERROR "nginx vars not found: ${NGINX_VARS}"; exit 3; }
# Same as the installer and the old updater: the vars file is shell (T1 config).
# shellcheck disable=SC1090
source "${NGINX_VARS}"
IFS=$'\t' read -r CERT_FULLPATH KEY_FULLPATH < <(nginx_cert_paths) || exit 3

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
render_nginx_bundle "${TEMPLATE_DIR}" "${STAGE}" "${RSTUDIO_VARS}" "${CERT_FULLPATH}" "${KEY_FULLPATH}" || { hu_log ERROR "render failed — nothing touched"; exit 1; }

mapfile -t TARGETS < <(cd "${STAGE}" && find . -type f | sed 's|^\.||' | sort)
IFS=$'\t' read -r REL_TAG REL_COMMIT < <(hu_repo_release "${REPO_ROOT}")

pending=0
printf '\nupdate_host.sh — component %s — checkout %s (%s)\n\n' "${COMPONENT}" "${REL_TAG}" "${REL_COMMIT:0:12}"
for rel in "${TARGETS[@]}"; do
    if hu_compare "${rel}" "${STAGE}${rel}"; then
        printf '  %sOK%s       %s\n' "${C_GRN}" "${C_RST}" "${rel}"
    else
        pending=$(( pending + 1 ))
        hu_show_diff "${rel}" "${STAGE}${rel}"
    fi
done

site_link="$(hu_path "${NGINX_DIR}/sites-enabled/${DOMAIN_OR_IP}.conf")"
if [[ ! -L "${site_link}" && ! -f "${site_link}" ]]; then
    printf '  %sWARN%s     %s is not enabled (installer step 7 not run?). Not managed here.\n' "${C_YEL}" "${C_RST}" "${site_link#"${HU_ROOT}"}"
fi

sessions="unknown"
if command -v rstudio-server >/dev/null 2>&1 && [[ -z "${HU_ROOT}" ]]; then
    if sessions_out="$(rstudio-server active-sessions 2>/dev/null)"; then
        sessions="$(printf '%s\n' "${sessions_out}" | tail -n +2 | grep -c . || true)"
    fi
fi
printf '\n  files to change: %d   service action: %s   rstudio-server: untouched (active sessions: %s)\n\n' \
    "${pending}" "$([[ ${pending} -gt 0 ]] && echo 'nginx -t, then systemctl reload nginx' || echo none)" "${sessions}"

if [[ "${MODE}" == "plan" ]]; then
    hu_log INFO "plan component=${COMPONENT} release=${REL_TAG} commit=${REL_COMMIT} pending=${pending}"
    (( pending == 0 )) && exit 0
    exit 10
fi

# --- apply ----------------------------------------------------------------------
if [[ "${REL_TAG}" == untagged* || "${REL_TAG}" == *+dirty ]]; then
    if (( ALLOW_UNTAGGED )); then
        hu_log WARN "applying from ${REL_TAG} checkout (--allow-untagged): only for the test host"
    else
        hu_log ERROR "checkout is ${REL_TAG}; hosts run release tags (ADR-0003). Check out a tag, or pass --allow-untagged on a test host."
        exit 3
    fi
fi
if (( pending == 0 )); then
    hu_log OK "nothing to apply: host already matches ${REL_TAG}"
    exit 0
fi

hu_lock || exit 3
hu_journal_open "update"
printf '%s\t%s\t%s\n' "${COMPONENT}" "${REL_TAG}" "${REL_COMMIT}" > "${HU_JOURNAL}/release.tsv"

for rel in "${TARGETS[@]}"; do
    hu_install_file "${rel}" "${STAGE}${rel}" 0644
done

# Validator BEFORE the service sees the files: nginx reads them only on reload.
if ! nginx_out="$("${HU_NGINX_BIN}" -t 2>&1)"; then
    hu_log ERROR "nginx -t failed on the new config:"
    printf '%s\n' "${nginx_out}" | sed 's/^/    /' >&2
    if hu_rollback "${HU_JOURNAL}"; then
        hu_log ERROR "previous files restored; nginx was NOT reloaded and keeps serving the old config"
    else
        hu_log ERROR "restore incomplete — see journal ${HU_JOURNAL#"${HU_ROOT}"}; nginx was NOT reloaded"
    fi
    exit 1
fi

if ! "${HU_SYSTEMCTL_BIN}" reload nginx; then
    hu_log ERROR "systemctl reload nginx failed after a passing nginx -t; rolling back"
    hu_rollback "${HU_JOURNAL}" || true
    "${HU_SYSTEMCTL_BIN}" reload nginx || true
    exit 1
fi

if [[ -f "$(hu_path "${HU_RELEASE_FILE}")" ]]; then
    cp -p "$(hu_path "${HU_RELEASE_FILE}")" "${HU_JOURNAL}/release.json.before"
else
    : > "${HU_JOURNAL}/release.json.absent"
fi
hu_release_record "${REL_TAG}" "${REL_COMMIT}" "${COMPONENT}"
hu_log OK "applied component=${COMPONENT} release=${REL_TAG} commit=${REL_COMMIT} files=${HU_CHANGED_COUNT} journal=${HU_JOURNAL#"${HU_ROOT}"}"
printf '\nRollback: sudo %s --rollback %s\n' "${BASH_SOURCE[0]}" "${HU_JOURNAL#"${HU_ROOT}"}"
