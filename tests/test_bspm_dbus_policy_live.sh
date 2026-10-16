#!/usr/bin/env bash
set -euo pipefail
# tests/test_bspm_dbus_policy_live.sh
#
# Loads the D-Bus policy rendered by scripts/fix_bspm_dbus_inplace.sh into a
# REAL private dbus-daemon (system.conf default policy + the rendered file) and
# checks who may call what on a stub org.r_project.linux1 service.
# Regression guard for the 2026-10-16 test-host failure: dbus-daemon rejected
# the whole file (a member rule without an interface), so even root got
# AccessDenied. The static tests could not see that.
#
# Needs root (runuser to throwaway users), dbus-daemon, dbus-send and a python3
# with gi (python3-gi). Missing prerequisites FAIL; nothing is skipped.
# Touches only a mktemp dir, plus two users/one group it creates and removes.

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_RESET='\033[0m'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../scripts/fix_bspm_dbus_inplace.sh"

pass=0; failn=0
ok()  { printf '%b[PASS]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; pass=$((pass + 1)); }
bad() { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*"; failn=$((failn + 1)); }
die() { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "needs root (run with sudo)"
for b in dbus-daemon dbus-send runuser useradd groupadd; do
  command -v "$b" >/dev/null 2>&1 || die "missing $b (apt-get install dbus-daemon)"
done
PY=""
for p in python3 python3.12; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'from gi.repository import Gio' >/dev/null 2>&1; then PY="$p"; break; fi
done
[[ -n "$PY" ]] || die "no python3 with gi (apt-get install python3-gi)"

GRP="bspmt$$"; U_IN="bspmin$$"; U_OUT="bspmout$$"
W="$(mktemp -d)"; chmod 755 "$W"
D_PID=""; S_PID=""
cleanup() {
  if [[ -n "$S_PID" ]]; then kill "$S_PID" 2>/dev/null || true; fi
  if [[ -n "$D_PID" ]]; then kill "$D_PID" 2>/dev/null || true; fi
  userdel "$U_IN" 2>/dev/null || true
  userdel "$U_OUT" 2>/dev/null || true
  groupdel "$GRP" 2>/dev/null || true
  rm -rf "$W"
}
trap cleanup EXIT
groupadd "$GRP"
useradd -M -N -g nogroup -G "$GRP" "$U_IN"
useradd -M -N -g nogroup "$U_OUT"

# 1. policy exactly as the hotfix renders it (dry-run output, between markers)
mkdir -p "${W}/system.d"
FIX_BSPM_ROOT="${W}/host" FIX_BSPM_PYTHON=true bash -c '
  mkdir -p "$FIX_BSPM_ROOT/usr/lib/R/site-library/bspm/service" "$FIX_BSPM_ROOT/etc/R"
  : > "$FIX_BSPM_ROOT/usr/lib/R/site-library/bspm/service/bspm.py"
  printf "a bspm.sudo = TRUE\nb bspm.sudo = TRUE\n" > "$FIX_BSPM_ROOT/etc/R/Rprofile.site"'
FIX_BSPM_ROOT="${W}/host" FIX_BSPM_PYTHON=true bash "$SCRIPT" --group "$GRP" > "${W}/dry" 2>&1 \
  || { cat "${W}/dry"; die "hotfix dry-run failed"; }
awk '/^--- \/etc\/dbus-1\/system.d\//{f=1; next} /^--- /{f=0} f' "${W}/dry" > "${W}/system.d/org.r_project.linux1.conf"
grep -q '<busconfig>' "${W}/system.d/org.r_project.linux1.conf" || die "could not extract the policy from the dry-run"

# 2. private bus: the distro default policy + our file
"$PY" - "$W" <<'EOF'
import re, sys
w = sys.argv[1]
src = open('/usr/share/dbus-1/system.conf').read()
pol = re.search(r'<policy context="default">.*?</policy>', src, re.S).group(0)
open(w + '/bus.conf', 'w').write(f'''<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>system</type><auth>EXTERNAL</auth>
<listen>unix:path={w}/sock</listen>
{pol}
<includedir>{w}/system.d</includedir>
</busconfig>''')
EOF
dbus-daemon --config-file="${W}/bus.conf" --nofork >/dev/null 2>"${W}/daemon.err" & D_PID=$!
for _ in $(seq 50); do [[ -S "${W}/sock" ]] && break; sleep 0.1; done
[[ -S "${W}/sock" ]] || { cat "${W}/daemon.err"; die "dbus-daemon did not start"; }
chmod 666 "${W}/sock"
if grep -q 'Encountered error' "${W}/daemon.err"; then
  bad "dbus-daemon rejected the policy: $(grep 'Encountered error' "${W}/daemon.err")"
else
  ok "dbus-daemon parses the rendered policy"
fi
A="unix:path=${W}/sock"

# 3. stub service (root) owning the name, same methods/signatures as bspm.py
cat > "${W}/svc.py" <<'EOF'
import sys
from gi.repository import Gio, GLib
XML = '''<node><interface name="org.r_project.linux1.PackageManager">
<method name="discover"><arg type="i" direction="in"/></method>
<method name="available"><arg type="i" direction="in"/><arg type="as" direction="out"/></method>
<method name="install"><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="as" direction="out"/></method>
<method name="remove"><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="as" direction="out"/></method>
</interface></node>'''
c = Gio.DBusConnection.new_for_address_sync(sys.argv[1],
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
def call(conn, sender, path, iface, method, params, inv):
    inv.return_value(None if method == "discover" else GLib.Variant('(as)', ([method],)))
c.register_object('/org/r_project/linux1/PackageManager', Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, None, None)
c.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
            GLib.Variant('(su)', ('org.r_project.linux1', 0)), None, 0, -1, None)
print("owned", flush=True)
GLib.MainLoop().run()
EOF
"$PY" "${W}/svc.py" "$A" > "${W}/svc.log" 2>&1 & S_PID=$!
for _ in $(seq 50); do grep -q owned "${W}/svc.log" 2>/dev/null && break; sleep 0.1; done
grep -q owned "${W}/svc.log" || { cat "${W}/svc.log"; bad "root could not own org.r_project.linux1"; }

# client: method call; empty iface sends a message WITHOUT an interface field
cat > "${W}/cli.py" <<'EOF'
import sys
from gi.repository import Gio, GLib
addr, iface, member = sys.argv[1], sys.argv[2] or None, sys.argv[3]
c = Gio.DBusConnection.new_for_address_sync(addr,
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
m = Gio.DBusMessage.new_method_call('org.r_project.linux1', '/org/r_project/linux1/PackageManager', iface, member)
if member in ("install", "remove"):
    m.set_body(GLib.Variant('(ias)', (1, ['praise'])))
elif member in ("available", "discover"):
    m.set_body(GLib.Variant('(i)', (1,)))
r, _ = c.send_message_with_reply_sync(m, Gio.DBusSendMessageFlags.NONE, 5000, None)
if r.get_message_type() == Gio.DBusMessageType.ERROR:
    print("ERROR", r.get_error_name()); sys.exit(1)
print("OK")
EOF
chmod 644 "${W}/cli.py"
PM=org.r_project.linux1.PackageManager
expect() { # expect allow|deny USER IFACE MEMBER
  local want="$1" u="$2" iface="$3" mem="$4" out rc=0
  if [[ "$u" == root ]]; then out="$("$PY" "${W}/cli.py" "$A" "$iface" "$mem" 2>&1)" || rc=$?
  else out="$(runuser -u "$u" -- "$PY" "${W}/cli.py" "$A" "$iface" "$mem" 2>&1)" || rc=$?; fi
  local got=allow; [[ $rc -eq 0 ]] || got=deny
  if [[ "$got" == "$want" ]] && { [[ "$want" == allow ]] || grep -q AccessDenied <<<"$out"; }; then
    ok "${u%%[0-9]*} ${iface:-<no interface>}.${mem} -> ${want}"
  else bad "${u%%[0-9]*} ${iface:-<no interface>}.${mem}: want ${want}, got ${got} (${out})"; fi
}
expect allow root   org.freedesktop.DBus.Introspectable Introspect
expect allow root   "$PM" remove
expect allow "$U_IN" "$PM" install
expect allow "$U_IN" "$PM" available
expect allow "$U_IN" "$PM" discover
expect allow "$U_IN" org.freedesktop.DBus.Introspectable Introspect
expect deny  "$U_IN" "$PM" remove
expect deny  "$U_IN" ""    remove
expect deny  "$U_IN" org.freedesktop.DBus.Properties GetAll
expect deny  "$U_OUT" "$PM" install
expect deny  "$U_OUT" "$PM" available

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[[ $failn -eq 0 ]]
