#!/usr/bin/env bash
set -euo pipefail
# tests/test_fix_bspm_dbus.sh
#
# Regression tests for scripts/fix_bspm_dbus_inplace.sh (ADR-0005) and for the
# bspm section of templates/Rprofile_site.R.template.
# Deterministic: every path lives under a mktemp root (FIX_BSPM_ROOT); stat, id,
# getent, systemctl and dbus-send are PATH stubs. No D-Bus, apt or root needed.

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_RESET='\033[0m'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SCRIPT="${REPO}/scripts/fix_bspm_dbus_inplace.sh"
TEMPLATE="${REPO}/templates/Rprofile_site.R.template"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; failn=0
ok()  { printf '%b[PASS]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; pass=$((pass + 1)); }
bad() { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*"; failn=$((failn + 1)); }

# ── stubs ────────────────────────────────────────────────────────────────────
STUBS="${WORK}/stubs"; mkdir -p "$STUBS"
cat > "${STUBS}/id" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
cat > "${STUBS}/stat" <<'EOF'
#!/usr/bin/env bash
# stat -c '%U %a' PATH -> "root 755", or STUB_STAT_BAD for paths matching it
p="${*: -1}"
if [[ -n "${STUB_STAT_BAD:-}" && "$p" == *"${STUB_STAT_BAD}" ]]; then echo "${STUB_STAT_BAD_VAL:-ladmin 755}"; else echo "root 755"; fi
EOF
cat > "${STUBS}/getent" <<'EOF'
#!/usr/bin/env bash
[[ "${2:-}" == "${STUB_GROUP:-domain_users}" ]] && { echo "${2}:x:10000:"; exit 0; }
exit 2
EOF
cat > "${STUBS}/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${STUB_LOG}"
exit "${STUB_SYSTEMCTL_RC:-0}"
EOF
cat > "${STUBS}/dbus-send" <<'EOF'
#!/usr/bin/env bash
# "answers" only when the files are installed and STUB_DBUS_OK=1
echo "dbus-send $*" >> "${STUB_LOG}"
[[ "${STUB_DBUS_OK:-1}" == 1 ]] || exit 1
[[ -f "${FIX_BSPM_ROOT}/usr/share/dbus-1/system-services/org.r_project.linux1.service" ]] || exit 1
[[ -f "${FIX_BSPM_ROOT}/etc/dbus-1/system.d/org.r_project.linux1.conf" ]] || exit 1
exit 0
EOF
chmod +x "${STUBS}"/*

PROFILE_V12='  options(bspm.sudo = TRUE, bspm.version.check = FALSE)
  tryCatch({
    if (requireNamespace("bspm", quietly = TRUE)) {
      options(bspm.sudo = TRUE)
      suppressMessages(bspm::enable())
    }
  }, error = function(e) NULL)'

# fresh fake host: bspm installed, v12 dispatcher deployed
new_root() {
  local r="${WORK}/root$1"
  mkdir -p "${r}/usr/lib/R/site-library/bspm/service" "${r}/etc/R" "${r}/bk"
  printf '#!/usr/bin/env python3\n' > "${r}/usr/lib/R/site-library/bspm/service/bspm.py"
  printf '%s\n' "$PROFILE_V12" > "${r}/etc/R/Rprofile.site"
  cp "${r}/etc/R/Rprofile.site" "${r}/Rprofile.orig"
  : > "${r}/stub.log"
  printf '%s' "$r"
}

# run the script against root $1; remaining args are passed through
run() {
  local r="$1"; shift
  env PATH="${STUBS}:${PATH}" FIX_BSPM_ROOT="$r" FIX_BSPM_BACKUP_ROOT="${r}/bk" \
      FIX_BSPM_PYTHON="${FIX_BSPM_PYTHON:-true}" STUB_LOG="${r}/stub.log" \
      bash "$SCRIPT" "$@" > "${r}/out" 2>&1
}

POL=/etc/dbus-1/system.d/org.r_project.linux1.conf
SVC=/usr/share/dbus-1/system-services/org.r_project.linux1.service
nbk() { find "$1/bk" -mindepth 1 -maxdepth 1 -type d | wc -l; }

# T1 dry-run changes nothing
r="$(new_root 1)"; rc=0; run "$r" || rc=$?
if [[ $rc -eq 0 && ! -e "${r}${POL}" && ! -e "${r}${SVC}" ]] && cmp -s "${r}/etc/R/Rprofile.site" "${r}/Rprofile.orig" \
   && [[ "$(grep -c 'CREATE' "${r}/out")" -eq 2 ]] && grep -q 'EDIT' "${r}/out" && [[ "$(nbk "$r")" -eq 0 ]]; then
  ok "T1 dry-run plans 2 creates + 1 edit and changes nothing"
else bad "T1 dry-run (rc=$rc)"; cat "${r}/out"; fi

# T2 --commit refuses without root
r="$(new_root 2)"; rc=0; STUB_UID=1000 run "$r" --commit || rc=$?
if [[ $rc -eq 1 && ! -e "${r}${POL}" ]] && cmp -s "${r}/etc/R/Rprofile.site" "${r}/Rprofile.orig"; then
  ok "T2 --commit as non-root refused, nothing changed"
else bad "T2 non-root commit (rc=$rc)"; cat "${r}/out"; fi

# T3 --commit applies, backs up, reloads, verifies
r="$(new_root 3)"; rc=0; run "$r" --commit || rc=$?
bk="$(find "${r}/bk" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [[ $rc -eq 0 && -f "${r}${POL}" && -f "${r}${SVC}" ]] \
   && [[ "$(grep -c 'bspm\.sudo = FALSE' "${r}/etc/R/Rprofile.site")" -eq 2 ]] \
   && ! grep -q 'bspm\.sudo = TRUE' "${r}/etc/R/Rprofile.site" \
   && grep -q 'systemctl reload dbus' "${r}/stub.log" \
   && grep -q 'Introspect' "${r}/stub.log" \
   && [[ -n "$bk" ]] && [[ "$(grep -c '^created' "${bk}/manifest")" -eq 2 ]] \
   && grep -q "^replaced	/etc/R/Rprofile.site$" "${bk}/manifest" \
   && cmp -s "${bk}/files/etc/R/Rprofile.site" "${r}/Rprofile.orig" \
   && [[ "$(stat -c %a "${r}${POL}")" == 644 ]]; then
  ok "T3 --commit installs policy + service, flips both sudo lines, backs up, reloads, verifies"
else bad "T3 commit (rc=$rc)"; cat "${r}/out"; fi

# T4 policy content: well-formed; group may install/available/discover/Introspect only; remove denied last
pol="${r}${POL}"
if python3 - "$pol" <<'EOF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
pol = {(p.get("user"), p.get("group"), p.get("context")): p for p in root.findall("policy")}
grp = pol[(None, "domain_users", None)]
rules = [(r.tag, r.get("send_member")) for r in grp]
allowed = {m for t, m in rules if t == "allow"}
assert allowed == {"install", "available", "discover", "Introspect"}, allowed
assert all(r.get("send_member") for r in grp if r.tag == "allow"), "allow without member"
assert rules[-1] == ("deny", "remove"), rules
assert [r.tag for r in pol[(None, None, "default")]] == ["deny"]
assert {r.get("own") for r in pol[("root", None, None)]} >= {"org.r_project.linux1"}
EOF
then ok "T4 policy: allow install/available/discover/Introspect to the group, deny remove (last), default deny"
else bad "T4 policy content"; cat "$pol"; fi
if grep -q '^Exec=/usr/lib/R/site-library/bspm/service/bspm.py$' "${r}${SVC}" && grep -q '^User=root$' "${r}${SVC}"; then
  ok "T4b service file runs bspm.py as root with no arguments (service mode)"
else bad "T4b service file"; cat "${r}${SVC}"; fi

# T5 second --commit is a no-op
rc=0; run "$r" --commit || rc=$?
if [[ $rc -eq 0 ]] && grep -q 'already applied' "${r}/out" && [[ "$(nbk "$r")" -eq 1 ]]; then
  ok "T5 re-run is idempotent (no new backup)"
else bad "T5 idempotency (rc=$rc)"; cat "${r}/out"; fi

# T6 --rollback restores the exact pre-hotfix state
rc=0; run "$r" --rollback "$bk" || rc=$?
if [[ $rc -eq 0 && ! -e "${r}${POL}" && ! -e "${r}${SVC}" ]] && cmp -s "${r}/etc/R/Rprofile.site" "${r}/Rprofile.orig" \
   && [[ "$(grep -c 'systemctl reload dbus' "${r}/stub.log")" -ge 2 ]]; then
  ok "T6 --rollback removes both files and restores Rprofile.site byte-for-byte"
else bad "T6 rollback (rc=$rc)"; cat "${r}/out"; fi

# T7 service does not answer -> automatic rollback
r="$(new_root 7)"; rc=0; STUB_DBUS_OK=0 run "$r" --commit || rc=$?
if [[ $rc -eq 1 && ! -e "${r}${POL}" && ! -e "${r}${SVC}" ]] && cmp -s "${r}/etc/R/Rprofile.site" "${r}/Rprofile.orig" \
   && grep -q 'did not answer Introspect' "${r}/out"; then
  ok "T7 failed verification rolls everything back automatically"
else bad "T7 auto-rollback (rc=$rc)"; cat "${r}/out"; fi

# T8 dbus reload fails -> automatic rollback
r="$(new_root 8)"; rc=0; STUB_SYSTEMCTL_RC=1 run "$r" --commit || rc=$?
if [[ $rc -eq 1 && ! -e "${r}${POL}" ]] && cmp -s "${r}/etc/R/Rprofile.site" "${r}/Rprofile.orig"; then
  ok "T8 failed dbus reload rolls back"
else bad "T8 reload failure (rc=$rc)"; cat "${r}/out"; fi

# T9 unsafe ownership anywhere on the bspm.py path refuses
for case in "bspm.py|ladmin 755" "site-library|root 775" "bspm.py|root 757"; do
  bad_path="${case%%|*}"; val="${case#*|}"
  r="$(new_root "9${bad_path}${val// /}")"; rc=0
  STUB_STAT_BAD="$bad_path" STUB_STAT_BAD_VAL="$val" run "$r" --commit || rc=$?
  if [[ $rc -eq 1 && ! -e "${r}${POL}" ]] && grep -q 'unsafe ownership' "${r}/out"; then
    ok "T9 ${bad_path} '${val}' refused"
  else bad "T9 unsafe ${bad_path} '${val}' (rc=$rc)"; cat "${r}/out"; fi
done

# T10 missing python modules, unresolvable group, missing bspm: refused
r="$(new_root 10a)"; rc=0; FIX_BSPM_PYTHON=false run "$r" --commit || rc=$?
if [[ $rc -eq 1 && ! -e "${r}${POL}" ]] && grep -q 'cannot import dbus' "${r}/out"; then ok "T10a missing python3-dbus/gi/apt refused"
else bad "T10a python (rc=$rc)"; cat "${r}/out"; fi
r="$(new_root 10b)"; rc=0; run "$r" --commit --group researchers || rc=$?
if [[ $rc -eq 1 && ! -e "${r}${POL}" ]] && grep -q "group 'researchers' does not resolve" "${r}/out"; then ok "T10b unresolvable group refused"
else bad "T10b group (rc=$rc)"; cat "${r}/out"; fi
r="$(new_root 10c)"; rm -f "${r}/usr/lib/R/site-library/bspm/service/bspm.py"; rc=0; run "$r" --commit || rc=$?
if [[ $rc -eq 1 && ! -e "${r}${POL}" ]] && grep -q 'bspm service not found' "${r}/out"; then ok "T10c bspm not installed refused"
else bad "T10c bspm missing (rc=$rc)"; cat "${r}/out"; fi

# T11 unexpected profile (one TRUE line) refused
r="$(new_root 11)"; printf 'options(bspm.sudo = TRUE)\n' > "${r}/etc/R/Rprofile.site"; rc=0; run "$r" --commit || rc=$?
if [[ $rc -eq 1 && ! -e "${r}${POL}" ]] && grep -q 'not the v12 dispatcher' "${r}/out"; then ok "T11 unexpected Rprofile.site refused"
else bad "T11 profile shape (rc=$rc)"; cat "${r}/out"; fi

# T12 --group is honoured and XML-escaped
r="$(new_root 12)"; rc=0; STUB_GROUP='a&b' run "$r" --commit --group 'a&b' || rc=$?
if [[ $rc -eq 0 ]] && grep -q 'group="a&amp;b"' "${r}${POL}" && python3 -c 'import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])' "${r}${POL}"; then
  ok "T12 --group written XML-escaped and well-formed"
else bad "T12 group escape (rc=$rc)"; cat "${r}/out"; fi

# T13 --skip-profile registers the service on a host with no Rprofile.site yet
r="$(new_root 13)"; rm -f "${r}/etc/R/Rprofile.site"; rc=0; run "$r" --commit --skip-profile || rc=$?
if [[ $rc -eq 0 && -f "${r}${POL}" && -f "${r}${SVC}" && ! -e "${r}/etc/R/Rprofile.site" ]]; then ok "T13 --skip-profile installs the service only"
else bad "T13 skip-profile (rc=$rc)"; cat "${r}/out"; fi

# T14 usage errors
r="$(new_root 14)"; rc=0; run "$r" --bogus || rc=$?
rc2=0; run "$r" --rollback || rc2=$?
if [[ $rc -eq 2 && $rc2 -eq 2 ]]; then ok "T14 usage errors exit 2"; else bad "T14 usage (rc=$rc rc2=$rc2)"; fi

# T15 template: bspm never uses sudo; enabled only when the D-Bus service is registered
sect="$(awk '/SECTION 0: bspm/{f=1} /SECTION 1:/{f=0} f' "$TEMPLATE")"
if [[ -n "$sect" ]] && ! grep -q 'bspm\.sudo = TRUE' <<<"$sect" \
   && [[ "$(grep -c 'bspm\.sudo = FALSE' <<<"$sect")" -eq 2 ]] \
   && grep -q 'org.r_project.linux1.service' <<<"$sect" \
   && ! grep -q 'bspm\.sudo = TRUE' "$TEMPLATE"; then
  ok "T15 template: bspm.sudo = FALSE (2 lines, hotfix-compatible), gated on the D-Bus service file"
else bad "T15 template bspm section"; printf '%s\n' "$sect"; fi

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[[ $failn -eq 0 ]]
