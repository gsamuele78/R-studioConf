#!/usr/bin/env bash
set -euo pipefail
# scripts/biome_node_maintenance.sh
#
# OS updates (unattended-upgrades) and the rstudio-server restart they need,
# only inside the night window and only when the node is free (ADR-0007).
#
# Why: on biome-calc01 on 2026-10-28 at 06:26 the stock apt-daily-upgrade.timer
# upgraded libbrotli, and needrestart restarted rstudio-server. Stopping the
# service suspends every RStudio session: each session's whole R environment is
# written to ~/.local/share/rstudio on NFS and read back at the next login. One
# researcher's environment was 765 MB, and his login hung on "Loading…".
#
# What --install-timer changes on the host:
#   * NEW  /etc/needrestart/conf.d/biome-rstudio.conf: needrestart never
#          restarts rstudio-server (other services are restarted as before)
#   * NEW  biome-node-maintenance.{service,timer} in /etc/systemd/system
#   * apt-daily-upgrade.timer disabled (its state is saved for --remove-timer).
#     apt-daily.timer (package lists refresh) is left alone.
#
# Each run (timer: every 15 minutes, 03:00-05:00 by default; work from 03:30):
#   1. gate   stop unless: inside the window, not done tonight, the R package
#             sync is not running on this node, apt/dpkg is idle, and no
#             RStudio session or R process runs. Nothing is ever killed.
#             A deferred run exits 75 and the next slot retries; after the
#             last slot the work moves to the next night. After
#             MAINT_OVERDUE_NIGHTS deferred nights it logs a warning.
#   2. update apt-get update, then unattended-upgrade (its own origins
#             config, /etc/apt/apt.conf.d/50unattended-upgrades)
#   3. restart if needrestart lists rstudio-server and the node is STILL free,
#             restart it; otherwise leave it pending for the next slot
#   4. report JSON in MAINT_STATE_DIR/last_report.json; a pending kernel
#             reboot is reported, never done
# Locks are local to the node: no node waits for another.
#
# Usage:
#   sudo bash scripts/biome_node_maintenance.sh                  # one run (what the timer does)
#   sudo bash scripts/biome_node_maintenance.sh --plan           # gates + needrestart, change nothing
#   bash scripts/biome_node_maintenance.sh --status              # last report and deferral state
#   sudo bash scripts/biome_node_maintenance.sh --install-timer  # in-place install (idempotent)
#   sudo bash scripts/biome_node_maintenance.sh --remove-timer   # rollback: stock behaviour back
#   Options: --force-window (ignore the window and tonight's done-marker; for a
#            supervised manual run; the session gate still applies), -h|--help
# Settings: config/node_maintenance.vars.conf, site overrides in
#           config/site/node_maintenance.site.vars.conf.
#
# Exit: 0 done / nothing to do / outside window | 1 failed | 2 usage error
#       75 deferred (sessions, package sync or apt busy)

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

# shellcheck source=../config/node_maintenance.vars.conf disable=SC1091
source "${WORKSPACE_ROOT}/config/node_maintenance.vars.conf"
SITE_CONF="${WORKSPACE_ROOT}/config/site/node_maintenance.site.vars.conf"
# shellcheck source=/dev/null
[[ -f "${SITE_CONF}" ]] && source "${SITE_CONF}"

SYSTEMD_DIR="${MAINT_SYSTEMD_DIR:-/etc/systemd/system}"
NEEDRESTART_DIR="${MAINT_NEEDRESTART_DIR:-/etc/needrestart/conf.d}"
LOCK_FILE="${MAINT_LOCK:-/run/lock/biome-node-maintenance.lock}"
NR_CONF="${NEEDRESTART_DIR}/biome-rstudio.conf"
APT_OPTS=(-q -o DPkg::Lock::Timeout=300)
TAG="biome-node-maintenance"

ACTION="run"; FORCE_WINDOW=false
usage() { sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)          ACTION="plan"; shift ;;
    --status)        ACTION="status"; shift ;;
    --install-timer) ACTION="install-timer"; shift ;;
    --remove-timer)  ACTION="remove-timer"; shift ;;
    --force-window)  FORCE_WINDOW=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) log_error "unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done

for bin in jq pgrep awk flock date hostname; do
  command -v "$bin" >/dev/null 2>&1 || { log_error "required binary not found: $bin"; exit 1; }
done
for v in MAINT_WINDOW_START MAINT_WINDOW_END; do
  [[ "${!v}" =~ ^([01][0-9]|2[0-3])[0-5][0-9]$ ]] || { log_error "${v} must be HHMM, not '${!v}'"; exit 2; }
done
(( 10#$MAINT_WINDOW_START < 10#$MAINT_WINDOW_END )) \
  || { log_error "MAINT_WINDOW_START must be before MAINT_WINDOW_END (a window across midnight is not supported)"; exit 2; }
[[ "$MAINT_OVERDUE_NIGHTS" =~ ^[0-9]+$ ]] || { log_error "MAINT_OVERDUE_NIGHTS must be a number"; exit 2; }
[[ "$MAINT_RESTART_RSTUDIO" == true || "$MAINT_RESTART_RSTUDIO" == false ]] \
  || { log_error "MAINT_RESTART_RSTUDIO must be true or false"; exit 2; }

is_root()  { [[ "$(id -u)" -eq 0 ]]; }
now_hhmm() { echo "${MAINT_NOW:-$(date +%H%M)}"; }
today()    { echo "${MAINT_TODAY:-$(date +%F)}"; }
utc_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

write_atomic() {
  local file="$1" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  cat > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$file"
}

sessions_active() {  # prints "<rsession> <R>" (same test as biome_pkg_sync.sh)
  local s r
  s="$(pgrep -c -x rsession 2>/dev/null || true)"; r="$(pgrep -c -x R 2>/dev/null || true)"
  echo "${s:-0} ${r:-0}"
}

apt_busy() {  # an apt/dpkg frontend is running (e.g. an operator's manual upgrade)
  pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr' >/dev/null 2>&1
}

pkg_sync_busy() {  # biome_pkg_sync.sh holds its flock for its whole run
  [[ -e "$MAINT_PKG_SYNC_LOCK" ]] || return 1
  ! flock -n "$MAINT_PKG_SYNC_LOCK" true 2>/dev/null
}

# rstudio-server needs a restart according to needrestart (batch mode lists,
# never restarts). Prints the kernel status line too.
needrestart_state() {  # prints "<svc yes|no|unknown> <kernel status 0-3|unknown>"
  local out svc="no" ksta="unknown"
  if ! command -v needrestart >/dev/null 2>&1; then echo "unknown unknown"; return 0; fi
  out="$(needrestart -b 2>/dev/null || true)"
  grep -q '^NEEDRESTART-SVC: rstudio-server' <<<"$out" && svc="yes"
  ksta="$(awk -F': ' '$1=="NEEDRESTART-KSTA"{print $2; exit}' <<<"$out")"
  echo "$svc ${ksta:-unknown}"
}

nights_deferred() {  # whole days since the first deferral of this streak
  local f="${MAINT_STATE_DIR}/first_deferred" first
  first="$(cat "$f" 2>/dev/null || true)"
  [[ -n "$first" ]] || { echo 0; return 0; }
  echo $(( ( $(date -d "$(today)" +%s) - $(date -d "$first" +%s) ) / 86400 ))
}

REPORT_STATUS="unknown"; REPORT_NOTE=""; REPORT_UPGRADE="not run"; REPORT_RESTART="not needed"; REPORT_KERNEL="unknown"
finish() {  # STATUS NOTE EXIT
  REPORT_STATUS="$1"; REPORT_NOTE="$2"
  if [[ -d "$MAINT_STATE_DIR" ]]; then
    jq -n --arg host "$(hostname -s)" --arg at "$(utc_now)" --arg status "$REPORT_STATUS" \
          --arg note "$REPORT_NOTE" --arg upgrade "$REPORT_UPGRADE" --arg restart "$REPORT_RESTART" \
          --arg kernel "$REPORT_KERNEL" --argjson nights "$(nights_deferred)" \
      '{schema: 1, host: $host, finished_at: $at, status: $status, note: $note, upgrade: $upgrade,
        rstudio_restart: $restart, needrestart_kernel_status: $kernel, nights_deferred: $nights}' \
      | write_atomic "${MAINT_STATE_DIR}/last_report.json"
  fi
  log_info "result: $1: $2"
  exit "$3"
}

# Where a deferred run goes next: the next 15-minute slot, or the next night.
next_slot_note() {
  local n m
  n="$(now_hhmm)"; m=$(( 10#${n:0:2} * 60 + 10#${n:2:2} ))
  m=$(( (m / 15 + 1) * 15 ))
  if (( m >= 10#${MAINT_WINDOW_END:0:2} * 60 + 10#${MAINT_WINDOW_END:2:2} )); then
    echo "last slot tonight, moves to the next night"
  else
    printf 'retry at %02d:%02d' $(( m / 60 )) $(( m % 60 ))
  fi
}

defer() {  # REASON
  local f="${MAINT_STATE_DIR}/first_deferred" n
  [[ -s "$f" ]] || today > "$f"
  n="$(nights_deferred)"
  if (( n >= MAINT_OVERDUE_NIGHTS )); then
    if command -v logger >/dev/null 2>&1; then
      logger -t "$TAG" -p daemon.warning "OS updates deferred for ${n} night(s) on $(hostname -s): $1" || true
    fi
    finish overdue "deferred for ${n} night(s): $1: $(next_slot_note)" 75
  fi
  finish deferred "$1: $(next_slot_note)" 75
}

# ── status (read-only) ──────────────────────────────────────────────────────
if [[ "$ACTION" == "status" ]]; then
  if [[ -f "${MAINT_STATE_DIR}/last_report.json" ]]; then
    jq -r '"last run: \(.status) at \(.finished_at): \(.note)",
           "  upgrade: \(.upgrade); rstudio restart: \(.rstudio_restart); kernel status: \(.needrestart_kernel_status); nights deferred: \(.nights_deferred)"' \
      "${MAINT_STATE_DIR}/last_report.json"
  else
    log_warn "no report yet in ${MAINT_STATE_DIR}"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    log_info "biome-node-maintenance.timer: $(systemctl is-enabled biome-node-maintenance.timer 2>/dev/null || true); apt-daily-upgrade.timer: $(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)"
  fi
  if [[ -f "$NR_CONF" ]]; then log_ok "needrestart leaves rstudio-server alone (${NR_CONF})"
  else log_warn "needrestart may restart rstudio-server (${NR_CONF} missing)"; fi
  exit 0
fi

# ── install / remove (in-place, idempotent; remove = rollback) ──────────────
if [[ "$ACTION" == "install-timer" || "$ACTION" == "remove-timer" ]]; then
  is_root || { log_error "--${ACTION} needs root"; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { log_error "systemctl not found"; exit 1; }
  mkdir -p "$MAINT_STATE_DIR" || { log_error "cannot create ${MAINT_STATE_DIR}"; exit 1; }
  if [[ "$ACTION" == "remove-timer" ]]; then
    systemctl disable --now biome-node-maintenance.timer 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/biome-node-maintenance.service" "${SYSTEMD_DIR}/biome-node-maintenance.timer" "$NR_CONF"
    systemctl daemon-reload
    was="$(cat "${MAINT_STATE_DIR}/apt_upgrade_timer_was" 2>/dev/null || echo enabled)"
    if [[ "$was" == enabled ]]; then
      systemctl enable --now apt-daily-upgrade.timer || { log_error "could not re-enable apt-daily-upgrade.timer"; exit 1; }
      log_ok "apt-daily-upgrade.timer re-enabled (stock behaviour)"
    else
      log_info "apt-daily-upgrade.timer left ${was}, as it was before --install-timer"
    fi
    log_ok "removed: timer, service and ${NR_CONF} (reports in ${MAINT_STATE_DIR} are kept)"
    exit 0
  fi
  command -v unattended-upgrade >/dev/null 2>&1 \
    || { log_error "unattended-upgrade not found (apt install unattended-upgrades)"; exit 1; }
  tpl="${WORKSPACE_ROOT}/templates"
  # save the stock timer state once, so --remove-timer restores what was there
  if [[ ! -f "${MAINT_STATE_DIR}/apt_upgrade_timer_was" ]]; then
    st="$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)"
    printf '%s\n' "${st:-unknown}" > "${MAINT_STATE_DIR}/apt_upgrade_timer_was"
  fi
  if [[ -d "$NEEDRESTART_DIR" ]]; then
    write_atomic "$NR_CONF" < "${tpl}/needrestart/biome-rstudio.conf.template"
    if command -v perl >/dev/null 2>&1 \
       && ! perl -e 'our %nrconf; do $ARGV[0]; die $@ if $@; die "no override_rc\n" unless $nrconf{override_rc}' "$NR_CONF" 2>/dev/null; then
      rm -f "$NR_CONF"; log_error "needrestart fragment does not parse: removed, nothing else changed"; exit 1
    fi
    log_ok "needrestart will not restart rstudio-server: ${NR_CONF}"
  else
    log_warn "${NEEDRESTART_DIR} not found (needrestart not installed): nothing restarts rstudio-server on upgrade anyway"
  fi
  sed -e "s|%%SCRIPT%%|${SCRIPT_DIR}/biome_node_maintenance.sh|g" \
      "${tpl}/systemd/biome-node-maintenance.service.template" \
    | write_atomic "${SYSTEMD_DIR}/biome-node-maintenance.service"
  start="${MAINT_WINDOW_START:0:2}"; last="${MAINT_WINDOW_END:0:2}"
  [[ "${MAINT_WINDOW_END:2:2}" == "00" ]] && last=$(( 10#$last - 1 ))
  sed "s|%%HOURS%%|${start}..$(printf '%02d' "$((10#$last))")|g" "${tpl}/systemd/biome-node-maintenance.timer.template" \
    | write_atomic "${SYSTEMD_DIR}/biome-node-maintenance.timer"
  systemctl daemon-reload
  systemctl disable --now apt-daily-upgrade.timer 2>/dev/null || true
  systemctl enable --now biome-node-maintenance.timer \
    || { log_error "could not enable biome-node-maintenance.timer; undo: sudo bash $0 --remove-timer"; exit 1; }
  log_ok "installed: OS updates ${MAINT_WINDOW_START}-${MAINT_WINDOW_END} on a free node; next runs: systemctl list-timers biome-node-maintenance.timer"
  log_info "undo: sudo bash $0 --remove-timer"
  exit 0
fi

# ── run / plan ───────────────────────────────────────────────────────────────
if [[ "$ACTION" == "plan" ]]; then
  now="$(now_hhmm)"
  log_info "window ${MAINT_WINDOW_START}-${MAINT_WINDOW_END}, now ${now}: $( (( 10#$now >= 10#$MAINT_WINDOW_START && 10#$now < 10#$MAINT_WINDOW_END )) && echo inside || echo outside)"
  read -r s r <<<"$(sessions_active)"
  log_info "RStudio sessions: ${s}, R processes: ${r} ($( (( s + r == 0 )) && echo free || echo busy))"
  if pkg_sync_busy; then log_info "package sync: running"; else log_info "package sync: idle"; fi
  if apt_busy; then log_info "apt/dpkg: busy"; else log_info "apt/dpkg: idle"; fi
  read -r svc ksta <<<"$(needrestart_state)"
  log_info "rstudio-server needs restart: ${svc}; needrestart kernel status: ${ksta} (3 = reboot needed)"
  log_info "deferred nights in a row: $(nights_deferred 2>/dev/null || echo 0)"
  exit 0
fi

is_root || { log_error "a run needs root"; exit 1; }
mkdir -p "$MAINT_STATE_DIR" || { log_error "cannot create ${MAINT_STATE_DIR}"; exit 1; }
exec 9>"${LOCK_FILE}"
flock -n 9 || { log_warn "another run is active: exiting"; exit 0; }

now="$(now_hhmm)"
if [[ "$FORCE_WINDOW" != true ]]; then
  if (( 10#$now < 10#$MAINT_WINDOW_START || 10#$now >= 10#$MAINT_WINDOW_END )); then
    log_info "outside the window ${MAINT_WINDOW_START}-${MAINT_WINDOW_END}: nothing to do"; exit 0
  fi
  if [[ "$(cat "${MAINT_STATE_DIR}/done_date" 2>/dev/null || true)" == "$(today)" ]]; then
    log_info "already done tonight: nothing to do"; exit 0
  fi
fi

pkg_sync_busy && defer "R package sync running on this node"
apt_busy && defer "apt/dpkg busy"
read -r s r <<<"$(sessions_active)"
(( s + r == 0 )) || defer "${s} RStudio session(s), ${r} R process(es) running"

command -v unattended-upgrade >/dev/null 2>&1 || finish failed "unattended-upgrade not found" 1
# Respect the host's apt policy: the stock timer would not upgrade either.
uu_on="$(apt-config dump 2>/dev/null | awk '$1=="APT::Periodic::Unattended-Upgrade"{gsub(/[";]/, "", $2); print $2}' | tail -n 1)"
if [[ "${uu_on:-0}" == "0" ]]; then
  today > "${MAINT_STATE_DIR}/done_date"
  finish skipped "APT::Periodic::Unattended-Upgrade is off on this host (/etc/apt/apt.conf.d/20auto-upgrades)" 0
fi
apt-get update "${APT_OPTS[@]}" >/dev/null 2>&1 || log_warn "apt-get update failed: upgrading from the current lists"
set +e
unattended-upgrade
uu_rc=$?
set -e
if (( uu_rc != 0 )); then
  REPORT_UPGRADE="failed (rc ${uu_rc}, see /var/log/unattended-upgrades/)"
  finish failed "unattended-upgrade exit ${uu_rc}" 1
fi
REPORT_UPGRADE="done"
rm -f "${MAINT_STATE_DIR}/first_deferred"

read -r svc ksta <<<"$(needrestart_state)"
REPORT_KERNEL="$ksta"
[[ "$ksta" == 3 ]] && log_warn "a newer kernel is installed: reboot this node in a maintenance slot (never done automatically)"
if [[ "$svc" == yes ]]; then
  read -r s r <<<"$(sessions_active)"
  if [[ "$MAINT_RESTART_RSTUDIO" != true ]]; then
    REPORT_RESTART="needed, disabled by MAINT_RESTART_RSTUDIO=false"
  elif (( s + r > 0 )); then
    # someone logged in during the upgrade: retry the restart at the next slot
    REPORT_RESTART="pending: ${s} session(s) started during the upgrade"
    finish deferred "upgrade done, rstudio-server restart pending: $(next_slot_note)" 75
  elif systemctl restart rstudio-server; then
    REPORT_RESTART="done"; log_ok "rstudio-server restarted on a free node"
  else
    REPORT_RESTART="failed"
    finish failed "systemctl restart rstudio-server failed: systemctl status rstudio-server" 1
  fi
fi
today > "${MAINT_STATE_DIR}/done_date"
finish "done" "upgrade done; rstudio-server restart: ${REPORT_RESTART}" 0
