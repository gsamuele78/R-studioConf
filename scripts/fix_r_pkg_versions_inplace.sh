#!/usr/bin/env bash
set -euo pipefail
# scripts/fix_r_pkg_versions_inplace.sh
#
# IN-PLACE FIX: bring the apt-installed R packages (r-cran-*) of ONE host up to
# the versions in its apt repositories, so hosts converge (ADR-0004 step 3).
#
# Why: bspm installs a researcher's install.packages() through apt on the host
# they are on, and nothing upgrades the other hosts. Baseline 2026-10-15
# (99_check_pkg_host_drift.sh): 180 packages with different versions across
# biome-calc01..04; calc01 is newest. Upgrading every host to the repository's
# current version closes those mismatches. Missing packages (246) are NOT
# installed here: that is the reconciler of ADR-0004 step 4.
#
# What it changes: only packages already installed as r-cran-*, and only to a
# newer version (apt-get --only-upgrade; apt holds are respected). It refuses a
# plan that removes any package or touches r-base*/r-recommended, so the R
# version pin (HARD RULE 19) cannot move.
#
# Safety:
#   * dry-run by default: prints the plan (apt-get -s) and how many upgrades
#     can be rolled back. --commit applies.
#   * --commit refuses when RStudio/R sessions are running: replacing a
#     package's files under a session that has it loaded can give
#     "lazy-load database is corrupt" errors in that session.
#     --allow-active-sessions overrides.
#   * --commit refuses unless EVERY upgraded package can be rolled back: the
#     old .deb is copied from the apt cache or downloaded (apt-get download)
#     into the backup dir BEFORE the upgrade. --accept-partial-rollback overrides.
#   * backup dir: ${BACKUP_ROOT}/r-pkg-align-<ts>/ with before.tsv, plan.tsv,
#     debs/, after.tsv.
#   * --rollback DIR reinstalls the saved .debs (apt-get --allow-downgrades).
#   * no service restart.
#
# Usage:
#   sudo bash scripts/fix_r_pkg_versions_inplace.sh                  # dry-run
#   sudo bash scripts/fix_r_pkg_versions_inplace.sh --commit
#   sudo bash scripts/fix_r_pkg_versions_inplace.sh --rollback DIR
#   Options: --no-update (skip apt-get update)  --allow-active-sessions
#            --accept-partial-rollback  -h|--help
#   Env:     FIX_PKG_BACKUP_ROOT  (default /var/backups/biome-calc)
#            FIX_PKG_APT_ARCHIVES (default /var/cache/apt/archives)
#
# Measure: run scripts/99_check_pkg_host_drift.sh on all hosts before and after.
#
# Exit codes:
#   0 applied, nothing to do, or dry-run
#   1 failed (or --commit/--rollback without root)
#   2 usage error
#   3 refused before any change (removal or r-base in the plan, active
#     sessions, rollback not fully possible): host unchanged

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_BOLD='\033[1m'
readonly C_RESET='\033[0m'

log_info()  { printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_head()  { printf '\n%b== %s ==%b\n' "$C_BOLD" "$*" "$C_RESET"; }

BACKUP_ROOT="${FIX_PKG_BACKUP_ROOT:-/var/backups/biome-calc}"
APT_ARCHIVES="${FIX_PKG_APT_ARCHIVES:-/var/cache/apt/archives}"
MODE="dry-run"
ROLLBACK_DIR=""
DO_UPDATE=true
ALLOW_SESSIONS=false
ACCEPT_PARTIAL=false

usage() { sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit)                  MODE="commit"; shift ;;
    --rollback)
      [[ $# -ge 2 ]] || { log_error "--rollback needs a backup directory"; exit 2; }
      MODE="rollback"; ROLLBACK_DIR="$2"; shift 2 ;;
    --no-update)               DO_UPDATE=false; shift ;;
    --allow-active-sessions)   ALLOW_SESSIONS=true; shift ;;
    --accept-partial-rollback) ACCEPT_PARTIAL=true; shift ;;
    -h|--help)                 usage; exit 0 ;;
    *) log_error "unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done

for bin in apt-get apt-cache dpkg-query pgrep awk; do
  command -v "$bin" >/dev/null 2>&1 || { log_error "required binary not found: $bin"; exit 1; }
done

is_root() { [[ "$(id -u)" -eq 0 ]]; }

# installed r-cran-* as "pkg<TAB>version"
installed_rcran() {
  dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 'r-cran-*' 2>/dev/null \
    | awk -F'\t' '$1 ~ /^ii/ {print $2 "\t" $3}' | LC_ALL=C sort
}

# ── rollback ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "rollback" ]]; then
  log_head "Rollback from ${ROLLBACK_DIR}"
  is_root || { log_error "--rollback needs root"; exit 1; }
  [[ -f "${ROLLBACK_DIR}/before.tsv" ]] || { log_error "not a backup dir (no before.tsv): ${ROLLBACK_DIR}"; exit 1; }
  shopt -s nullglob
  debs=("${ROLLBACK_DIR}"/debs/*.deb)
  shopt -u nullglob
  [[ ${#debs[@]} -gt 0 ]] || { log_error "no saved .deb files in ${ROLLBACK_DIR}/debs"; exit 1; }
  log_info "reinstalling ${#debs[@]} saved package(s)"
  apt-get install -y -q --allow-downgrades "${debs[@]}" || { log_error "apt-get failed; host state unchanged or partial — check dpkg -l 'r-cran-*'"; exit 1; }
  # verify every package in plan.tsv is back at its old version
  bad=0
  while IFS=$'\t' read -r pkg old _new; do
    now="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo missing)"
    if [[ "$now" != "$old" ]]; then log_warn "$pkg is $now, expected $old"; bad=1; fi
  done < "${ROLLBACK_DIR}/plan.tsv"
  [[ $bad -eq 0 ]] || { log_error "rollback incomplete (see warnings)"; exit 1; }
  log_ok "rollback complete"
  exit 0
fi

# ── plan ────────────────────────────────────────────────────────────────────
log_head "Plan (mode: ${MODE})"
if [[ "$DO_UPDATE" == true ]]; then
  if is_root; then
    apt-get update -q >/dev/null || { log_error "apt-get update failed"; exit 1; }
    log_info "apt index refreshed"
  else
    log_warn "not root: using the existing apt index (run with sudo for a fresh plan)"
  fi
fi

mapfile -t INSTALLED < <(installed_rcran)
if [[ ${#INSTALLED[@]} -eq 0 ]]; then
  log_ok "no r-cran-* packages installed: nothing to do"
  exit 0
fi
PKGS=()
for line in "${INSTALLED[@]}"; do PKGS+=("${line%%$'\t'*}"); done
log_info "${#PKGS[@]} r-cran-* packages installed"

SIM="$(apt-get -s -q install --only-upgrade "${PKGS[@]}" 2>&1)" || { log_error "apt-get simulation failed:"; printf '%s\n' "$SIM" >&2; exit 1; }

# Inst lines: "Inst pkg [old] (new repo [arch])" for upgrades, "Inst pkg (new ...)" for new installs
PLAN="$(awk '
  $1 == "Inst" {
    pkg = $2
    if ($3 ~ /^\[/) { old = $3; gsub(/[][]/, "", old); new = $4; sub(/^\(/, "", new); print "UPG\t" pkg "\t" old "\t" new }
    else            { new = $3; sub(/^\(/, "", new); print "NEW\t" pkg "\t-\t" new }
  }
  $1 == "Remv" { print "REMV\t" $2 "\t-\t-" }
' <<<"$SIM")"

UPG="$(awk -F'\t' '$1=="UPG" && $2 ~ /^r-cran-/' <<<"$PLAN")"
OTHER="$(awk -F'\t' '!($1=="UPG" && $2 ~ /^r-cran-/) && NF' <<<"$PLAN")"

if grep -qE '^REMV' <<<"$OTHER"; then
  log_error "the plan removes packages — refused:"; awk -F'\t' '$1=="REMV"{print "  " $2}' <<<"$OTHER" >&2; exit 3
fi
if awk -F'\t' '{print $2}' <<<"$OTHER" | grep -qE '^r-base|^r-recommended'; then
  log_error "the plan touches r-base*/r-recommended (R version pin, HARD RULE 19) — refused:"
  awk -F'\t' '$2 ~ /^r-base|^r-recommended/ {print "  " $1 " " $2 " " $4}' <<<"$OTHER" >&2; exit 3
fi

n_upg=0; [[ -n "$UPG" ]] && n_upg="$(wc -l <<<"$UPG")"
if [[ "$n_upg" -eq 0 ]]; then
  log_ok "all r-cran-* packages are at the repository version: nothing to do"
  exit 0
fi
log_info "${n_upg} package(s) to upgrade:"
awk -F'\t' '{printf "  %-34s %s -> %s\n", $2, $3, $4}' <<<"$UPG"
if [[ -n "$OTHER" ]]; then
  log_warn "also pulled in by the upgrade (dependencies):"
  awk -F'\t' '{printf "  %-4s %-34s %s\n", $1, $2, $4}' <<<"$OTHER" >&2
fi

# ── rollback coverage ───────────────────────────────────────────────────────
# old .deb in the apt cache, or old version still offered by a repository
COVER="$(while IFS=$'\t' read -r _t pkg old _new; do
  esc="${old//:/%3a}"
  if compgen -G "${APT_ARCHIVES}/${pkg}_${esc}_*.deb" >/dev/null; then
    printf '%s\t%s\tcache\n' "$pkg" "$old"
  elif apt-cache madison "$pkg" 2>/dev/null | awk -F'|' -v v="$old" '{gsub(/ /,"",$2)} $2==v {f=1} END{exit !f}'; then
    printf '%s\t%s\trepo\n' "$pkg" "$old"
  else
    printf '%s\t%s\tnone\n' "$pkg" "$old"
  fi
done <<<"$UPG")"
n_none="$(awk -F'\t' '$3=="none"' <<<"$COVER" | grep -c . || true)"
log_info "rollback possible for $((n_upg - n_none))/${n_upg} upgrade(s)"
if [[ "$n_none" -gt 0 ]]; then
  log_warn "no old .deb available for:"; awk -F'\t' '$3=="none"{print "  " $1 " " $2}' <<<"$COVER" >&2
fi

if [[ "$MODE" == "dry-run" ]]; then
  log_info "dry-run: nothing changed. Apply with --commit."
  exit 0
fi

# ── commit ──────────────────────────────────────────────────────────────────
log_head "Commit"
is_root || { log_error "--commit needs root"; exit 1; }

sessions="$(pgrep -c -x rsession 2>/dev/null || true)"; sessions="${sessions:-0}"
rprocs="$(pgrep -c -x R 2>/dev/null || true)"; rprocs="${rprocs:-0}"
if [[ $((sessions + rprocs)) -gt 0 && "$ALLOW_SESSIONS" != true ]]; then
  log_error "${sessions} RStudio session(s) and ${rprocs} R process(es) running: packages loaded in them may break."
  log_error "Run when idle, or pass --allow-active-sessions."
  exit 3
fi
if [[ "$n_none" -gt 0 && "$ACCEPT_PARTIAL" != true ]]; then
  log_error "${n_none} upgrade(s) cannot be rolled back — refused (see list above). --accept-partial-rollback overrides."
  exit 3
fi

BK="${BACKUP_ROOT}/r-pkg-align-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${BK}/debs" || { log_error "cannot create ${BK}"; exit 1; }
chmod 700 "$BK" || { log_error "chmod failed on ${BK}"; exit 1; }
printf '%s\n' "${INSTALLED[@]}" > "${BK}/before.tsv"
awk -F'\t' '{print $2 "\t" $3 "\t" $4}' <<<"$UPG" > "${BK}/plan.tsv"

saved=0
while IFS=$'\t' read -r pkg old src; do
  esc="${old//:/%3a}"
  case "$src" in
    cache)
      if cp -p "${APT_ARCHIVES}/${pkg}_${esc}_"*.deb "${BK}/debs/"; then saved=$((saved + 1))
      else log_warn "copy from apt cache failed: ${pkg}=${old}"; fi ;;
    repo)
      if ( cd "${BK}/debs" && apt-get download -q "${pkg}=${old}" >/dev/null ); then saved=$((saved + 1))
      else log_warn "download failed: ${pkg}=${old}"; fi ;;
  esac
done <<<"$COVER"
log_info "saved ${saved}/${n_upg} old package(s) in ${BK}/debs"
if [[ "$saved" -lt "$n_upg" && "$ACCEPT_PARTIAL" != true ]]; then
  log_error "could not save every old package — refused before any change. Backup dir: ${BK}"
  exit 3
fi

mapfile -t TO_UPG < <(awk -F'\t' '{print $2}' <<<"$UPG")
if ! apt-get install -y -q --only-upgrade "${TO_UPG[@]}"; then
  log_error "apt-get install failed. Roll back with: sudo bash $0 --rollback ${BK}"
  exit 1
fi
installed_rcran > "${BK}/after.tsv"

bad=0
while IFS=$'\t' read -r pkg _old new; do
  now="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo missing)"
  if [[ "$now" != "$new" ]]; then log_warn "$pkg is $now, expected $new"; bad=1; fi
done < "${BK}/plan.tsv"
if [[ $bad -ne 0 ]]; then
  log_error "some packages did not reach the planned version. Roll back with: sudo bash $0 --rollback ${BK}"
  exit 1
fi
log_ok "${n_upg} package(s) upgraded. Backup: ${BK}"
log_info "Rollback: sudo bash $0 --rollback ${BK}"
log_info "Measure: re-run scripts/99_check_pkg_host_drift.sh on every host and --compare."
