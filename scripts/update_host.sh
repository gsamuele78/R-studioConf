#!/usr/bin/env bash
set -euo pipefail
# scripts/update_host.sh — update a live T1 host in place, without reinstalling.
#
# ADR-0003. Read-only by default. Renders the managed files from THIS checkout
# with the same render functions the installer uses, compares them with what is
# deployed, and only on --apply replaces them: backup + journal, atomic swap,
# validator, automatic restore if the validator fails.
#
# Components (--component, default: all, in this order):
#   nginx     /etc/nginx/templates/*.conf + sites-available/<domain>.conf
#             validator: nginx -t (before reload)   service action: systemctl reload nginx
#             (replaces scripts/update_nginx_templates.sh)
#   rprofile  /etc/R/Rprofile.site + /etc/R/Rprofile_site.d/NN_*.R (+ .compiled bundle)
#             = step 8 of 50_setup_nodes.sh without Renviron.site
#             validator: R parse + version check + a staged R start-up as an
#             unprivileged user BEFORE the swap, the same start-up AFTER it
#             service action: none (new R sessions load it; running ones keep the old one)
# Never restarted: rstudio-server. Out of scope until each has a validator and
# a VM test: Renviron.site, SSSD, Samba, PAM, Kerberos.
#
# Usage:
#   sudo scripts/update_host.sh                      # same as --plan
#   sudo scripts/update_host.sh --plan  [--component all|nginx|rprofile]
#   sudo scripts/update_host.sh --apply [--component ...] [--allow-untagged]
#   sudo scripts/update_host.sh --rollback /var/backups/biome-calc/update-...
#   sudo scripts/update_host.sh --status
#
# Exit: 0 nothing to do / applied | 10 changes pending (--plan) | 1 failure
#       (on --apply the previous files of the failing component are back in place)
#       | 2 usage | 3 precondition

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
COMPONENT="all"
ROLLBACK_DIR=""
ALLOW_UNTAGGED=0
NGINX_VARS="${REPO_ROOT}/config/install_nginx.vars.conf"
RSTUDIO_VARS="${REPO_ROOT}/config/configure_rstudio.vars.conf"
SETUP_VARS="${REPO_ROOT}/config/setup_nodes.vars.conf"
SETUP_SITE_VARS="${REPO_ROOT}/config/site/setup_nodes.site.vars.conf"
RPROFILE_MAIN_TEMPLATE="${TEMPLATE_DIR}/Rprofile_site.R.template"
readonly R_FRAG_DIR="/etc/R/Rprofile_site.d"
readonly R_BUNDLE_DIR="${R_FRAG_DIR}/.compiled"

# Test hooks (see lib/host_update.sh). On a host these stay at their defaults.
: "${HU_NGINX_BIN:=nginx}"
: "${HU_SYSTEMCTL_BIN:=systemctl}"
: "${HU_SKIP_ROOT_CHECK:=0}"
HU_R_SMOKE_USER="${HU_R_SMOKE_USER-nobody}"   # R start-up check runs as this user when we are root ("" = test hook: as is)
: "${HU_FRAG_ERR_DIR:=/tmp}"        # where the dispatcher logs fragment errors (biome_frag_errors_<pid>.log)

usage() { sed -n '2,/^#       | 2 usage/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

while (( $# )); do
    case "$1" in
        --plan)            MODE="plan" ;;
        --apply)           MODE="apply" ;;
        --status)          MODE="status" ;;
        --rollback)        MODE="rollback"; ROLLBACK_DIR="${2:-}"; shift ;;
        --component)       COMPONENT="${2:-}"; shift ;;
        --nginx-vars)      NGINX_VARS="${2:-}"; shift ;;
        --setup-vars)      SETUP_VARS="${2:-}"; shift ;;
        --allow-untagged)  ALLOW_UNTAGGED=1 ;;
        -h|--help)         usage ;;
        *) printf '%sunknown argument: %s%s\n' "${C_RED}" "$1" "${C_RST}" >&2; usage ;;
    esac
    shift
done

case "${COMPONENT}" in
    all)            COMPONENTS=(nginx rprofile) ;;
    nginx|rprofile) COMPONENTS=("${COMPONENT}") ;;
    *) printf '%sunknown component: %s (managed: all, nginx, rprofile)%s\n' "${C_RED}" "${COMPONENT}" "${C_RST}" >&2; exit 2 ;;
esac

# common_utils must not write to /var/log during a plan run as non-root tests.
export LOG_FILE="${LOG_FILE:-${HU_ROOT:-}/var/log/biome-log/update_host.log}"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || export LOG_FILE=/dev/null
# shellcheck source=../lib/common_utils.sh disable=SC1091
source "${REPO_ROOT}/lib/common_utils.sh"
# shellcheck source=../lib/host_update.sh disable=SC1091
source "${REPO_ROOT}/lib/host_update.sh"
# shellcheck source=../lib/render_nginx.sh disable=SC1091
source "${REPO_ROOT}/lib/render_nginx.sh"
# shellcheck source=../lib/render_rprofile.sh disable=SC1091
source "${REPO_ROOT}/lib/render_rprofile.sh"

if [[ "${HU_SKIP_ROOT_CHECK}" != "1" && "$(id -u)" -ne 0 ]]; then
    hu_log ERROR "must run as root (reads deployed config, writes /etc on --apply)"
    exit 3
fi
hu_require_cmds jq flock sha256sum md5sum diff cmp git || exit 3

# --- rprofile helpers -------------------------------------------------------------

# rprofile_smoke PROFILE FRAG_DIR DISABLE_BUNDLE — start R the way a user session
# does (site profile + fragments, no user profile) and fail if it does not reach
# the end or the dispatcher logged a fragment error. PROFILE is used as is when
# FRAG_DIR is the deployed one; otherwise a copy pointing at FRAG_DIR is loaded.
rprofile_smoke() {
    local profile="$1" frag_dir="$2" disable_bundle="$3" sdir load out pid errlog n
    sdir="$(mktemp -d)"
    chmod 0755 "${sdir}"
    load="${profile}"
    if [[ "${frag_dir}" != "${R_FRAG_DIR}" ]]; then
        n="$(grep -c "\"${R_FRAG_DIR}\"" "${profile}" || true)"
        if [[ "${n}" != "1" ]]; then
            hu_log ERROR "smoke: ${profile} does not reference \"${R_FRAG_DIR}\" exactly once (found ${n}); cannot test it before the swap"
            rm -rf "${sdir}"; return 1
        fi
        mkdir -m 0755 "${sdir}/frags"
        cp "${frag_dir}"/[0-9][0-9]_*.R "${sdir}/frags/" 2>/dev/null || true
        chmod 0644 "${sdir}/frags/"* 2>/dev/null || true
        sed "s|\"${R_FRAG_DIR}\"|\"${sdir}/frags\"|" "${profile}" > "${sdir}/Rprofile.site"
        chmod 0644 "${sdir}/Rprofile.site"
        load="${sdir}/Rprofile.site"
    fi
    local -a run=(env "HOME=${sdir}" "R_PROFILE=${load}")
    [[ "${disable_bundle}" == "1" ]] && run+=("BIOME_DISABLE_BUNDLE=1")
    if [[ "$(id -u)" -eq 0 && -n "${HU_R_SMOKE_USER}" ]]; then
        run=(runuser -u "${HU_R_SMOKE_USER}" -- "${run[@]}")
    fi
    out="$(cd "${sdir}" && timeout 120 "${run[@]}" "${HU_RSCRIPT_BIN}" --no-init-file -e 'cat("BIOME_SMOKE_OK", Sys.getpid(), "\n")' 2>&1)" || true
    pid="$(sed -n 's/.*BIOME_SMOKE_OK \([0-9][0-9]*\).*/\1/p' <<< "${out}" | head -n 1)"
    rm -rf "${sdir}"
    if [[ -z "${pid}" ]]; then
        hu_log ERROR "smoke: R did not finish start-up with this profile:"
        printf '%s\n' "${out}" | tail -n 20 | sed 's/^/    /' >&2
        return 1
    fi
    errlog="${HU_FRAG_ERR_DIR}/biome_frag_errors_${pid}.log"
    if [[ -s "${errlog}" ]]; then
        hu_log ERROR "smoke: fragments failed at start-up (${errlog}):"
        head -n 20 "${errlog}" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}

# Render step 8 in a subshell: the setup vars must not leak into this shell
# (they set LOG_FILE to the R system log).
render_rprofile_component() {
    local out="$1"
    (
        own_log="${LOG_FILE}"
        # shellcheck disable=SC1090
        source "${SETUP_VARS}"
        # shellcheck disable=SC1090
        [[ -f "${SETUP_SITE_VARS}" ]] && source "${SETUP_SITE_VARS}"
        [[ -z "${BIOME_HOST}" ]] && BIOME_HOST="$(hostname)"
        export RPROFILE_LOG_FILE="${LOG_FILE}"
        LOG_FILE="${own_log}"
        rprofile_render_tree "${RPROFILE_MAIN_TEMPLATE}" "${out}"
        printf '%s\n' "${RPROFILE_VERSION}" > "${out}.version"
    )
}

# Fragments the host has and the release does not: they still load, and the
# bundle covers them, but this tool does not own them.
rprofile_extras() {
    local stage="$1" f
    for f in "$(hu_path "${R_FRAG_DIR}")"/[0-9][0-9]_*.R; do
        [[ -e "${f}" ]] || continue
        [[ -e "${stage}${R_FRAG_DIR}/$(basename "${f}")" ]] || printf '%s\n' "$(basename "${f}")"
    done
}

# 0 = deployed bundle matches the fragment set after this apply, 10 = rebuild needed.
rprofile_bundle_check() {
    local stage="$1" view want
    view="$(mktemp -d)"
    cp -p "$(hu_path "${R_FRAG_DIR}")"/[0-9][0-9]_*.R "${view}/" 2>/dev/null || true
    cp -p "${stage}${R_FRAG_DIR}"/[0-9][0-9]_*.R "${view}/" 2>/dev/null || true
    want="$(rprofile_manifest "${view}")"
    rm -rf "${view}"
    local mf rc; mf="$(hu_path "${R_BUNDLE_DIR}/manifest.txt")"
    rc=10
    if [[ -f "${mf}" && -f "$(hu_path "${R_BUNDLE_DIR}/bundle.Rc")" ]] && [[ "$(cat "${mf}")" == "${want}" ]]; then
        rc=0
    fi
    return "${rc}"
}

# Validation of the staged tree, BEFORE anything is installed.
rprofile_validate_staged() {
    local stage="$1" f want got
    hu_require_cmds "${HU_RSCRIPT_BIN}" timeout || return 1
    if [[ "$(id -u)" -eq 0 && -n "${HU_R_SMOKE_USER}" ]]; then hu_require_cmds runuser || return 1; fi
    for f in "${stage}/etc/R/Rprofile.site" "${stage}${R_FRAG_DIR}"/[0-9][0-9]_*.R; do
        [[ -e "${f}" ]] || continue
        rprofile_parse_check "${f}" || { hu_log ERROR "R parse failed: ${f#"${stage}"}"; return 1; }
    done
    want="$(cat "${stage}.version")"
    got="$(grep -m1 -oP 'VERSION\s*<-\s*"\K[0-9.]+' "${stage}/etc/R/Rprofile.site" || true)"
    if [[ -n "${got}" && "${got}" != "${want}" ]]; then
        hu_log ERROR "version drift: rendered Rprofile.site says ${got}, RPROFILE_VERSION is ${want}"
        return 1
    fi
    rprofile_smoke "${stage}/etc/R/Rprofile.site" "${stage}${R_FRAG_DIR}" 1 || return 1
    hu_log OK "staged R profile v${got:-unknown}: parse OK, start-up OK"
}

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
    jcomp="nginx"
    [[ -f "${jdir}/release.tsv" ]] && jcomp="$(cut -f1 "${jdir}/release.tsv")"
    hu_rollback "${jdir}" || rc=1
    hu_release_unrecord "${jdir}" "${jcomp}"
    case "${jcomp}" in
        nginx)
            if "${HU_NGINX_BIN}" -t >/dev/null 2>&1; then
                "${HU_SYSTEMCTL_BIN}" reload nginx
                hu_log OK "rollback done, nginx reloaded"
            else
                hu_log ERROR "nginx -t fails AFTER rollback: nginx NOT reloaded, the running config is still the old one. Investigate before any restart."
                rc=1
            fi ;;
        rprofile)
            hu_log OK "rollback done: new R sessions load the previous profile; running sessions are not affected" ;;
    esac
    exit "${rc}"
fi

# --- render every requested component (plan and apply share this) ----------------
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGE_ROOT}"' EXIT
IFS=$'\t' read -r REL_TAG REL_COMMIT < <(hu_repo_release "${REPO_ROOT}")
printf '\nupdate_host.sh — checkout %s (%s)\n' "${REL_TAG}" "${REL_COMMIT:0:12}"

declare -A PENDING=()
declare -A BUNDLE_PENDING=()
declare -A TARGET_LIST=()
total=0

for comp in "${COMPONENTS[@]}"; do
    stage="${STAGE_ROOT}/${comp}"
    mkdir -p "${stage}"
    case "${comp}" in
        nginx)
            [[ -f "${NGINX_VARS}" ]] || { hu_log ERROR "nginx vars not found: ${NGINX_VARS}"; exit 3; }
            # Same as the installer and the old updater: the vars file is shell (T1 config).
            # shellcheck disable=SC1090
            source "${NGINX_VARS}"
            IFS=$'\t' read -r CERT_FULLPATH KEY_FULLPATH < <(nginx_cert_paths) || exit 3
            render_nginx_bundle "${TEMPLATE_DIR}" "${stage}" "${RSTUDIO_VARS}" "${CERT_FULLPATH}" "${KEY_FULLPATH}" \
                || { hu_log ERROR "nginx render failed — nothing touched"; exit 1; }
            ;;
        rprofile)
            [[ -f "${SETUP_VARS}" ]] || { hu_log ERROR "setup vars not found: ${SETUP_VARS}"; exit 3; }
            render_rprofile_component "${stage}" || { hu_log ERROR "rprofile render failed — nothing touched"; exit 1; }
            ;;
    esac

    printf '\n[%s]\n' "${comp}"
    TARGET_LIST[${comp}]="$(cd "${stage}" && find . -type f | sed 's|^\.||' | sort)"
    n=0
    while IFS= read -r rel; do
        [[ -n "${rel}" ]] || continue
        if hu_compare "${rel}" "${stage}${rel}"; then
            printf '  %sOK%s       %s\n' "${C_GRN}" "${C_RST}" "${rel}"
        else
            n=$(( n + 1 ))
            hu_show_diff "${rel}" "${stage}${rel}"
        fi
    done <<< "${TARGET_LIST[${comp}]}"

    case "${comp}" in
        nginx)
            site_link="$(hu_path "${NGINX_DIR}/sites-enabled/${DOMAIN_OR_IP}.conf")"
            if [[ ! -L "${site_link}" && ! -f "${site_link}" ]]; then
                printf '  %sWARN%s     %s is not enabled (installer step 7 not run?). Not managed here.\n' "${C_YEL}" "${C_RST}" "${site_link#"${HU_ROOT}"}"
            fi
            action="nginx -t, then systemctl reload nginx"
            ;;
        rprofile)
            while IFS= read -r x; do
                [[ -n "${x}" ]] && printf '  %sEXTRA%s    %s/%s is not in this release: left in place, still loaded\n' "${C_YEL}" "${C_RST}" "${R_FRAG_DIR}" "${x}"
            done < <(rprofile_extras "${stage}")
            BUNDLE_PENDING[${comp}]=0
            if ! rprofile_bundle_check "${stage}"; then
                BUNDLE_PENDING[${comp}]=1
                n=$(( n + 1 ))
                printf '  REBUILD  %s/bundle.Rc + manifest.txt (does not match the fragments)\n' "${R_BUNDLE_DIR}"
            fi
            guard="$(hu_path /Rtmp/biome_thread_guard)"
            if [[ -d "$(hu_path /Rtmp)" && "$(stat -c '%a' "${guard}" 2>/dev/null || echo none)" != "1777" ]]; then
                printf '  %sWARN%s     /Rtmp/biome_thread_guard is not 1777 (installer step 8 creates it). Not managed here.\n' "${C_YEL}" "${C_RST}"
            fi
            action="none (new R sessions load it; running sessions keep the old profile)"
            ;;
    esac
    PENDING[${comp}]="${n}"
    total=$(( total + n ))
    printf '  changes: %d   service action: %s\n' "${n}" "$([[ ${n} -gt 0 ]] && echo "${action}" || echo none)"
done

sessions="unknown"
if command -v rstudio-server >/dev/null 2>&1 && [[ -z "${HU_ROOT}" ]]; then
    if sessions_out="$(rstudio-server active-sessions 2>/dev/null)"; then
        sessions="$(printf '%s\n' "${sessions_out}" | tail -n +2 | grep -c . || true)"
    fi
fi
printf '\n  files to change: %d   rstudio-server: untouched (active sessions: %s)\n\n' "${total}" "${sessions}"

if [[ "${MODE}" == "plan" ]]; then
    hu_log INFO "plan components=${COMPONENTS[*]} release=${REL_TAG} commit=${REL_COMMIT} pending=${total}"
    (( total == 0 )) && exit 0
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
if (( total == 0 )); then
    hu_log OK "nothing to apply: host already matches ${REL_TAG}"
    exit 0
fi

# Validate every staged tree first, so a bad rprofile does not leave nginx half-applied.
for comp in "${COMPONENTS[@]}"; do
    (( PENDING[${comp}] > 0 )) || continue
    if [[ "${comp}" == "rprofile" ]]; then
        rprofile_validate_staged "${STAGE_ROOT}/rprofile" \
            || { hu_log ERROR "rprofile: staged files rejected — nothing touched"; exit 1; }
    fi
done

hu_lock || exit 3

# record_release COMP — journal the previous release.json, then record this apply.
record_release() {
    if [[ -f "$(hu_path "${HU_RELEASE_FILE}")" ]]; then
        cp -p "$(hu_path "${HU_RELEASE_FILE}")" "${HU_JOURNAL}/release.json.before"
    else
        : > "${HU_JOURNAL}/release.json.absent"
    fi
    hu_release_record "${REL_TAG}" "${REL_COMMIT}" "$1"
    hu_log OK "applied component=$1 release=${REL_TAG} commit=${REL_COMMIT} files=${HU_CHANGED_COUNT} journal=${HU_JOURNAL#"${HU_ROOT}"}"
    printf 'Rollback %s: sudo %s --rollback %s\n' "$1" "${BASH_SOURCE[0]}" "${HU_JOURNAL#"${HU_ROOT}"}"
}

for comp in "${COMPONENTS[@]}"; do
    (( PENDING[${comp}] > 0 )) || continue
    stage="${STAGE_ROOT}/${comp}"
    hu_journal_open "update"
    printf '%s\t%s\t%s\n' "${comp}" "${REL_TAG}" "${REL_COMMIT}" > "${HU_JOURNAL}/release.tsv"
    while IFS= read -r rel; do
        [[ -n "${rel}" ]] && hu_install_file "${rel}" "${stage}${rel}" 0644
    done <<< "${TARGET_LIST[${comp}]}"

    case "${comp}" in
        nginx)
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
            ;;
        rprofile)
            if (( BUNDLE_PENDING[${comp}] )); then
                bstage="$(mktemp -d)"
                if rprofile_build_bundle "$(hu_path "${R_FRAG_DIR}")" "${bstage}"; then
                    hu_install_file "${R_BUNDLE_DIR}/bundle.Rc" "${bstage}/bundle.Rc" 0644
                    hu_install_file "${R_BUNDLE_DIR}/manifest.txt" "${bstage}/manifest.txt" 0644
                else
                    # The dispatcher would reject the stale bundle (md5 mismatch) anyway;
                    # removing it makes the per-fragment loop explicit.
                    hu_log WARN "bundle compile failed: removing the stale bundle, sessions use the per-fragment loop ($(tail -n 2 "${bstage}/compile.log" 2>/dev/null | tr '\n' ' '))"
                    hu_remove_file "${R_BUNDLE_DIR}/bundle.Rc"
                    hu_remove_file "${R_BUNDLE_DIR}/manifest.txt"
                fi
                rm -rf "${bstage}"
            fi
            # R reads the files at the next session start: check that start now,
            # with the deployed files and the bundle, as an unprivileged user.
            if ! rprofile_smoke "$(hu_path /etc/R/Rprofile.site)" "$(hu_path "${R_FRAG_DIR}")" 0; then
                if hu_rollback "${HU_JOURNAL}"; then
                    hu_log ERROR "R start-up failed with the deployed profile: previous files restored"
                else
                    hu_log ERROR "R start-up failed AND restore incomplete — see journal ${HU_JOURNAL#"${HU_ROOT}"}"
                fi
                exit 1
            fi
            ;;
    esac
    record_release "${comp}"
done
