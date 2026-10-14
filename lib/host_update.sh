#!/usr/bin/env bash
# lib/host_update.sh — shared helpers for in-place host updates and hotfixes.
#
# Implements the mechanics of ADR-0003 once, so update_host.sh and every
# scripts/hotfix/HF-*.sh use the same backup, journal, atomic swap, rollback and
# release record instead of private copies.
#
#   journal   /var/backups/biome-calc/<action>-<UTC>-<pid>/  (0700, root)
#             manifest.tsv  dest  existed  mode  owner  sha_before  sha_after
#             files/<dest>  byte copy of every file before it was replaced
#   release   /etc/biome-calc/release.json  (written with jq, 0644)
#   audit     every action goes to journald: `journalctl -t biome-calc`
#
# Test hooks (never set them on a host): HU_ROOT prefixes every path so the
# whole flow runs inside a mktemp tree; HU_NO_SYSLOG=1 keeps tests out of journald.
set -euo pipefail

: "${HU_ROOT:=}"
: "${HU_BACKUP_ROOT:=/var/backups/biome-calc}"
: "${HU_RELEASE_FILE:=/etc/biome-calc/release.json}"
: "${HU_LOCK_FILE:=/run/lock/biome-calc-update.lock}"
: "${HU_NO_SYSLOG:=0}"

HU_JOURNAL=""          # set by hu_journal_open
HU_CHANGED_COUNT=0     # files actually replaced in this run

if [[ -t 2 ]]; then
    HU_C_RED=$'\e[31m'; HU_C_YEL=$'\e[33m'; HU_C_GRN=$'\e[32m'; HU_C_RST=$'\e[0m'
else
    HU_C_RED=""; HU_C_YEL=""; HU_C_GRN=""; HU_C_RST=""
fi

# hu_log LEVEL MESSAGE... — stderr for the operator, journald for the audit trail.
hu_log() {
    local level="$1"; shift
    local colour="" prio="info"
    case "${level}" in
        ERROR) colour="${HU_C_RED}"; prio="err" ;;
        WARN)  colour="${HU_C_YEL}"; prio="warning" ;;
        OK)    colour="${HU_C_GRN}" ;;
    esac
    printf '%s %s%-5s%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${colour}" "${level}" "${HU_C_RST}" "$*" >&2
    if [[ "${HU_NO_SYSLOG}" != "1" ]] && command -v logger >/dev/null 2>&1; then
        logger -t biome-calc -p "user.${prio}" -- "${level} $*" 2>/dev/null || true
    fi
}

hu_path() { printf '%s%s' "${HU_ROOT}" "$1"; }

hu_sha() { if [[ -e "$1" ]]; then sha256sum "$1" | cut -d' ' -f1; else printf 'absent'; fi; }

# hu_require_cmds CMD... — fail fast with the missing list (rule: assert binaries).
hu_require_cmds() {
    local missing=() c
    for c in "$@"; do command -v "${c}" >/dev/null 2>&1 || missing+=("${c}"); done
    if (( ${#missing[@]} )); then
        hu_log ERROR "missing required commands: ${missing[*]} (apt-get install ${missing[*]})"
        return 1
    fi
}

# hu_lock — one update or hotfix at a time per host. Holds fd 9 until exit.
hu_lock() {
    local lock; lock="$(hu_path "${HU_LOCK_FILE}")"
    mkdir -p "$(dirname "${lock}")"
    exec 9>"${lock}"
    if ! flock -n 9; then
        hu_log ERROR "another update/hotfix holds ${lock}; refusing to run concurrently"
        return 1
    fi
}

# hu_journal_open ACTION — create the journal for this run.
hu_journal_open() {
    local action="$1" base
    base="$(hu_path "${HU_BACKUP_ROOT}")"
    mkdir -p "${base}"
    chmod 0700 "${base}"
    HU_JOURNAL="${base}/${action}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -m 0700 "${HU_JOURNAL}"
    mkdir -m 0700 "${HU_JOURNAL}/files"
    : > "${HU_JOURNAL}/manifest.tsv"
    HU_CHANGED_COUNT=0
    hu_log INFO "journal: ${HU_JOURNAL#"${HU_ROOT}"}"
}

# hu_compare DEST STAGED — 0 identical, 10 differs or DEST absent.
hu_compare() {
    local dest; dest="$(hu_path "$1")"
    [[ -f "${dest}" ]] && cmp -s "${dest}" "$2" && return 0
    return 10
}

# hu_show_diff DEST STAGED — bounded unified diff for --plan / --check output.
hu_show_diff() {
    local dest; dest="$(hu_path "$1")"
    if [[ ! -e "${dest}" ]]; then
        printf '  NEW      %s\n' "$1"
        return 0
    fi
    printf '  CHANGED  %s\n' "$1"
    diff -u --label "deployed:$1" --label "release:$1" "${dest}" "$2" | head -n 80 | sed 's/^/    /' || true
}

# hu_install_file DEST STAGED [DEFAULT_MODE] — back up, atomic swap, record.
# Keeps mode and owner of an existing file; a new file gets DEFAULT_MODE root:root.
# Returns 0 if the file was replaced, 0 with no change if identical.
hu_install_file() {
    local rel="$1" staged="$2" default_mode="${3:-0644}"
    [[ -n "${HU_JOURNAL}" ]] || { hu_log ERROR "hu_install_file called without an open journal"; return 1; }
    local dest; dest="$(hu_path "${rel}")"
    if [[ -f "${dest}" ]] && cmp -s "${dest}" "${staged}"; then
        return 0
    fi
    local existed=0 mode="${default_mode}" owner="0:0" sha_before
    sha_before="$(hu_sha "${dest}")"
    if [[ -e "${dest}" ]]; then
        existed=1
        mode="$(stat -c '%a' "${dest}")"
        owner="$(stat -c '%u:%g' "${dest}")"
        mkdir -p "${HU_JOURNAL}/files$(dirname "${rel}")"
        cp -p "${dest}" "${HU_JOURNAL}/files${rel}"
    fi
    mkdir -p "$(dirname "${dest}")"
    local tmp
    tmp="$(mktemp "$(dirname "${dest}")/.$(basename "${dest}").hu.XXXXXX")"
    cp "${staged}" "${tmp}"
    chmod "${mode}" "${tmp}"
    if [[ "$(id -u)" -eq 0 ]]; then chown "${owner}" "${tmp}"; fi
    mv -f "${tmp}" "${dest}"
    local sha_after; sha_after="$(hu_sha "${dest}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${rel}" "${existed}" "${mode}" "${owner}" "${sha_before}" "${sha_after}" \
        >> "${HU_JOURNAL}/manifest.tsv"
    HU_CHANGED_COUNT=$(( HU_CHANGED_COUNT + 1 ))
    hu_log INFO "replaced ${rel} (${sha_before:0:12} -> ${sha_after:0:12})"
}

# hu_remove_file DEST — journaled removal (hu_rollback puts the file back).
hu_remove_file() {
    local rel="$1" dest
    [[ -n "${HU_JOURNAL}" ]] || { hu_log ERROR "hu_remove_file called without an open journal"; return 1; }
    dest="$(hu_path "${rel}")"
    [[ -e "${dest}" ]] || return 0
    local mode owner sha_before
    mode="$(stat -c '%a' "${dest}")"
    owner="$(stat -c '%u:%g' "${dest}")"
    sha_before="$(hu_sha "${dest}")"
    mkdir -p "${HU_JOURNAL}/files$(dirname "${rel}")"
    cp -p "${dest}" "${HU_JOURNAL}/files${rel}"
    rm -f "${dest}"
    printf '%s\t1\t%s\t%s\t%s\tabsent\n' "${rel}" "${mode}" "${owner}" "${sha_before}" >> "${HU_JOURNAL}/manifest.tsv"
    HU_CHANGED_COUNT=$(( HU_CHANGED_COUNT + 1 ))
    hu_log INFO "removed ${rel} (${sha_before:0:12})"
}

# hu_set_mode PATH MODE — journaled chmod (for hotfixes that fix permissions).
hu_set_mode() {
    local rel="$1" want="$2" p cur
    p="$(hu_path "${rel}")"
    [[ -e "${p}" ]] || { hu_log WARN "hu_set_mode: ${rel} does not exist, skipped"; return 0; }
    cur="$(stat -c '%a' "${p}")"
    [[ "${cur}" == "${want#0}" || "0${cur}" == "${want}" ]] && return 0
    printf '%s\tmode\t%s\t%s\n' "${rel}" "${cur}" "${want}" >> "${HU_JOURNAL}/modes.tsv"
    chmod "${want}" "${p}"
    HU_CHANGED_COUNT=$(( HU_CHANGED_COUNT + 1 ))
    hu_log INFO "mode ${rel}: ${cur} -> ${want}"
}

# hu_rollback JOURNAL — restore every file (or remove files the run created) and
# every mode; verify sha_before. Returns 1 if any file does not match.
hu_rollback() {
    local journal="$1" rc=0 rel existed mode owner sha_before sha_after dest got kind old new
    [[ -f "${journal}/manifest.tsv" ]] || { hu_log ERROR "not a journal: ${journal}"; return 1; }
    hu_log INFO "rollback from ${journal#"${HU_ROOT}"}"
    # Reverse order: the last change is undone first.
    while IFS=$'\t' read -r rel existed mode owner sha_before sha_after; do
        dest="$(hu_path "${rel}")"
        if [[ "${existed}" == "1" ]]; then
            local tmp
            tmp="$(mktemp "$(dirname "${dest}")/.$(basename "${dest}").rb.XXXXXX")"
            cp -p "${journal}/files${rel}" "${tmp}"
            mv -f "${tmp}" "${dest}"
        else
            rm -f "${dest}"
        fi
        got="$(hu_sha "${dest}")"
        if [[ "${got}" != "${sha_before}" ]]; then
            hu_log ERROR "rollback mismatch on ${rel}: expected ${sha_before:0:12}, got ${got:0:12}"
            rc=1
        else
            hu_log INFO "restored ${rel}"
        fi
    done < <(tac "${journal}/manifest.tsv")
    if [[ -f "${journal}/modes.tsv" ]]; then
        while IFS=$'\t' read -r rel kind old new; do
            [[ "${kind}" == "mode" ]] || continue
            chmod "${old}" "$(hu_path "${rel}")" && hu_log INFO "mode ${rel}: ${new} -> ${old}"
        done < <(tac "${journal}/modes.tsv")
    fi
    return "${rc}"
}

# hu_repo_release REPO_DIR — print "<tag>\t<commit>". tag is "untagged" when the
# checkout is not exactly at a release tag (ADR-0003 §1: hosts run releases).
# Local edits under config/ are site data (vars files) and do not make the
# checkout dirty; edits anywhere else (scripts, lib, templates) do.
hu_repo_release() {
    local repo="$1" tag commit
    # safe.directory: root runs this on a checkout that may belong to another user.
    local g=(git -c "safe.directory=${repo}" -C "${repo}")
    commit="$("${g[@]}" rev-parse HEAD 2>/dev/null || echo unknown)"
    tag="$("${g[@]}" describe --tags --exact-match 2>/dev/null || echo untagged)"
    if [[ -n "$("${g[@]}" status --porcelain --untracked-files=no -- . ':(exclude)config' 2>/dev/null)" ]]; then
        tag="${tag}+dirty"
    fi
    printf '%s\t%s\n' "${tag}" "${commit}"
}

# hu_release_record TAG COMMIT COMPONENT — update release.json after an apply.
# Keeps the hotfixes[] history. jq only (rule 16).
hu_release_record() {
    local tag="$1" commit="$2" component="$3" f tmp
    f="$(hu_path "${HU_RELEASE_FILE}")"
    mkdir -p "$(dirname "${f}")"
    [[ -s "${f}" ]] || printf '{}\n' > "${f}"
    tmp="$(mktemp "$(dirname "${f}")/.release.json.XXXXXX")"
    jq --arg tag "${tag}" --arg commit "${commit}" --arg comp "${component}" \
       --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg journal "${HU_JOURNAL#"${HU_ROOT}"}" \
       '.tag=$tag | .commit=$commit | .applied_at=$at | .journal=$journal
        | .components[$comp]={tag:$tag, commit:$commit, applied_at:$at, journal:$journal}
        | .hotfixes=(.hotfixes // [])' "${f}" > "${tmp}"
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${f}"
}

# hu_hotfix_record ID — append or refresh a hotfix entry in release.json.
hu_hotfix_record() {
    local id="$1" f tmp
    f="$(hu_path "${HU_RELEASE_FILE}")"
    mkdir -p "$(dirname "${f}")"
    [[ -s "${f}" ]] || printf '{}\n' > "${f}"
    tmp="$(mktemp "$(dirname "${f}")/.release.json.XXXXXX")"
    jq --arg id "${id}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg journal "${HU_JOURNAL#"${HU_ROOT}"}" \
       '.hotfixes=((.hotfixes // []) | map(select(.id != $id)) + [{id:$id, applied_at:$at, journal:$journal, absorbed_in:null}])' \
       "${f}" > "${tmp}"
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${f}"
}

# hu_release_unrecord JOURNAL COMPONENT — after a rollback, put that component's
# entry of release.json back as it was before the apply of JOURNAL, leaving the
# other components and the hotfix history alone. jq only (rule 16).
hu_release_unrecord() {
    local journal="$1" component="$2" f tmp before="{}" jrel
    f="$(hu_path "${HU_RELEASE_FILE}")"
    [[ -s "${f}" ]] || return 0
    [[ -s "${journal}/release.json.before" ]] && before="$(cat "${journal}/release.json.before")"
    jrel="${journal#"${HU_ROOT}"}"
    tmp="$(mktemp "$(dirname "${f}")/.release.json.XXXXXX")"
    jq --argjson b "${before}" --arg comp "${component}" --arg j "${jrel}" '
        (if ($b.components // {})[$comp] then .components[$comp] = $b.components[$comp]
         else del(.components[$comp]) end)
        | (if .journal == $j then .tag=$b.tag | .commit=$b.commit | .applied_at=$b.applied_at | .journal=$b.journal else . end)' \
        "${f}" > "${tmp}"
    # Nothing left to describe: the host is back to "never updated".
    if jq -e '((.components // {}) | length) == 0 and ((.hotfixes // []) | length) == 0' "${tmp}" >/dev/null; then
        rm -f "${tmp}" "${f}"
        return 0
    fi
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${f}"
}
