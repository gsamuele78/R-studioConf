#!/usr/bin/env bash
set -euo pipefail
# tests/test_biome_node_maintenance.sh — scripts/biome_node_maintenance.sh (ADR-0007)
#
# pgrep, id, systemctl, unattended-upgrade, needrestart, apt-get, apt-config,
# logger and hostname are stubbed on PATH; state, systemd and needrestart dirs
# are fakes under mktemp. flock and perl are real. Never touches apt, systemd
# or /var.
#
# Exit: 0 all pass | 1 at least one failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SUT="${SCRIPT_DIR}/../scripts/biome_node_maintenance.sh"
readonly NR_TEMPLATE="${SCRIPT_DIR}/../templates/needrestart/biome-rstudio.conf.template"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; NC=""; }

command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
T="$(mktemp -d)"
HOLDER=""
cleanup() { [[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fails=0
pass() { printf "%sPASS%s %s\n" "$GREEN" "$NC" "$1"; }
fail() { printf "%sFAIL%s %s\n" "$RED" "$NC" "$1"; fails=$((fails + 1)); }
check() { if eval "$1"; then pass "$2"; else fail "$2"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fi; }

# ── stubs ──
mkdir -p "$T/bin"
cat > "$T/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *rsession*) n="$(cat "$STUB_SESS")"; echo "$n"; [[ "$n" -gt 0 ]]; exit ;;
  "-c -x R")  echo "${STUB_R:-0}"; [[ "${STUB_R:-0}" -gt 0 ]]; exit ;;
  *apt-get*)  [[ "${STUB_APT_BUSY:-0}" == 1 ]]; exit ;;
esac
echo 0; exit 1
EOF
cat > "$T/bin/id" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_UID:-0}"
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
[[ "$1" == is-enabled ]] && { echo "${STUB_APT_TIMER:-enabled}"; exit 0; }
[[ "$1 $2" == "restart rstudio-server" && "${STUB_RESTART_FAIL:-0}" == 1 ]] && exit 1
exit 0
EOF
cat > "$T/bin/unattended-upgrade" <<'EOF'
#!/usr/bin/env bash
echo "unattended-upgrade $*" >> "$STUB_LOG"
[[ -n "${STUB_SESS_AFTER_UU:-}" ]] && echo "$STUB_SESS_AFTER_UU" > "$STUB_SESS"
exit "${STUB_UU_RC:-0}"
EOF
cat > "$T/bin/needrestart" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -b ]] || exit 2
echo "NEEDRESTART-VER: 3.6"
echo "NEEDRESTART-KSTA: ${STUB_KSTA:-1}"
[[ "${STUB_NR_RSTUDIO:-0}" == 1 ]] && echo "NEEDRESTART-SVC: rstudio-server.service"
echo "NEEDRESTART-SVC: cron.service"
EOF
cat > "$T/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STUB_LOG"
EOF
cat > "$T/bin/apt-config" <<'EOF'
#!/usr/bin/env bash
echo 'APT::Periodic::Update-Package-Lists "1";'
echo "APT::Periodic::Unattended-Upgrade \"${STUB_UU_PERIODIC:-1}\";"
EOF
cat > "$T/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "logger $*" >> "$STUB_LOG"
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo "calc-test"
EOF
chmod +x "$T"/bin/*

reset_env() {
  rm -rf "$T/state" "$T/systemd" "$T/nr" "$T/log" "$T/sess"
  mkdir -p "$T/state" "$T/systemd" "$T/nr"
  : > "$T/log"; echo 0 > "$T/sess"
  unset STUB_R STUB_APT_BUSY STUB_SESS_AFTER_UU STUB_UU_RC STUB_KSTA STUB_NR_RSTUDIO STUB_UU_PERIODIC STUB_RESTART_FAIL STUB_APT_TIMER
}
run() {  # args...
  set +e
  OUT="$(PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_SESS="$T/sess" \
         MAINT_STATE_DIR="$T/state" MAINT_SYSTEMD_DIR="$T/systemd" MAINT_NEEDRESTART_DIR="$T/nr" \
         MAINT_LOCK="$T/run.lock" MAINT_PKG_SYNC_LOCK="$T/pkgsync.lock" \
         MAINT_NOW="${NOW:-0345}" MAINT_TODAY="${TODAY:-2026-10-29}" \
         bash "$SUT" "$@" 2>&1)"
  # shellcheck disable=SC2034  # read inside the eval'd check strings
  RC=$?
  set -e
}
report() { jq -r ".$1" "$T/state/last_report.json" 2>/dev/null || true; }
uu_called() { grep -q '^unattended-upgrade' "$T/log"; }
restarted() { grep -q '^systemctl restart rstudio-server' "$T/log"; }

echo "## gates"
reset_env; NOW=0200 run
check '[[ $RC -eq 0 ]] && ! uu_called && [[ "$OUT" == *"outside the window"* ]]' "outside the window: exit 0, no upgrade"

reset_env; echo 2 > "$T/sess"; NOW=0345 run
check '[[ $RC -eq 75 ]] && ! uu_called && [[ "$(report status)" == deferred ]]' "RStudio sessions: deferred (75), no upgrade"
check '[[ "$(cat "$T/state/first_deferred")" == 2026-10-29 ]] && [[ "$(report note)" == *"retry at 04:00"* ]]' "deferral recorded, next slot named"

reset_env; NOW=0445 STUB_R=1 run
check '[[ $RC -eq 75 ]] && [[ "$(report note)" == *"moves to the next night"* ]]' "R process in tmux counts as busy; last slot moves to the next night"

reset_env; echo 2026-10-25 > "$T/state/first_deferred"; echo 1 > "$T/sess"; run
check '[[ $RC -eq 75 && "$(report status)" == overdue ]] && grep -q "logger -t biome-node-maintenance -p daemon.warning" "$T/log"' "4 nights deferred (>= 3): overdue + journal warning"

reset_env; ( exec 8>"$T/pkgsync.lock"; flock 8; exec sleep 30 ) & HOLDER=$!; sleep 0.3; run
kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true; HOLDER=""
check '[[ $RC -eq 75 ]] && ! uu_called && [[ "$(report note)" == *"package sync running"* ]]' "package sync holds its lock: deferred, no upgrade"

reset_env; : > "$T/pkgsync.lock"; run
check '[[ $RC -eq 0 ]] && uu_called' "package sync lock file present but free: runs"

reset_env; STUB_APT_BUSY=1 run
check '[[ $RC -eq 75 ]] && ! uu_called && [[ "$(report note)" == *"apt/dpkg busy"* ]]' "apt/dpkg busy: deferred"

reset_env; STUB_UU_PERIODIC=0 run
check '[[ $RC -eq 0 && "$(report status)" == skipped ]] && ! uu_called' "APT::Periodic::Unattended-Upgrade 0 respected: no upgrade"

echo "## upgrade + restart"
reset_env; echo 2026-10-28 > "$T/state/first_deferred"; STUB_NR_RSTUDIO=1 run
check '[[ $RC -eq 0 && "$(report status)" == done ]] && uu_called && restarted' "free node: upgrade, then rstudio-server restart"
check '[[ "$(cat "$T/state/done_date")" == 2026-10-29 && ! -e "$T/state/first_deferred" ]]' "done-marker written, deferral streak cleared"
check 'grep -q "^apt-get update" "$T/log"' "package lists refreshed first"
run
check '[[ $RC -eq 0 && "$OUT" == *"already done tonight"* ]] && [[ $(grep -c "^unattended-upgrade" "$T/log") -eq 1 ]]' "second slot the same night: nothing to do"

reset_env; run
check '[[ $RC -eq 0 ]] && uu_called && ! restarted && [[ "$(report rstudio_restart)" == "not needed" ]]' "no restart when needrestart does not list rstudio-server"

reset_env; STUB_NR_RSTUDIO=1 STUB_SESS_AFTER_UU=1 run
check '[[ $RC -eq 75 ]] && uu_called && ! restarted && [[ ! -e "$T/state/done_date" ]] && [[ "$(report rstudio_restart)" == pending* ]]' "session opened during the upgrade: restart pending, retried next slot"

reset_env; STUB_NR_RSTUDIO=1 MAINT_RESTART_RSTUDIO=false run
check '[[ $RC -eq 0 ]] && ! restarted && [[ "$(report rstudio_restart)" == *"disabled"* ]]' "MAINT_RESTART_RSTUDIO=false: reported, not restarted"

reset_env; STUB_NR_RSTUDIO=1 STUB_RESTART_FAIL=1 run
check '[[ $RC -eq 1 && "$(report status)" == failed && ! -e "$T/state/done_date" ]]' "restart failure: exit 1, not marked done"

reset_env; STUB_UU_RC=1 run
check '[[ $RC -eq 1 && "$(report status)" == failed && ! -e "$T/state/done_date" ]]' "unattended-upgrade failure: exit 1, not marked done"

reset_env; STUB_KSTA=3 run
check '[[ $RC -eq 0 && "$(report needrestart_kernel_status)" == 3 ]] && [[ "$OUT" == *"reboot this node"* ]] && ! grep -q reboot "$T/log"' "pending kernel: reported, never rebooted"

reset_env; STUB_UID=1000 run
check '[[ $RC -eq 1 ]] && ! uu_called' "non-root run refused"

reset_env; MAINT_WINDOW_START=0500 MAINT_WINDOW_END=0330 run
check '[[ $RC -eq 2 ]]' "window across midnight rejected (exit 2)"

echo "## install / remove (in-place, rollback)"
reset_env; run --install-timer
check '[[ $RC -eq 0 && -f "$T/nr/biome-rstudio.conf" && -f "$T/systemd/biome-node-maintenance.service" ]]' "install writes needrestart fragment and units"
check 'grep -q "OnCalendar=\*-\*-\* 03..04:00/15:00" "$T/systemd/biome-node-maintenance.timer"' "timer covers 03:00-04:45 for the 0330-0500 window"
check 'grep -q "ExecStart=/usr/bin/env bash .*/scripts/biome_node_maintenance.sh" "$T/systemd/biome-node-maintenance.service"' "service runs the repo script"
check 'grep -q "systemctl disable --now apt-daily-upgrade.timer" "$T/log" && grep -q "systemctl enable --now biome-node-maintenance.timer" "$T/log"' "stock upgrade timer disabled, ours enabled"
check '[[ "$(cat "$T/state/apt_upgrade_timer_was")" == enabled ]]' "previous apt-daily-upgrade.timer state saved"
STUB_APT_TIMER=disabled run --install-timer
check '[[ $RC -eq 0 && "$(cat "$T/state/apt_upgrade_timer_was")" == enabled ]]' "re-install is idempotent and keeps the original timer state"
run --remove-timer
check '[[ $RC -eq 0 && ! -e "$T/nr/biome-rstudio.conf" && ! -e "$T/systemd/biome-node-maintenance.timer" ]] && grep -q "systemctl enable --now apt-daily-upgrade.timer" "$T/log"' "remove = rollback: files gone, stock timer back"

echo "## needrestart fragment"
if command -v perl >/dev/null 2>&1; then
  res="$(perl -e 'our %nrconf; do $ARGV[0]; die $@ if $@;
                  my ($re) = grep { $nrconf{override_rc}{$_} == 0 } keys %{$nrconf{override_rc}};
                  print join(",", map { $_ =~ $re ? 1 : 0 } qw(rstudio-server.service nginx.service sssd.service)), "\n"' "$NR_TEMPLATE" 2>&1)"
  if [[ "$res" == "1,0,0" ]]; then pass "fragment parses; excludes rstudio-server.service only"; else fail "needrestart fragment: got '$res'"; fi
else
  echo "SKIP: perl not available"
fi

echo
if (( fails > 0 )); then echo "${fails} test(s) failed"; exit 1; fi
echo "all tests passed"
