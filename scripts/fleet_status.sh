#!/usr/bin/env bash
set -euo pipefail
# scripts/fleet_status.sh — are all T1 hosts on the same code? (ADR-0003)
#
# Read-only. For every host in HOSTS_FILE, over ssh + `sudo -n`, it collects:
#   - the commit/tag of the host's own checkout (what update_host.sh would deploy)
#   - `update_host.sh --plan`: how many deployed files differ from that checkout
#     rendered with the host's own config/ values
#   - /etc/biome-calc/release.json: the last apply or installer run, per component
# The rendered files contain host values (BIOME_HOST, VM_VCORES, domain), so a raw
# sha256 cannot be compared across hosts, and the checkout commit alone does not
# prove what is deployed. Verdict "same code" = every host reachable, every
# checkout at the same commit and clean, and every plan at 0 files to change.
#
# Usage:
#   scripts/fleet_status.sh HOSTS_FILE [--component all|nginx|rprofile]
#   HOSTS_FILE: one host per line, optional second column = checkout path on that
#               host (default: $FLEET_REPO_PATH or /home/ladmin/configServices/R-studioConf).
#               '#' starts a comment. Hosts are ssh targets (user@host works).
# Needs: ssh with keys (BatchMode, no prompts), passwordless `sudo -n` for
#        update_host.sh and `cat` on the hosts, jq + base64 locally.
#
# Exit: 0 same code everywhere | 10 hosts differ | 1 a host could not be checked | 2 usage

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_RST=""
fi

# Test hooks (tests/fleet_status_test.sh). On a workstation these stay at their defaults.
: "${FLEET_SSH_BIN:=ssh}"
: "${FLEET_SUDO:=sudo -n}"
: "${FLEET_RELEASE_FILE:=/etc/biome-calc/release.json}"
: "${FLEET_REPO_PATH:=/home/ladmin/configServices/R-studioConf}"
: "${FLEET_CONNECT_TIMEOUT:=10}"

usage() { sed -n '3,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

HOSTS_FILE=""
COMPONENT="all"
while (( $# )); do
    case "$1" in
        --component) COMPONENT="${2:-}"; shift ;;
        -h|--help)   usage ;;
        -*)          printf '%sunknown argument: %s%s\n' "${C_RED}" "$1" "${C_RST}" >&2; usage ;;
        *)           HOSTS_FILE="$1" ;;
    esac
    shift
done
[[ -n "${HOSTS_FILE}" && -r "${HOSTS_FILE}" ]] || { printf '%sHOSTS_FILE missing or unreadable%s\n' "${C_RED}" "${C_RST}" >&2; usage; }
case "${COMPONENT}" in all|nginx|rprofile) ;; *) printf '%sunknown component: %s%s\n' "${C_RED}" "${COMPONENT}" "${C_RST}" >&2; exit 2 ;; esac

missing=()
for c in jq base64 "${FLEET_SSH_BIN}"; do command -v "${c}" >/dev/null 2>&1 || missing+=("${c}"); done
(( ${#missing[@]} == 0 )) || { printf '%smissing required commands: %s%s\n' "${C_RED}" "${missing[*]}" "${C_RST}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# probe HOST REPO — prints the raw answer of one host into TMP/<n>.out
probe() {
    local host="$1" repo="$2" remote
    # Everything on the remote side is quoted with printf %q: paths may contain spaces.
    remote="$(printf 'r=$(%s cat %q 2>/dev/null | base64 -w0); printf "RELEASE %%s\\n" "$r"; ' "${FLEET_SUDO}" "${FLEET_RELEASE_FILE}")"
    remote+="$(printf 'if [ -x %q ]; then %s %q --plan --component %q 2>/dev/null | grep "^UPDATE_HOST_SUMMARY"; else echo NO_UPDATE_HOST; fi' \
        "${repo}/scripts/update_host.sh" "${FLEET_SUDO}" "${repo}/scripts/update_host.sh" "${COMPONENT}")"
    "${FLEET_SSH_BIN}" -o BatchMode=yes -o ConnectTimeout="${FLEET_CONNECT_TIMEOUT}" "${host}" "${remote}"
}

declare -a HOSTS=() REPOS=()
while read -r h r _; do
    [[ -z "${h}" || "${h}" == \#* ]] && continue
    HOSTS+=("${h}"); REPOS+=("${r:-${FLEET_REPO_PATH}}")
done < "${HOSTS_FILE}"
(( ${#HOSTS[@]} )) || { printf '%sno hosts in %s%s\n' "${C_RED}" "${HOSTS_FILE}" "${C_RST}" >&2; exit 2; }

unreachable=0
declare -a COMMITS=()
printf '\n%-24s %-28s %-22s %s\n' "HOST" "CHECKOUT" "PLAN (files to change)" "LAST RECORDED DEPLOY (per component)"
for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"; out="${TMP}/${i}.out"
    if ! probe "${host}" "${REPOS[$i]}" > "${out}" 2> "${TMP}/${i}.err"; then
        printf '%-24s %s%s%s\n' "${host}" "${C_RED}" "UNREACHABLE: $(tail -n 1 "${TMP}/${i}.err")" "${C_RST}"
        unreachable=$(( unreachable + 1 )); COMMITS+=("?"); continue
    fi
    summary="$(grep -m1 '^UPDATE_HOST_SUMMARY' "${out}" || true)"
    rel_b64="$(sed -n 's/^RELEASE //p' "${out}" | head -n 1)"
    last="never recorded"
    if [[ -n "${rel_b64}" ]] && rel="$(base64 -d <<< "${rel_b64}" 2>/dev/null)" && [[ -n "${rel}" ]]; then
        last="$(jq -r '[(.components // {}) | to_entries[]
                 | "\(.key)=\(.value.tag) \(.value.commit[0:12]) \(.value.applied_at) via \(.value.via // "update_host.sh")"]
                 | if length == 0 then "no components" else join("; ") end' <<< "${rel}" 2>/dev/null || echo "release.json unreadable")"
    fi
    if grep -q '^NO_UPDATE_HOST' "${out}"; then
        printf '%-24s %-28s %s%-22s%s %s\n' "${host}" "-" "${C_RED}" "no update_host.sh at ${REPOS[$i]}" "${C_RST}" "${last}"
        unreachable=$(( unreachable + 1 )); COMMITS+=("?"); continue
    fi
    if [[ -z "${summary}" ]]; then
        printf '%-24s %-28s %s%-22s%s %s\n' "${host}" "-" "${C_RED}" "plan failed (sudo -n? vars?)" "${C_RST}" "${last}"
        unreachable=$(( unreachable + 1 )); COMMITS+=("?"); continue
    fi
    tag="$(sed -n 's/.* tag=\([^ ]*\).*/\1/p' <<< "${summary}")"
    commit="$(sed -n 's/.* commit=\([^ ]*\).*/\1/p' <<< "${summary}")"
    pending="$(sed -n 's/.* pending=\([0-9]*\).*/\1/p' <<< "${summary}")"
    comps="$(sed -n 's/.* components=\([^ ]*\).*/\1/p' <<< "${summary}")"
    key="${commit}"
    [[ "${tag}" == *+dirty ]] && key+="+dirty"
    COMMITS+=("${key}")
    colour="${C_GRN}"; (( pending > 0 )) && colour="${C_YEL}"
    printf '%-24s %-28s %s%-22s%s %s\n' "${host}" "${tag} ${commit:0:12}" "${colour}" "${pending} (${comps})" "${C_RST}" "${last}"
    echo "${pending}" > "${TMP}/${i}.pending"
done

# --- verdict ---------------------------------------------------------------------
echo
distinct="$(printf '%s\n' "${COMMITS[@]}" | grep -v '^?$' | sort -u | wc -l)"
drifted=0
for f in "${TMP}"/*.pending; do [[ -e "${f}" ]] || continue; (( $(cat "${f}") > 0 )) && drifted=$(( drifted + 1 )); done
dirty="$(printf '%s\n' "${COMMITS[@]}" | grep -c '+dirty' || true)"

if (( unreachable > 0 )); then
    printf '%sNOT VERIFIED%s: %d host(s) could not be checked.\n' "${C_RED}" "${C_RST}" "${unreachable}"
    exit 1
fi
if (( distinct == 1 && drifted == 0 && dirty == 0 )); then
    printf '%sSAME CODE%s: %d host(s) on commit %s, deployed files match it (plan 0 diff).\n' \
        "${C_GRN}" "${C_RST}" "${#HOSTS[@]}" "${COMMITS[0]:0:12}"
    exit 0
fi
printf '%sDIFFERENT%s: %d distinct checkout commit(s), %d host(s) with files differing from their checkout, %d dirty checkout(s).\n' \
    "${C_YEL}" "${C_RST}" "${distinct}" "${drifted}" "${dirty}"
printf 'Details per host: sudo scripts/update_host.sh --plan (on that host).\n'
exit 10
