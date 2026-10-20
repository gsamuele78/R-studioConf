#!/usr/bin/env bash
set -euo pipefail
# scripts/biome_pkg_sync.sh
#
# Nightly R package sync across the biome-calc hosts (ADR-0004 step 4).
#
# Why: bspm installs a researcher's install.packages() through apt on the host
# they are on only, so hosts drift (2026-10-15: 426 of 690 packages differ).
# This job brings every host to the same set: the union of the r-cran-*
# packages installed on any host, at the repository's current version.
#
# Each run, from the systemd timer (every 30 min, 01:00-05:00 by default):
#   1. publish   write this host's manifest (JSON) to the shared directory on
#                biome-store03: r-cran-* packages from dpkg, R version, and
#                packages apt does not manage (reported, never synced)
#   2. gate      stop unless: inside the window, from APPLY_FROM, not already
#                done tonight, R at the pinned version, no R/RStudio session
#   3. plan      target = union of fresh manifests minus the policy exclusions;
#                missing = target minus installed, available in apt, capped
#   4. apply     (mode=apply only) align versions with
#                fix_r_pkg_versions_inplace.sh (old .debs saved), then install
#                the missing packages; never removes a package, never touches
#                r-base*/r-recommended
#   5. report    JSON report locally and in the shared directory
# A deferred run (sessions active) exits 75 and the next slot retries. After
# the window ends nothing starts until the next night. Sessions are never
# killed.
#
# Usage:
#   sudo bash scripts/biome_pkg_sync.sh                   # one run (what the timer does)
#   sudo bash scripts/biome_pkg_sync.sh --plan            # publish + plan, never change
#   bash scripts/biome_pkg_sync.sh --status               # fleet view from the manifests
#   sudo bash scripts/biome_pkg_sync.sh --rollback DIR    # remove what a run installed
#   sudo bash scripts/biome_pkg_sync.sh --install-timer | --remove-timer
#   Options: --force-window (ignore the window and tonight's done-marker; for a
#            supervised manual run), -h|--help
# Settings: config/pkg_sync.vars.conf, site overrides in
#           config/site/pkg_sync.site.vars.conf.
#
# Exit: 0 done / nothing to do / outside window | 1 failed | 2 usage error
#       3 refused, host unchanged | 4 status: hosts differ | 75 deferred (sessions)

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_RESET='\033[0m'

log_info()  { printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR WORKSPACE_ROOT

# shellcheck source=../config/pkg_sync.vars.conf disable=SC1091
source "${WORKSPACE_ROOT}/config/pkg_sync.vars.conf"
SITE_CONF="${WORKSPACE_ROOT}/config/site/pkg_sync.site.vars.conf"
# shellcheck source=/dev/null
[[ -f "${SITE_CONF}" ]] && source "${SITE_CONF}"

# R version pin: single source of truth (HARD RULE 19).
PIN_CONF="${WORKSPACE_ROOT}/config/pin_r_version.vars.conf"
PIN_R_VERSION="$(grep -m1 '^DEFAULT_R_VERSION=' "${PIN_CONF}" | cut -d= -f2- | tr -d '"' || true)"

FIX_SCRIPT="${PKG_SYNC_FIX_SCRIPT:-${SCRIPT_DIR}/fix_r_pkg_versions_inplace.sh}"
HOST="${PKG_SYNC_HOST:-$(hostname -s)}"
SYSTEMD_DIR="${PKG_SYNC_SYSTEMD_DIR:-/etc/systemd/system}"
LOCK_FILE="${PKG_SYNC_LOCK:-/run/lock/biome-pkg-sync.lock}"
APT_OPTS=(-q -o DPkg::Lock::Timeout=600)

ACTION="run"; ROLLBACK_DIR=""; FORCE_WINDOW=false
usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)          ACTION="plan"; shift ;;
    --status)        ACTION="status"; shift ;;
    --install-timer) ACTION="install-timer"; shift ;;
    --remove-timer)  ACTION="remove-timer"; shift ;;
    --rollback)
      [[ $# -ge 2 ]] || { log_error "--rollback needs a backup directory"; exit 2; }
      ACTION="rollback"; ROLLBACK_DIR="$2"; shift 2 ;;
    --force-window)  FORCE_WINDOW=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) log_error "unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done

for bin in jq apt-get apt-cache dpkg-query pgrep awk flock; do
  command -v "$bin" >/dev/null 2>&1 || { log_error "required binary not found: $bin"; exit 1; }
done
[[ "${PKG_SYNC_MODE}" == "dry-run" || "${PKG_SYNC_MODE}" == "apply" ]] \
  || { log_error "PKG_SYNC_MODE must be dry-run or apply, not '${PKG_SYNC_MODE}'"; exit 2; }

is_root() { [[ "$(id -u)" -eq 0 ]]; }
now_hhmm() { echo "${PKG_SYNC_NOW:-$(date +%H%M)}"; }
today()    { echo "${PKG_SYNC_TODAY:-$(date +%F)}"; }
utc_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# installed r-cran-* as "pkg<TAB>version"
installed_rcran() {
  dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 'r-cran-*' 2>/dev/null \
    | awk -F'\t' '$1 ~ /^ii/ {print $2 "\t" $3}' | LC_ALL=C sort
}

# installed R version without starting R, e.g. 4.6.0
local_r_version() {
  local v
  v="$(dpkg-query -W -f='${Version}' r-base-core 2>/dev/null || true)"
  printf '%s\n' "${v%%-*}"
}

# packages in PKG_SYNC_OTHER_LIBS (not managed by apt) as "pkg<TAB>version<TAB>lib"
other_packages() {
  local lib d
  for lib in ${PKG_SYNC_OTHER_LIBS}; do
    [[ -d "$lib" ]] || continue
    for d in "$lib"/*/DESCRIPTION; do
      [[ -f "$d" ]] || continue
      awk -v lib="$lib" -F': *' '$1=="Package"{p=$2} $1=="Version"{v=$2} END{if(p!="") print p "\t" v "\t" lib}' "$d"
    done
  done | LC_ALL=C sort
}

require_sync_dir() {
  [[ -n "${PKG_SYNC_DIR}" ]] || { log_error "PKG_SYNC_DIR is not set (config/site/pkg_sync.site.vars.conf)"; exit 1; }
  [[ -d "${PKG_SYNC_DIR}" ]] || { log_error "shared directory not found: ${PKG_SYNC_DIR} (is biome-store03 mounted?)"; exit 1; }
  mkdir -p "${PKG_SYNC_DIR}/hosts" "${PKG_SYNC_DIR}/reports" 2>/dev/null \
    || { log_error "cannot create hosts/ and reports/ in ${PKG_SYNC_DIR} (NFS root_squash? see docs/operations/PKG_SYNC.md)"; exit 1; }
}

# atomic write of stdin to FILE (temp file in the same directory, then mv)
write_atomic() {
  local file="$1" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  cat > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$file"
}

tsv_to_json() {  # $1 = space-separated field names
  jq -R -s --arg f "$1" '($f | split(" ")) as $k
    | split("\n") | map(select(length > 0) | split("\t")
    | [$k, .] | transpose | map({(.[0]): .[1]}) | add)'
}

publish() {
  require_sync_dir
  local apt other
  apt="$(installed_rcran | tsv_to_json "package version")"
  other="$(other_packages | tsv_to_json "package version lib")"
  jq -n --arg host "$HOST" --arg at "$(utc_now)" --arg r "$(local_r_version)" \
        --arg mode "$PKG_SYNC_MODE" --argjson apt "$apt" --argjson other "$other" \
    '{schema: 1, host: $host, generated_at: $at, r_version: $r, mode: $mode, apt: $apt, other: $other}' \
    | write_atomic "${PKG_SYNC_DIR}/hosts/${HOST}.json"
  log_ok "manifest published: ${PKG_SYNC_DIR}/hosts/${HOST}.json ($(jq 'length' <<<"$apt") r-cran-*, $(jq 'length' <<<"$other") not managed by apt)"
}

# fresh manifests as one JSON array; stale or invalid ones are reported and skipped
fresh_manifests() {
  local f now max
  now="$(date -u +%s)"; max=$(( PKG_SYNC_MAX_AGE_HOURS * 3600 ))
  for f in "${PKG_SYNC_DIR}"/hosts/*.json; do
    [[ -f "$f" ]] || continue
    if ! jq -e --argjson now "$now" --argjson max "$max" \
         '.schema == 1 and (.apt | type) == "array" and ($now - (.generated_at | fromdateiso8601)) <= $max' \
         "$f" >/dev/null 2>&1; then
      log_warn "skipping $(basename "$f"): stale (older than ${PKG_SYNC_MAX_AGE_HOURS}h) or invalid"
      continue
    fi
    cat "$f"
  done | jq -s '.'
}

excluded_packages() {
  local p="${PKG_SYNC_DIR}/policy.json"
  if [[ -f "$p" ]]; then
    jq -r '.exclude // [] | .[]' "$p" 2>/dev/null || { log_error "invalid ${p}"; exit 1; }
  fi
}

# missing packages for this host: union of fresh manifests - installed - excluded,
# names validated, available in apt. Prints "pkg<TAB>from-hosts".
plan_missing() {
  local manifests="$1" installed_names known
  installed_names="$(installed_rcran | cut -f1)"
  known="$(apt-cache pkgnames r-cran- 2>/dev/null | LC_ALL=C sort -u)"
  jq -r '[.[] | .host as $h | .apt[] | {p: .package, h: $h}]
         | group_by(.p) | .[] | "\(.[0].p)\t\([.[].h] | join(","))"' <<<"$manifests" \
    | LC_ALL=C sort \
    | awk -F'\t' -v inst="$installed_names" -v excl="$(excluded_packages)" -v known="$known" '
        BEGIN { n = split(inst, a, "\n"); for (i = 1; i <= n; i++) I[a[i]] = 1
                n = split(excl, b, "\n"); for (i = 1; i <= n; i++) X[b[i]] = 1
                n = split(known, c, "\n"); for (i = 1; i <= n; i++) K[c[i]] = 1 }
        $1 !~ /^r-cran-[a-z0-9][a-z0-9.+-]*$/ { print "BAD\t" $1 "\t" $2; next }
        ($1 in I) || ($1 in X) { next }
        !($1 in K) { print "NA\t" $1 "\t" $2; next }
        { print "NEW\t" $1 "\t" $2 }'
}

sessions_active() {  # prints "<rsession> <R>"
  local s r
  s="$(pgrep -c -x rsession 2>/dev/null || true)"; r="$(pgrep -c -x R 2>/dev/null || true)"
  echo "${s:-0} ${r:-0}"
}

REPORT_STATUS="unknown"; REPORT_NOTE=""; REPORT_NEW="[]"; REPORT_NA="[]"; REPORT_ALIGN="not run"; REPORT_BACKUP=""
write_report() {
  local r
  r="$(jq -n --arg host "$HOST" --arg at "$(utc_now)" --arg mode "$PKG_SYNC_MODE" \
          --arg status "$REPORT_STATUS" --arg note "$REPORT_NOTE" --arg align "$REPORT_ALIGN" \
          --arg backup "$REPORT_BACKUP" --argjson new "$REPORT_NEW" --argjson na "$REPORT_NA" \
    '{schema: 1, host: $host, finished_at: $at, mode: $mode, status: $status, note: $note,
      version_alignment: $align, installed_or_planned: $new, not_in_apt: $na, backup: $backup}')"
  mkdir -p "${PKG_SYNC_STATE_DIR}"
  write_atomic "${PKG_SYNC_STATE_DIR}/last_report.json" <<<"$r"
  [[ -d "${PKG_SYNC_DIR}/reports" ]] && write_atomic "${PKG_SYNC_DIR}/reports/${HOST}.json" <<<"$r"
  return 0
}
finish() {  # STATUS NOTE EXIT
  REPORT_STATUS="$1"; REPORT_NOTE="$2"
  write_report
  exit "$3"
}

# ── status: fleet view from the shared manifests (read-only) ────────────────
if [[ "$ACTION" == "status" ]]; then
  require_sync_dir
  m="$(fresh_manifests)"
  [[ "$(jq 'length' <<<"$m")" -gt 0 ]] || { log_error "no fresh manifest in ${PKG_SYNC_DIR}/hosts"; exit 1; }
  jq -r '([.[].apt[].package] | unique) as $u
    | ["HOST", "R", "MANIFEST (UTC)", "MODE", "R-CRAN", "MISSING", "NOT-APT"],
      (.[] | [.host, .r_version, .generated_at, .mode, (.apt | length),
              ($u - [.apt[].package] | length), (.other | length)])
    | @tsv' <<<"$m" | { if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi; }
  versions="$(jq -r '[.[] | .host as $h | .apt[] | {p: .package, v: .version}]
             | group_by(.p) | map(select(([.[].v] | unique | length) > 1)) | length' <<<"$m")"
  missing="$(jq '([.[].apt[].package] | unique) as $u | [.[] | ($u - [.apt[].package]) | length] | add' <<<"$m")"
  rvers="$(jq '[.[].r_version] | unique | length' <<<"$m")"
  log_info "packages differing in version: ${versions}; missing (sum over hosts): ${missing}; R versions: ${rvers}"
  for f in "${PKG_SYNC_DIR}"/reports/*.json; do
    [[ -f "$f" ]] && jq -r '"last run \(.host): \(.status) at \(.finished_at) (\(.mode)) \(.note)"' "$f"
  done
  if [[ "$versions" -eq 0 && "$missing" -eq 0 && "$rvers" -eq 1 ]]; then log_ok "all hosts have the same R packages"; exit 0; fi
  exit 4
fi

# ── timer install/remove ─────────────────────────────────────────────────────
if [[ "$ACTION" == "install-timer" || "$ACTION" == "remove-timer" ]]; then
  is_root || { log_error "--${ACTION} needs root"; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { log_error "systemctl not found"; exit 1; }
  if [[ "$ACTION" == "remove-timer" ]]; then
    systemctl disable --now biome-pkg-sync.timer 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/biome-pkg-sync.service" "${SYSTEMD_DIR}/biome-pkg-sync.timer"
    systemctl daemon-reload
    log_ok "timer removed (manifests, reports and backups are left in place)"
    exit 0
  fi
  require_sync_dir
  tpl="${WORKSPACE_ROOT}/templates/systemd"
  sed -e "s|%%SCRIPT%%|${SCRIPT_DIR}/biome_pkg_sync.sh|g" -e "s|%%SYNC_DIR%%|${PKG_SYNC_DIR}|g" \
      "${tpl}/biome-pkg-sync.service.template" \
    | write_atomic "${SYSTEMD_DIR}/biome-pkg-sync.service"
  start="${PKG_SYNC_WINDOW_START:0:2}"; last=$(( 10#${PKG_SYNC_WINDOW_END:0:2} - 1 ))
  sed "s|%%HOURS%%|${start}..$(printf '%02d' "$last")|g" "${tpl}/biome-pkg-sync.timer.template" \
    | write_atomic "${SYSTEMD_DIR}/biome-pkg-sync.timer"
  systemctl daemon-reload
  systemctl enable --now biome-pkg-sync.timer
  log_ok "timer installed (mode: ${PKG_SYNC_MODE}); next runs: systemctl list-timers biome-pkg-sync.timer"
  exit 0
fi

# ── rollback: remove the packages a run installed ───────────────────────────
if [[ "$ACTION" == "rollback" ]]; then
  is_root || { log_error "--rollback needs root"; exit 1; }
  [[ -f "${ROLLBACK_DIR}/new.tsv" ]] || { log_error "not a sync backup dir (no new.tsv): ${ROLLBACK_DIR}"; exit 1; }
  mapfile -t RM < <(cut -f1 "${ROLLBACK_DIR}/new.tsv" | awk 'NF')
  [[ ${#RM[@]} -gt 0 ]] || { log_ok "the run installed nothing: nothing to roll back"; exit 0; }
  sim="$(apt-get -s "${APT_OPTS[@]}" remove "${RM[@]}" 2>&1)" || { log_error "apt-get simulation failed:"; printf '%s\n' "$sim" >&2; exit 1; }
  extra="$(awk '$1=="Remv"{print $2}' <<<"$sim" | grep -vxF -f <(printf '%s\n' "${RM[@]}") || true)"
  if [[ -n "$extra" ]]; then
    log_error "removing them would also remove packages the run did not install — refused:"; sed 's/^/  /' <<<"$extra" >&2; exit 3
  fi
  apt-get remove -y "${APT_OPTS[@]}" "${RM[@]}" || { log_error "apt-get remove failed"; exit 1; }
  log_ok "removed ${#RM[@]} package(s) installed by that run"
  if [[ -f "${ROLLBACK_DIR}/align_backup" ]]; then
    log_info "versions it aligned: sudo bash ${FIX_SCRIPT} --rollback $(cat "${ROLLBACK_DIR}/align_backup")"
  fi
  exit 0
fi

# ── run / plan ───────────────────────────────────────────────────────────────
mkdir -p "${PKG_SYNC_STATE_DIR}" || { log_error "cannot create ${PKG_SYNC_STATE_DIR}"; exit 1; }
exec 9>"${LOCK_FILE}"
flock -n 9 || { log_warn "another sync run is active: exiting"; exit 0; }

publish

now="$(now_hhmm)"
if [[ "$FORCE_WINDOW" != true && "$ACTION" == "run" ]]; then
  if (( 10#$now < 10#$PKG_SYNC_WINDOW_START || 10#$now >= 10#$PKG_SYNC_WINDOW_END )); then
    log_info "outside the window ${PKG_SYNC_WINDOW_START}-${PKG_SYNC_WINDOW_END}: manifest only"; exit 0
  fi
  if (( 10#$now < 10#$PKG_SYNC_APPLY_FROM )); then
    log_info "before ${PKG_SYNC_APPLY_FROM}: manifest only, so every host publishes first"; exit 0
  fi
  if [[ "$(cat "${PKG_SYNC_STATE_DIR}/done_date" 2>/dev/null || true)" == "$(today)" ]]; then
    log_info "already synced tonight: nothing to do"; exit 0
  fi
fi

r_local="$(local_r_version)"
if [[ -n "$PIN_R_VERSION" && "$r_local" != "$PIN_R_VERSION" ]]; then
  finish refused "R ${r_local} is not the pinned ${PIN_R_VERSION} (HARD RULE 19): align R first (scripts/pin_r_version.sh)" 3
fi

manifests="$(fresh_manifests)"
log_info "$(jq 'length' <<<"$manifests") fresh manifest(s): $(jq -r '[.[].host] | join(", ")' <<<"$manifests")"
PLAN="$(plan_missing "$manifests")"
bad="$(awk -F'\t' '$1=="BAD"{print $2}' <<<"$PLAN")"
[[ -z "$bad" ]] || log_warn "ignored invalid package names in manifests: $(tr '\n' ' ' <<<"$bad")"
REPORT_NA="$(awk -F'\t' '$1=="NA"{print $2 "\t" $3}' <<<"$PLAN" | tsv_to_json "package hosts")"
[[ "$(jq 'length' <<<"$REPORT_NA")" -eq 0 ]] || log_warn "$(jq 'length' <<<"$REPORT_NA") package(s) installed elsewhere are not in this host's apt repositories (reported only)"
NEW_ALL="$(awk -F'\t' '$1=="NEW"{print $2 "\t" $3}' <<<"$PLAN")"
n_all=0; [[ -n "$NEW_ALL" ]] && n_all="$(wc -l <<<"$NEW_ALL")"
NEW="$(head -n "$PKG_SYNC_MAX_NEW" <<<"$NEW_ALL")"
REPORT_NEW="$(tsv_to_json "package hosts" <<<"$NEW")"
log_info "${n_all} package(s) missing on ${HOST}; this run takes $(jq 'length' <<<"$REPORT_NEW") (max ${PKG_SYNC_MAX_NEW})"

if [[ "$ACTION" == "plan" || "$PKG_SYNC_MODE" == "dry-run" ]]; then
  [[ -n "$NEW" ]] && awk -F'\t' '{printf "  %-34s (on %s)\n", $1, $2}' <<<"$NEW"
  log_info "dry-run: nothing changed (version alignment plan: sudo bash ${FIX_SCRIPT})"
  if [[ "$ACTION" == "run" ]]; then
    mkdir -p "${PKG_SYNC_STATE_DIR}"; today > "${PKG_SYNC_STATE_DIR}/done_date"
  fi
  finish dry-run "${n_all} missing" 0
fi

is_root || { log_error "applying needs root"; exit 1; }
read -r s r <<<"$(sessions_active)"
if (( s + r > 0 )); then
  finish deferred "${s} RStudio session(s), ${r} R process(es) running: retry at the next slot" 75
fi

BK="${PKG_SYNC_BACKUP_ROOT}/r-pkg-sync-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BK" || { log_error "cannot create ${BK}"; exit 1; }
chmod 700 "$BK" || { log_error "chmod failed on ${BK}"; exit 1; }
REPORT_BACKUP="$BK"
installed_rcran > "${BK}/before.tsv"
: > "${BK}/new.tsv"

# 1) version alignment (backs up old .debs itself; exit 3 = refused, unchanged)
apt-get update "${APT_OPTS[@]}" >/dev/null || finish failed "apt-get update failed" 1
align_args=(--commit --no-update)
[[ "$PKG_SYNC_ACCEPT_PARTIAL_ROLLBACK" == true ]] && align_args+=(--accept-partial-rollback)
set +e
align_out="$(FIX_PKG_BACKUP_ROOT="$PKG_SYNC_BACKUP_ROOT" bash "$FIX_SCRIPT" "${align_args[@]}" 2>&1)"
align_rc=$?
set -e
printf '%s\n' "$align_out" > "${BK}/align.log"
case "$align_rc" in
  0) REPORT_ALIGN="done"
     ab="$(grep -o "${PKG_SYNC_BACKUP_ROOT}/r-pkg-align-[0-9TZ]*" <<<"$align_out" | tail -1 || true)"
     [[ -n "$ab" ]] && printf '%s\n' "$ab" > "${BK}/align_backup" ;;
  3) REPORT_ALIGN="refused, unchanged (see ${BK}/align.log)"; log_warn "version alignment refused, host unchanged: $(grep -m1 FAIL <<<"$align_out" || true)" ;;
  *) REPORT_ALIGN="failed (see ${BK}/align.log)"
     finish failed "version alignment failed (rc ${align_rc}); see ${BK}/align.log" 1 ;;
esac

# 2) install missing packages
if [[ -z "$NEW" ]]; then
  today > "${PKG_SYNC_STATE_DIR}/done_date"
  finish "done" "nothing missing; alignment: ${REPORT_ALIGN}" 0
fi
mapfile -t TO_NEW < <(cut -f1 <<<"$NEW")
sim="$(apt-get -s "${APT_OPTS[@]}" install --no-remove "${TO_NEW[@]}" 2>&1)" \
  || finish refused "apt-get simulation failed: $(tail -n 2 <<<"$sim" | tr '\n' ' ')" 3
if awk '$1=="Remv"' <<<"$sim" | grep -q .; then
  finish refused "the install plan removes packages" 3
fi
if awk '$1=="Inst"{print $2}' <<<"$sim" | grep -qE '^r-base|^r-recommended'; then
  finish refused "the install plan touches r-base*/r-recommended (HARD RULE 19)" 3
fi
upg_in_plan="$(awk '$1=="Inst" && $3 ~ /^\[/ {print $2}' <<<"$sim")"
if [[ -n "$upg_in_plan" ]]; then
  finish refused "installing would upgrade already-installed packages without a saved .deb: $(tr '\n' ' ' <<<"$upg_in_plan")" 3
fi
read -r s r <<<"$(sessions_active)"
(( s + r == 0 )) || finish deferred "a session started during the run: retry at the next slot" 75
if ! apt-get install -y "${APT_OPTS[@]}" --no-remove "${TO_NEW[@]}" > "${BK}/install.log" 2>&1; then
  installed_rcran > "${BK}/after.tsv"
  LC_ALL=C comm -13 <(cut -f1 "${BK}/before.tsv") <(cut -f1 "${BK}/after.tsv") > "${BK}/new.tsv"
  finish failed "apt-get install failed (see ${BK}/install.log); undo: sudo bash $0 --rollback ${BK}" 1
fi
installed_rcran > "${BK}/after.tsv"
LC_ALL=C comm -13 <(cut -f1 "${BK}/before.tsv") <(cut -f1 "${BK}/after.tsv") > "${BK}/new.tsv"
today > "${PKG_SYNC_STATE_DIR}/done_date"
publish
log_info "undo: sudo bash $0 --rollback ${BK}"
finish "done" "$(wc -l < "${BK}/new.tsv") package(s) installed; alignment: ${REPORT_ALIGN}" 0
