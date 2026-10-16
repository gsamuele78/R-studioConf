#!/usr/bin/env bash
set -euo pipefail
# scripts/fix_bspm_dbus_inplace.sh
#
# IN-PLACE HOTFIX: let researchers install R packages through bspm WITHOUT sudo,
# by registering bspm's own D-Bus system service (ADR-0005).
#
# Why: bspm today works only through sudo. Step 7 of 50_setup_nodes.sh writes
#   %domain_users ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt-mark, /usr/bin/dpkg, .../bspm.py
# Unrestricted sudo apt-get/dpkg is root for every domain user, and sudo
# bspm.py is root too (its `-o FILE` appends user text to any path as root).
# The CRAN bspm package ships the D-Bus service but does not register it; once
# registered, the service runs as root and exposes only install/available/
# discover/remove of r-cran-* packages. This hotfix allows `install`,
# `available` and `discover` to one group and denies everything else,
# including `remove`.
#
# What it changes:
#   * NEW  /etc/dbus-1/system.d/org.r_project.linux1.conf          (bus policy)
#   * NEW  /usr/share/dbus-1/system-services/org.r_project.linux1.service
#   * EDIT /etc/R/Rprofile.site: `bspm.sudo = TRUE` -> `bspm.sudo = FALSE`
#          (exactly the two occurrences of the v12 dispatcher; refuses otherwise)
#   * `systemctl reload dbus` (re-reads policy; no session or service restart)
#   Sudoers is NOT touched: removing the sudo lines is a separate decision,
#   taken only after the service is verified (ADR-0005).
#
# Safety:
#   * dry-run by default; --commit applies; --rollback DIR undoes.
#   * pre-checks: bspm.py and every parent dir root-owned and not group/other
#     writable; python3 can import dbus, gi, apt; the group resolves (getent).
#   * backup + manifest in ${BACKUP_ROOT}/bspm-dbus-hotfix-<ts>/ BEFORE any write.
#   * each file written to a temp name in its directory, then mv (atomic).
#   * after reload, the service must answer an Introspect call as root;
#     otherwise every change is rolled back automatically (exit 1).
#
# Known residual risk (upstream bspm, not fixable here): service methods take a
# caller-supplied pid and write apt's output to /proc/<pid>/fd/2 as root.
#
# Usage:
#   sudo bash scripts/fix_bspm_dbus_inplace.sh                   # dry-run
#   sudo bash scripts/fix_bspm_dbus_inplace.sh --commit
#   sudo bash scripts/fix_bspm_dbus_inplace.sh --rollback DIR
#   Options: --group NAME (default domain_users)
#            --skip-profile  register the service only, leave Rprofile.site alone
#                            (used by 50_setup_nodes.sh Step 7, which renders a
#                            profile that already has bspm.sudo = FALSE)
#            -h|--help
#   Env:     FIX_BSPM_ROOT        (default "", prefix for every path; tests only)
#            FIX_BSPM_BACKUP_ROOT (default /root)
#            FIX_BSPM_PYTHON      (default python3)
#
# Verify as a researcher afterwards (RStudio web, or no terminal):
#   setsid -w Rscript -e 'install.packages("praise"); cat(find.package("praise"), "\n")' < /dev/null
#
# Exit codes:
#   0 applied, already applied, dry-run, or rolled back
#   1 refused or failed (rolled back where stated)
#   2 usage error

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

R="${FIX_BSPM_ROOT:-}"
BACKUP_ROOT="${FIX_BSPM_BACKUP_ROOT:-/root}"
PYTHON="${FIX_BSPM_PYTHON:-python3}"

readonly BUS_NAME="org.r_project.linux1"
readonly IFACE="org.r_project.linux1.PackageManager"
readonly OPATH="/org/r_project/linux1/PackageManager"
BSPM_PY="${R}/usr/lib/R/site-library/bspm/service/bspm.py"
POLICY="${R}/etc/dbus-1/system.d/${BUS_NAME}.conf"
SERVICE="${R}/usr/share/dbus-1/system-services/${BUS_NAME}.service"
PROFILE="${R}/etc/R/Rprofile.site"

MODE="dry-run"
ROLLBACK_DIR=""
GROUP="domain_users"
SKIP_PROFILE=0

usage() { sed -n '3,58p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit) MODE="commit"; shift ;;
    --rollback)
      [[ $# -ge 2 ]] || { log_error "--rollback needs a backup directory"; exit 2; }
      MODE="rollback"; ROLLBACK_DIR="$2"; shift 2 ;;
    --group)
      [[ $# -ge 2 ]] || { log_error "--group needs a name"; exit 2; }
      GROUP="$2"; shift 2 ;;
    --skip-profile) SKIP_PROFILE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done

for bin in systemctl dbus-send getent stat; do
  command -v "$bin" >/dev/null 2>&1 || { log_error "required binary not found: $bin"; exit 1; }
done
is_root() { [[ "$(id -u)" -eq 0 ]]; }

reload_dbus() { systemctl reload dbus; }

# DBUS_ERR keeps dbus-send's error text for the failure report
DBUS_ERR=""
service_answers() {
  DBUS_ERR="$(dbus-send --system --print-reply --reply-timeout=10000 --dest="$BUS_NAME" "$OPATH" \
    org.freedesktop.DBus.Introspectable.Introspect 2>&1 >/dev/null)" && return 0
  return 1
}

xml_escape() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; printf '%s' "$s"; }

render_policy() {
  local g; g="$(xml_escape "$GROUP")"
  cat <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<!-- Managed by R-studioConf scripts/fix_bspm_dbus_inplace.sh (ADR-0005). -->
<busconfig>
  <policy user="root">
    <allow own="${BUS_NAME}"/>
    <allow send_destination="${BUS_NAME}"/>
  </policy>
  <policy context="default">
    <deny send_destination="${BUS_NAME}"/>
  </policy>
  <policy group="${g}">
    <allow send_destination="${BUS_NAME}" send_interface="${IFACE}" send_member="install"/>
    <allow send_destination="${BUS_NAME}" send_interface="${IFACE}" send_member="available"/>
    <allow send_destination="${BUS_NAME}" send_interface="${IFACE}" send_member="discover"/>
    <allow send_destination="${BUS_NAME}" send_interface="org.freedesktop.DBus.Introspectable" send_member="Introspect"/>
    <!-- explicit, last. dbus-daemon rejects the WHOLE file if a member rule has
         no interface, so every rule here names one (2026-10-16 test-host failure). -->
    <deny send_destination="${BUS_NAME}" send_interface="${IFACE}" send_member="remove"/>
  </policy>
</busconfig>
EOF
}

render_service() {
  cat <<EOF
# Managed by R-studioConf scripts/fix_bspm_dbus_inplace.sh (ADR-0005).
[D-BUS Service]
Name=${BUS_NAME}
Exec=/usr/lib/R/site-library/bspm/service/bspm.py
User=root
EOF
}

# atomic write: temp file in the target dir, mode 0644 root, then mv
atomic_write() {
  local dest="$1" content="$2" tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || return 1
  if printf '%s\n' "$content" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$dest"; then return 0; fi
  rm -f "$tmp"; return 1
}

do_rollback() {
  local dir="$1"
  [[ -f "${dir}/manifest" ]] || { log_error "not a backup dir (no manifest): ${dir}"; return 1; }
  local kind path rc=0
  while IFS=$'\t' read -r kind path; do
    case "$kind" in
      created)  rm -f "${R}${path}" && log_info "removed ${path}" || rc=1 ;;
      replaced) cp -p "${dir}/files${path}" "${R}${path}" && log_info "restored ${path}" || rc=1 ;;
    esac
  done < "${dir}/manifest"
  reload_dbus || { log_warn "systemctl reload dbus failed"; rc=1; }
  return "$rc"
}

# ── rollback ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "rollback" ]]; then
  log_head "Rollback from ${ROLLBACK_DIR}"
  is_root || { log_error "--rollback needs root"; exit 1; }
  if do_rollback "$ROLLBACK_DIR"; then log_ok "rollback complete"; exit 0; fi
  log_error "rollback incomplete (see messages above)"; exit 1
fi

# ── pre-checks ──────────────────────────────────────────────────────────────
log_head "Pre-checks (mode: ${MODE})"
fail=0
[[ -f "$BSPM_PY" ]] || { log_error "bspm service not found: ${BSPM_PY#"$R"} (is bspm installed system-wide?)"; exit 1; }

# bspm.py and every parent dir must be root-owned and not group/other writable,
# otherwise a user could swap the code the root service runs.
p="$BSPM_PY"
while :; do
  read -r owner perms < <(stat -c '%U %a' "$p")
  if [[ "$owner" != root ]] || (( (8#$perms & 8#022) != 0 )); then
    log_error "unsafe ownership/mode on ${p#"$R"}: ${owner} ${perms} (needs root, no group/other write)"; fail=1
  fi
  [[ "$p" == "${R:-/}" || "$p" == "/" ]] && break
  p="$(dirname "$p")"
done
[[ $fail -eq 0 ]] && log_ok "bspm.py and parent directories are root-owned and not writable by others"

if "$PYTHON" -c 'import dbus, gi, apt' >/dev/null 2>&1; then
  log_ok "python3 modules dbus, gi, apt importable"
else
  log_error "python3 cannot import dbus/gi/apt (apt install python3-dbus python3-gi python3-apt)"; fail=1
fi

if getent group "$GROUP" >/dev/null 2>&1; then
  log_ok "group '${GROUP}' resolves"
else
  log_error "group '${GROUP}' does not resolve (getent group). Use --group NAME."; fail=1
fi

n_sudo_true=0; n_sudo_false=0
if [[ $SKIP_PROFILE -eq 0 && ! -f "$PROFILE" ]]; then
  log_error "missing ${PROFILE#"$R"} (use --skip-profile to register the service only)"; fail=1
elif [[ $SKIP_PROFILE -eq 0 ]]; then
  n_sudo_true="$(grep -c 'bspm\.sudo = TRUE' "$PROFILE" || true)"
  n_sudo_false="$(grep -c 'bspm\.sudo = FALSE' "$PROFILE" || true)"
  if [[ "$n_sudo_true" -ne 0 && "$n_sudo_true" -ne 2 ]] || [[ "$n_sudo_true" -eq 0 && "$n_sudo_false" -eq 0 ]]; then
    log_error "Rprofile.site has ${n_sudo_true} 'bspm.sudo = TRUE' and ${n_sudo_false} 'bspm.sudo = FALSE' lines; expected 2 or 0/2 — not the v12 dispatcher, refused"; fail=1
  fi
fi
[[ $fail -eq 0 ]] || { log_error "pre-checks failed: nothing changed"; exit 1; }

# ── plan ────────────────────────────────────────────────────────────────────
log_head "Plan"
want_policy="$(render_policy)"
want_service="$(render_service)"
changes=0
plan_file() {
  local path="$1" want="$2"
  if [[ -f "$path" && "$(cat "$path")" == "$want" ]]; then
    log_ok "up to date: ${path#"$R"}"
  elif [[ -f "$path" ]]; then
    log_info "REPLACE ${path#"$R"}"; changes=$((changes + 1))
  else
    log_info "CREATE  ${path#"$R"}"; changes=$((changes + 1))
  fi
}
plan_file "$POLICY" "$want_policy"
plan_file "$SERVICE" "$want_service"
if [[ $SKIP_PROFILE -eq 1 ]]; then
  log_info "skip    /etc/R/Rprofile.site (--skip-profile)"
elif [[ "$n_sudo_true" -eq 2 ]]; then
  log_info "EDIT    /etc/R/Rprofile.site: bspm.sudo = TRUE -> FALSE (2 lines)"; changes=$((changes + 1))
else
  log_ok "up to date: /etc/R/Rprofile.site already has bspm.sudo = FALSE"
fi

if [[ "$changes" -eq 0 ]]; then
  if service_answers; then log_ok "already applied and the service answers"; exit 0; fi
  log_warn "files are in place but the service does not answer (try: sudo systemctl reload dbus)"
  exit 1
fi

if [[ "$MODE" == "dry-run" ]]; then
  printf '\n--- %s ---\n%s\n--- %s ---\n%s\n' "${POLICY#"$R"}" "$want_policy" "${SERVICE#"$R"}" "$want_service"
  log_info "dry-run: nothing changed. Apply with --commit."
  exit 0
fi

# ── commit ──────────────────────────────────────────────────────────────────
log_head "Commit"
is_root || { log_error "--commit needs root"; exit 1; }
BK="${BACKUP_ROOT}/bspm-dbus-hotfix-$(date -u +%Y%m%dT%H%M%SZ)"
if ! { mkdir -p "${BK}/files" && chmod 700 "$BK"; }; then log_error "cannot create backup dir ${BK}"; exit 1; fi
: > "${BK}/manifest"
backup() {
  local path="$1" rel="${1#"$R"}"
  if [[ -f "$path" ]]; then
    mkdir -p "${BK}/files$(dirname "$rel")" && cp -p "$path" "${BK}/files${rel}" || return 1
    printf 'replaced\t%s\n' "$rel" >> "${BK}/manifest"
  else
    printf 'created\t%s\n' "$rel" >> "${BK}/manifest"
  fi
}
if ! { backup "$POLICY" && backup "$SERVICE" && { [[ $SKIP_PROFILE -eq 1 ]] || backup "$PROFILE"; }; }; then
  log_error "backup failed: nothing changed (${BK})"; exit 1
fi
log_ok "backup: ${BK}"

applied=0
if atomic_write "$POLICY" "$want_policy" && atomic_write "$SERVICE" "$want_service"; then
  if [[ "$n_sudo_true" -eq 2 ]]; then
    tmp="$(mktemp "$(dirname "$PROFILE")/.Rprofile.site.XXXXXX")"
    if sed 's/bspm\.sudo = TRUE/bspm.sudo = FALSE/' "$PROFILE" > "$tmp" \
       && chmod --reference="$PROFILE" "$tmp" && chown --reference="$PROFILE" "$tmp" \
       && mv -f "$tmp" "$PROFILE"; then applied=1; else rm -f "$tmp"; fi
  else
    applied=1
  fi
fi

fail_stage=""
if [[ $applied -ne 1 ]]; then
  fail_stage="writing the files failed"
elif ! reload_dbus; then
  fail_stage="systemctl reload dbus failed"
elif ! service_answers; then
  fail_stage="the D-Bus service did not answer Introspect: ${DBUS_ERR:-no error text}"
fi
if [[ -n "$fail_stage" ]]; then
  log_error "${fail_stage} — rolling back"
  log_info "diagnose: journalctl -b --since '-5 min' | grep -iE 'dbus|r_project|bspm'"
  do_rollback "$BK" || log_error "automatic rollback incomplete: run --rollback ${BK}"
  exit 1
fi

log_ok "bspm D-Bus service registered and answering; Rprofile.site no longer uses sudo for bspm"
# A service process started from another bspm copy keeps the bus name until it
# exits (bspm.py quits 10 s after its last install/available call).
if command -v pgrep >/dev/null 2>&1; then
  stale="$(pgrep -af 'bspm/service/bspm\.py' | grep -vF '/usr/lib/R/site-library/bspm/service/bspm.py' || true)"
  if [[ -n "$stale" ]]; then
    log_warn "a bspm service from another path is still running and answers until it exits:"
    printf '         %s\n' "$stale" >&2
    log_warn "stop it when no install is running: sudo kill <PID> (the next call starts the new one)"
  fi
fi
log_info "New R sessions pick this up; running sessions keep the old setting."
log_info "Rollback: sudo bash $0 --rollback ${BK}"
log_warn "Sudoers is unchanged. Remove the bspm sudo lines only after a researcher install works (ADR-0005)."
