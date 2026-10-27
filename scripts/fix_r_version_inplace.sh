#!/usr/bin/env bash
set -euo pipefail
# scripts/fix_r_version_inplace.sh
#
# IN-PLACE FIX: bring the R core packages (r-base, r-base-core, r-base-dev,
# r-recommended) of ONE host to the pinned R version, so every host runs the
# same R (HARD RULE 19, ADR-0004).
#
# Why: on 2026-10-27 biome-calc03 ran R 4.5.3 while the pin
# (config/pin_r_version.vars.conf, DEFAULT_R_VERSION) and calc01/02/04 are on
# 4.6.0. scripts/pin_r_version.sh only writes the apt pin; it installs
# nothing.
#
# Lesson from calc03 (2026-10-27): R 4.6 removed SETLENGTH from the C API, and
# the r-cran-rlang and r-cran-data.table builds installed under 4.5 called it.
# After the core upgrade 136 packages stopped loading (rlang and everything
# that imports it). Upgrading the r-cran-* packages to the repository builds
# fixed all 133 apt-installed ones. So on a minor-version change (4.5 -> 4.6)
# the plan now upgrades, in the same apt transaction, every installed
# r-cran-* package the repository has a newer build of. --core-only skips
# that (not recommended across a minor version).
#
# Steps:
#   sudo bash scripts/fix_r_version_inplace.sh            # plan
#   sudo bash scripts/fix_r_version_inplace.sh --commit   # apply
#   If the repository no longer offers the pinned version, take the .debs
#   from a host that runs it: --export-debs DIR there, --debs DIR here. When
#   the repository offers the same version, apt may download it from there
#   instead of using DIR (same version, signed repository); the plan says so.
#
# Safety:
#   * dry-run by default (plan, apt-get -s). --commit applies.
#   * refuses (exit 3, host unchanged) when: R sessions run, a core package is
#     held, the target is not available, the plan removes a package, or an
#     old .deb cannot be saved for rollback (--accept-partial-rollback
#     overrides the last one). A downgrade needs --allow-downgrade.
#   * backup dir ${BACKUP_ROOT}/r-version-<ts>/: before.tsv (every r-*
#     package), plan.tsv, debs/ (old .debs), load_before.tsv, load_after.tsv.
#   * load test (metric): every installed R package is loaded with
#     loadNamespace() before and after, in batches of separate Rscript
#     processes. Packages that loaded before and fail after are regressions:
#     exit 5 with the rollback command. --no-load-test skips it.
#   * rstudio-server is restarted after the change (no session is running),
#     unless --no-restart.
#   * user libraries (~/R/x86_64-pc-linux-gnu-library/X.Y) are never touched
#     (HARD RULE 17); a minor-version change only reports how many users
#     have packages (a non-empty library) for the old X.Y alone.
#   * the load test refuses the change (exit 3) when it cannot list or load
#     any package before it: without a baseline nothing can be measured.
#   * --rollback DIR reinstalls the saved .debs (apt-get --allow-downgrades)
#     and restarts rstudio-server. The pin would bring R back to the target
#     on the next apt upgrade: hold the packages if the rollback must stay.
#
# Usage:
#   sudo bash scripts/fix_r_version_inplace.sh [--debs DIR]            # dry-run
#   sudo bash scripts/fix_r_version_inplace.sh [--debs DIR] --commit
#   sudo bash scripts/fix_r_version_inplace.sh --rollback DIR
#   sudo bash scripts/fix_r_version_inplace.sh --export-debs DIR
#   Options: --no-update  --no-load-test  --no-restart  --allow-downgrade
#            --accept-partial-rollback  --core-only  -h|--help
#   Env:     FIX_R_BACKUP_ROOT  (default /var/backups/biome-calc)
#            FIX_R_APT_ARCHIVES (default /var/cache/apt/archives)
#            FIX_R_USER_LIB_ROOT (default /nfs/home)
#            FIX_R_LOAD_BATCH (default 40 packages per Rscript)
#
# Exit codes:
#   0 applied, nothing to do, dry-run, or export done
#   1 failed (or --commit/--rollback without root)
#   2 usage error
#   3 refused before any change: host unchanged
#   5 applied, but packages that loaded before no longer load: roll back or fix

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR WORKSPACE_ROOT

# R version pin: single source of truth (HARD RULE 19).
PIN_CONF="${WORKSPACE_ROOT}/config/pin_r_version.vars.conf"
[[ -f "$PIN_CONF" ]] || { log_error "missing ${PIN_CONF}"; exit 1; }
TARGET="$(grep -m1 '^DEFAULT_R_VERSION=' "$PIN_CONF" | cut -d= -f2- | tr -d '"' || true)"
CORE="$(grep -m1 '^R_CORE_PACKAGES=' "$PIN_CONF" | cut -d= -f2- | tr -d '"' || true)"
[[ -n "$CORE" ]] || CORE="r-base r-base-core r-base-dev r-recommended"
[[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log_error "DEFAULT_R_VERSION in ${PIN_CONF} is not X.Y.Z: '${TARGET}'"; exit 1; }
read -r -a CORE_PKGS <<<"$CORE"

BACKUP_ROOT="${FIX_R_BACKUP_ROOT:-/var/backups/biome-calc}"
APT_ARCHIVES="${FIX_R_APT_ARCHIVES:-/var/cache/apt/archives}"
USER_LIB_ROOT="${FIX_R_USER_LIB_ROOT:-/nfs/home}"
LOAD_BATCH="${FIX_R_LOAD_BATCH:-40}"
APT_OPTS=(-q -o DPkg::Lock::Timeout=600)

MODE="dry-run"; DIR_ARG=""; DEBS_DIR=""
DO_UPDATE=true; LOAD_TEST=true; RESTART=true; ALLOW_DOWNGRADE=false; ACCEPT_PARTIAL=false; CORE_ONLY=false

usage() { sed -n '2,/^# *5 applied/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit)          MODE="commit"; shift ;;
    --rollback|--export-debs)
      [[ $# -ge 2 ]] || { log_error "$1 needs a directory"; exit 2; }
      MODE="${1#--}"; DIR_ARG="$2"; shift 2 ;;
    --debs)
      [[ $# -ge 2 ]] || { log_error "--debs needs a directory"; exit 2; }
      DEBS_DIR="$2"; shift 2 ;;
    --no-update)       DO_UPDATE=false; shift ;;
    --no-load-test)    LOAD_TEST=false; shift ;;
    --no-restart)      RESTART=false; shift ;;
    --allow-downgrade) ALLOW_DOWNGRADE=true; shift ;;
    --accept-partial-rollback) ACCEPT_PARTIAL=true; shift ;;
    --core-only)       CORE_ONLY=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) log_error "unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done

for bin in apt-get apt-cache apt-mark dpkg-query dpkg-deb pgrep awk sort; do
  command -v "$bin" >/dev/null 2>&1 || { log_error "required binary not found: $bin"; exit 1; }
done

is_root() { [[ "$(id -u)" -eq 0 ]]; }
pkg_version() { dpkg-query -W -f='${db:Status-Abbrev}\t${Version}\n' "$1" 2>/dev/null | awk -F'\t' '$1 ~ /^ii/ {print $2}'; }
# 4.6.0-1.2404.0 -> 4.6.0 ; 4.6.0 -> 4.6
upstream() { local v="${1#*:}"; echo "${v%%-*}"; }
minor()    { local u; u="$(upstream "$1")"; echo "${u%.*}"; }
all_r_pkgs() {
  dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 'r-*' 2>/dev/null \
    | awk -F'\t' '$1 ~ /^ii/ {print $2 "\t" $3}' | LC_ALL=C sort
}
sessions_active() {
  local s r
  s="$(pgrep -c -x rsession 2>/dev/null || true)"; r="$(pgrep -c -x R 2>/dev/null || true)"
  echo "${s:-0} ${r:-0}"
}
restart_rstudio() {
  [[ "$RESTART" == true ]] || { log_info "rstudio-server not restarted (--no-restart)"; return 0; }
  if systemctl is-active --quiet rstudio-server 2>/dev/null; then
    if systemctl restart rstudio-server; then log_ok "rstudio-server restarted"
    else log_warn "rstudio-server restart failed: systemctl status rstudio-server"; fi
  fi
}

# Save the .deb of PKG at VERSION into DEST: apt cache, then a repository,
# then dpkg-repack of the installed files (only when VERSION is installed).
# Prints the source used (cache|repo|repack) or "none".
save_deb() {
  local pkg="$1" ver="$2" dest="$3" esc="${2//:/%3a}"
  if compgen -G "${APT_ARCHIVES}/${pkg}_${esc}_*.deb" >/dev/null \
     && cp -p "${APT_ARCHIVES}/${pkg}_${esc}_"*.deb "$dest/" 2>/dev/null; then echo cache; return 0; fi
  if apt-cache madison "$pkg" 2>/dev/null | awk -F'|' -v v="$ver" '{gsub(/ /,"",$2)} $2==v {f=1} END{exit !f}' \
     && ( cd "$dest" && apt-get download -q "${pkg}=${ver}" >/dev/null 2>&1 ); then echo repo; return 0; fi
  if [[ "$(pkg_version "$pkg")" == "$ver" ]] && command -v dpkg-repack >/dev/null 2>&1 \
     && ( cd "$dest" && dpkg-repack "$pkg" >/dev/null 2>&1 ); then echo repack; return 0; fi
  echo none
}
# Can save_deb succeed? Same chain, without writing.
can_save_deb() {
  local pkg="$1" ver="$2" esc="${2//:/%3a}"
  compgen -G "${APT_ARCHIVES}/${pkg}_${esc}_*.deb" >/dev/null && { echo cache; return; }
  apt-cache madison "$pkg" 2>/dev/null | awk -F'|' -v v="$ver" '{gsub(/ /,"",$2)} $2==v {f=1} END{exit !f}' && { echo repo; return; }
  [[ "$(pkg_version "$pkg")" == "$ver" ]] && command -v dpkg-repack >/dev/null 2>&1 && { echo repack; return; }
  echo none
}

# Load every installed R package in a fresh Rscript per batch; writes
# "pkg<TAB>OK|FAIL" to OUT and prints one progress line per batch.
load_test() {
  local out="$1" rs="$2" i n nb pk=()
  cat > "$rs" <<'REOF'
for (p in commandArgs(trailingOnly = TRUE)) {
  ok <- tryCatch({ suppressMessages(suppressWarnings(loadNamespace(p))); "OK" },
                 error = function(e) "FAIL")
  cat(p, "\t", ok, "\n", sep = "")
}
REOF
  mapfile -t pk < <(Rscript --vanilla -e 'cat(unique(rownames(installed.packages(lib.loc = .libPaths()))), sep = "\n")' 2>/dev/null \
    | LC_ALL=C sort -u)
  n=${#pk[@]}; nb=$(( (n + LOAD_BATCH - 1) / LOAD_BATCH ))
  : > "${out}.tmp"
  for (( i = 0; i < n; i += LOAD_BATCH )); do
    log_info "  load test batch $(( i / LOAD_BATCH + 1 ))/${nb} (${pk[i]} ...)"
    timeout 900 Rscript --vanilla "$rs" "${pk[@]:i:LOAD_BATCH}" 2>/dev/null >> "${out}.tmp" || true
  done
  LC_ALL=C sort "${out}.tmp" > "$out"; rm -f "${out}.tmp"
}

# ── export: write the installed core .debs for another host ────────────────
if [[ "$MODE" == "export-debs" ]]; then
  log_head "Export R core packages to ${DIR_ARG}"
  mkdir -p "$DIR_ARG" || { log_error "cannot create ${DIR_ARG}"; exit 1; }
  rv="$(pkg_version r-base-core)"
  [[ "$(upstream "$rv")" == "$TARGET" ]] || log_warn "this host runs R ${rv:-none}, not the pinned ${TARGET}"
  bad=0
  for p in "${CORE_PKGS[@]}"; do
    v="$(pkg_version "$p")"; [[ -n "$v" ]] || { log_info "$p not installed here: skipped"; continue; }
    src="$(save_deb "$p" "$v" "$DIR_ARG")"
    if [[ "$src" == none ]]; then
      log_error "$p=$v: no .deb in the apt cache or a repository (install dpkg-repack to rebuild it from the installed files)"; bad=1
    else log_ok "$p=$v ($src)"; fi
  done
  (( bad == 0 )) || exit 1
  ( cd "$DIR_ARG" && sha256sum ./*.deb > SHA256SUMS ) || { log_error "sha256sum failed"; exit 1; }
  log_ok "exported to ${DIR_ARG} (with SHA256SUMS). Copy the directory to the target host and run there:"
  log_info "  sudo bash scripts/fix_r_version_inplace.sh --debs ${DIR_ARG}"
  exit 0
fi

# ── rollback ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "rollback" ]]; then
  log_head "Rollback from ${DIR_ARG}"
  is_root || { log_error "--rollback needs root"; exit 1; }
  [[ -f "${DIR_ARG}/plan.tsv" ]] || { log_error "not a backup dir (no plan.tsv): ${DIR_ARG}"; exit 1; }
  read -r s r <<<"$(sessions_active)"
  (( s + r == 0 )) || { log_error "${s} RStudio session(s), ${r} R process(es) running: roll back when idle"; exit 3; }
  shopt -s nullglob; debs=("${DIR_ARG}"/debs/*.deb); shopt -u nullglob
  [[ ${#debs[@]} -gt 0 ]] || { log_error "no saved .deb files in ${DIR_ARG}/debs"; exit 1; }
  sim="$(apt-get -s "${APT_OPTS[@]}" install --allow-downgrades --no-remove "${debs[@]}" 2>&1)" \
    || { log_error "apt-get simulation failed:"; printf '%s\n' "$sim" >&2; exit 1; }
  if grep -q '^Remv' <<<"$sim"; then log_error "rollback would remove packages — refused:"; grep '^Remv' <<<"$sim" >&2; exit 3; fi
  apt-get install -y "${APT_OPTS[@]}" --allow-downgrades --no-remove "${debs[@]}" \
    || { log_error "apt-get failed: check dpkg -l 'r-base*'"; exit 1; }
  bad=0
  while IFS=$'\t' read -r pkg old _new; do
    [[ "$old" == "-" ]] && continue
    now="$(pkg_version "$pkg")"
    [[ "$now" == "$old" ]] || { log_warn "$pkg is ${now:-missing}, expected $old"; bad=1; }
  done < "${DIR_ARG}/plan.tsv"
  (( bad == 0 )) || { log_error "rollback incomplete (see warnings)"; exit 1; }
  restart_rstudio
  log_ok "rollback complete: R $(upstream "$(pkg_version r-base-core)")"
  log_warn "the pin (${TARGET}) brings R back on the next apt upgrade; to keep the rollback: sudo apt-mark hold ${CORE}"
  exit 0
fi

# ── plan ────────────────────────────────────────────────────────────────────
log_head "Plan (mode: ${MODE}, target R ${TARGET})"
CUR="$(pkg_version r-base-core)"
[[ -n "$CUR" ]] || { log_error "r-base-core is not installed: this is a fresh install, use the normal setup"; exit 1; }
log_info "installed: r-base-core ${CUR}"
if [[ "$(upstream "$CUR")" == "$TARGET" ]]; then
  log_ok "R is already at the pinned ${TARGET}: nothing to do"; exit 0
fi

if [[ "$DO_UPDATE" == true ]]; then
  if is_root; then apt-get update "${APT_OPTS[@]}" >/dev/null || { log_error "apt-get update failed"; exit 1; }
  else log_warn "not root: using the existing apt index"; fi
fi

held="$(apt-mark showhold 2>/dev/null | grep -xF -f <(printf '%s\n' "${CORE_PKGS[@]}") || true)"
if [[ -n "$held" ]]; then
  log_error "held by apt-mark: $(tr '\n' ' ' <<<"$held")— refused. Find out why they are held before unholding."; exit 3
fi

INSTALL=()
IN_REPO=()
PLAN=""
for p in "${CORE_PKGS[@]}"; do
  old="$(pkg_version "$p")"; [[ -n "$old" ]] || continue
  if [[ -n "$DEBS_DIR" ]]; then
    shopt -s nullglob; f=("${DEBS_DIR}/${p}_${TARGET}-"*.deb); shopt -u nullglob
    if [[ ${#f[@]} -ne 1 ]]; then log_error "${DEBS_DIR}: expected one ${p}_${TARGET}-*.deb, found ${#f[@]} — refused"; exit 3; fi
    new="$(dpkg-deb -f "${f[0]}" Version)"
    INSTALL+=("$(cd "$(dirname "${f[0]}")" && pwd)/$(basename "${f[0]}")")
    if apt-cache madison "$p" 2>/dev/null | awk -F'|' -v v="$new" '{gsub(/ /,"",$2)} $2==v {f=1} END{exit !f}'; then
      IN_REPO+=("$p")
    fi
  else
    new="$(apt-cache madison "$p" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
           | grep -E "^([0-9]+:)?${TARGET//./\\.}-" | sort -V | tail -1 || true)"
    if [[ -z "$new" ]]; then
      newest="$(apt-cache madison "$p" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}' | sort -V | tail -1 || true)"
      log_error "R ${TARGET} (${p}) is not in the apt repositories (newest: ${newest:-none}) — refused."
      log_error "Export it from a host that runs it (--export-debs DIR there, --debs DIR here), or move the pin (operator decision)."
      exit 3
    fi
    INSTALL+=("${p}=${new}")
  fi
  PLAN+="${p}"$'\t'"${old}"$'\t'"${new}"$'\n'
done
if [[ -n "$DEBS_DIR" && -f "${DEBS_DIR}/SHA256SUMS" ]]; then
  ( cd "$DEBS_DIR" && sha256sum -c --quiet SHA256SUMS ) || { log_error "checksum mismatch in ${DEBS_DIR} — refused"; exit 3; }
  log_ok "checksums of ${DEBS_DIR} verified"
fi
awk -F'\t' 'NF {printf "  %-16s %s -> %s\n", $1, $2, $3}' <<<"$PLAN"
if [[ ${#IN_REPO[@]} -gt 0 ]]; then
  log_info "the repository offers the same version of ${IN_REPO[*]}: apt may download it from there instead of ${DEBS_DIR} (same version)"
fi

# A minor-version change needs r-cran-* builds for the new R: compiled
# packages built for the old one can call C entry points the new R removed
# (calc03: SETLENGTH, rlang and data.table). Upgrade them in the same apt
# transaction.
RCRAN_UPG=""
if [[ "$(minor "$CUR")" != "$(minor "$TARGET")" ]]; then
  mapfile -t RCRAN < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'r-cran-*' 2>/dev/null | awk -F'\t' '$1 ~ /^ii/ {print $2}' | LC_ALL=C sort)
  if [[ ${#RCRAN[@]} -gt 0 ]]; then
    RSIM="$(apt-get -s "${APT_OPTS[@]}" install --only-upgrade "${RCRAN[@]}" 2>&1)" \
      || { log_error "apt-get simulation of the r-cran-* upgrade failed:"; printf '%s\n' "$RSIM" >&2; exit 1; }
    RCRAN_UPG="$(awk '$1=="Inst" && $2 ~ /^r-cran-/ && $3 ~ /^\[/ {print $2}' <<<"$RSIM")"
  fi
  n_rc=0; [[ -n "$RCRAN_UPG" ]] && n_rc="$(wc -l <<<"$RCRAN_UPG")"
  if [[ "$CORE_ONLY" == true ]]; then
    log_warn "--core-only: ${n_rc} installed r-cran-* package(s) have a newer build and stay as they are; compiled ones built for R $(minor "$CUR") may not load under $(minor "$TARGET")"
    RCRAN_UPG=""
  elif (( n_rc > 0 )); then
    log_info "R $(minor "$CUR") -> $(minor "$TARGET"): ${n_rc} installed r-cran-* package(s) are upgraded to the repository build in the same transaction"
    mapfile -t -O "${#INSTALL[@]}" INSTALL <<<"$RCRAN_UPG"
  else
    log_info "R $(minor "$CUR") -> $(minor "$TARGET"): every installed r-cran-* package is already at the repository build"
  fi
fi

DOWN=false
dpkg --compare-versions "$CUR" gt "$(awk -F'\t' '$1=="r-base-core"{print $3}' <<<"$PLAN")" && DOWN=true
if [[ "$DOWN" == true && "$ALLOW_DOWNGRADE" != true ]]; then
  log_error "this is a downgrade of R — refused without --allow-downgrade"; exit 3
fi
DG=(); [[ "$DOWN" == true ]] && DG=(--allow-downgrades)

SIM="$(apt-get -s "${APT_OPTS[@]}" install --no-remove "${DG[@]}" "${INSTALL[@]}" 2>&1)" \
  || { log_error "apt-get simulation failed:"; printf '%s\n' "$SIM" >&2; exit 1; }
if grep -q '^Remv' <<<"$SIM"; then
  log_error "the plan removes packages — refused:"; grep '^Remv' <<<"$SIM" | sed 's/^/  /' >&2; exit 3
fi
# every package the plan changes: "pkg<TAB>old<TAB>new" (old "-" = new install)
CHANGES="$(awk '$1=="Inst" { pkg=$2
  if ($3 ~ /^\[/) { old=$3; gsub(/[][]/,"",old); new=$4 } else { old="-"; new=$3 }
  sub(/^\(/,"",new); print pkg "\t" old "\t" new }' <<<"$SIM")"
n_chg=0; [[ -n "$CHANGES" ]] && n_chg="$(wc -l <<<"$CHANGES")"
log_info "apt changes ${n_chg} package(s):"
[[ -n "$CHANGES" ]] && awk -F'\t' '{printf "  %-30s %s -> %s\n", $1, $2, $3}' <<<"$CHANGES"

COVER=""; n_none=0
while IFS=$'\t' read -r pkg old _new; do
  [[ -z "$pkg" || "$old" == "-" ]] && continue
  src="$(can_save_deb "$pkg" "$old")"
  COVER+="${pkg}"$'\t'"${old}"$'\t'"${src}"$'\n'
  [[ "$src" == none ]] && n_none=$((n_none + 1))
done <<<"$CHANGES"
n_old="$(grep -c . <<<"$COVER" || true)"
log_info "rollback possible for $((n_old - n_none))/${n_old} replaced package(s)"
if (( n_none > 0 )); then
  log_warn "no old .deb for (apt cache, repository, dpkg-repack):"
  awk -F'\t' '$3=="none"{print "  " $1 " " $2}' <<<"$COVER" >&2
  command -v dpkg-repack >/dev/null 2>&1 || log_warn "dpkg-repack is not installed: it can rebuild them from the installed files"
fi

if [[ "$(minor "$CUR")" != "$(minor "$TARGET")" ]]; then
  old_m="$(minor "$CUR")"; new_m="$(minor "$TARGET")"; only_old=0; total=0
  shopt -s nullglob
  for d in "${USER_LIB_ROOT}"/*/R/x86_64-pc-linux-gnu-library/"${old_m}"; do
    [[ -n "$(ls -A "$d" 2>/dev/null)" ]] || continue   # empty library: nothing to lose
    total=$((total + 1)); [[ -n "$(ls -A "${d%/*}/${new_m}" 2>/dev/null)" ]] || only_old=$((only_old + 1))
  done
  shopt -u nullglob
  if (( only_old > 0 )); then
    log_warn "R ${old_m} -> ${new_m}: user libraries are per X.Y. ${total} user(s) have packages for ${old_m}, ${only_old} of them none for ${new_m}."
    log_warn "R ${new_m} will not see their ${old_m} packages; they reinstall them (bspm installs binaries). User libraries are not touched."
  else
    log_info "R ${old_m} -> ${new_m}: no user has packages for ${old_m} alone (${total} non-empty ${old_m} user libraries)"
  fi
fi

read -r s r <<<"$(sessions_active)"
log_info "running now: ${s} RStudio session(s), ${r} R process(es)"

if [[ "$MODE" == "dry-run" ]]; then
  log_info "dry-run: nothing changed. Apply with --commit (when no session runs)."
  exit 0
fi

# ── commit ──────────────────────────────────────────────────────────────────
log_head "Commit"
is_root || { log_error "--commit needs root"; exit 1; }
(( s + r == 0 )) || { log_error "${s} RStudio session(s), ${r} R process(es) running: upgrade R when idle — refused"; exit 3; }
if (( n_none > 0 )) && [[ "$ACCEPT_PARTIAL" != true ]]; then
  log_error "${n_none} package(s) cannot be rolled back — refused (--accept-partial-rollback overrides)"; exit 3
fi

BK="${BACKUP_ROOT}/r-version-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${BK}/debs" || { log_error "cannot create ${BK}"; exit 1; }
chmod 700 "$BK" || { log_error "chmod failed on ${BK}"; exit 1; }
all_r_pkgs > "${BK}/before.tsv"
printf '%s\n' "$CHANGES" > "${BK}/plan.tsv"
saved=0
while IFS=$'\t' read -r pkg old _src; do
  [[ -z "$pkg" ]] && continue
  [[ "$(save_deb "$pkg" "$old" "${BK}/debs")" != none ]] && saved=$((saved + 1))
done <<<"$COVER"
log_info "saved ${saved}/${n_old} old package(s) in ${BK}/debs"
if (( saved < n_old )) && [[ "$ACCEPT_PARTIAL" != true ]]; then
  log_error "could not save every old package — refused before any change. Backup dir: ${BK}"; exit 3
fi

if [[ "$LOAD_TEST" == true ]]; then
  log_info "load test before the change (every installed R package; this takes a few minutes)"
  load_test "${BK}/load_before.tsv" "${BK}/load_test.R"
  n_ok_before="$(grep -c $'\tOK$' "${BK}/load_before.tsv" || true)"
  log_info "before: ${n_ok_before} load, $(grep -c $'\tFAIL$' "${BK}/load_before.tsv" || true) fail"
  if (( n_ok_before == 0 )); then
    log_error "the load test loaded no package (Rscript broken?): nothing to measure against — refused, host unchanged. Backup dir: ${BK}"; exit 3
  fi
fi

read -r s r <<<"$(sessions_active)"
(( s + r == 0 )) || { log_error "a session started meanwhile — refused, host unchanged. Backup dir: ${BK}"; exit 3; }

if ! apt-get install -y "${APT_OPTS[@]}" --no-remove "${DG[@]}" "${INSTALL[@]}"; then
  log_error "apt-get install failed. Roll back with: sudo bash $0 --rollback ${BK}"; exit 1
fi
all_r_pkgs > "${BK}/after.tsv"
NOW_V="$(pkg_version r-base-core)"
if [[ "$(upstream "$NOW_V")" != "$TARGET" ]] || ! R --version >/dev/null 2>&1; then
  log_error "r-base-core is ${NOW_V:-missing} or R does not start. Roll back with: sudo bash $0 --rollback ${BK}"; exit 1
fi
log_ok "R is now $(R --version | head -1)"
restart_rstudio

if [[ "$LOAD_TEST" == true ]]; then
  load_test "${BK}/load_after.tsv" "${BK}/load_test.R"
  log_info "after: $(grep -c $'\tOK$' "${BK}/load_after.tsv" || true) load, $(grep -c $'\tFAIL$' "${BK}/load_after.tsv" || true) fail"
  REG="$(LC_ALL=C join -t $'\t' "${BK}/load_before.tsv" "${BK}/load_after.tsv" | awk -F'\t' '$2=="OK" && $3=="FAIL"{print $1}')"
  if [[ -n "$REG" ]]; then
    printf '%s\n' "$REG" > "${BK}/regressions.txt"
    log_error "$(wc -l <<<"$REG") package(s) loaded before and fail now: $(tr '\n' ' ' <<<"$REG")"
    log_error "Reinstall them (apt), or roll back: sudo bash $0 --rollback ${BK}"
    exit 5
  fi
  log_ok "no package stopped loading"
fi
log_ok "done. Backup: ${BK}"
log_info "Rollback: sudo bash $0 --rollback ${BK}"
log_info "Measure: scripts/99_check_pkg_host_drift.sh on every host (R version column)."
