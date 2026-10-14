#!/usr/bin/env bash
set -uo pipefail
# tests/update_host_test.sh
# Regression gate for scripts/update_host.sh + lib/host_update.sh + lib/render_nginx.sh
# (ADR-0003 metrics M3, M4 and the validator guard, at level L1: CI, fake root).
#
# Everything runs under a mktemp root (HU_ROOT). nginx and systemctl are stubs
# that record their calls; nginx -t returns whatever the test sets. Never touches
# /etc, /var or a real service. Real install on a test host: docs/operations/IN_PLACE_UPDATE.md.
# Run: bash tests/update_host_test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUT="${REPO}/scripts/update_host.sh"

FAILS=0
ok() { printf '  PASS  %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$1"; then ok "$2"; else no "$2"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
ROOT="$T/root"
mkdir -p "$ROOT" "$T/bin"

# --- stubs ---------------------------------------------------------------------
printf '0\n' > "$T/nginx_rc"
cat > "$T/bin/nginx" <<EOF
#!/usr/bin/env bash
echo "nginx \$*" >> "$T/calls"
exit "\$(cat "$T/nginx_rc")"
EOF
cat > "$T/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$T/calls"
EOF
chmod +x "$T/bin/nginx" "$T/bin/systemctl"

cat > "$T/nginx.vars.conf" <<'EOF'
CERT_MODE="SELF_SIGNED"
DOMAIN_OR_IP="calc.test"
NGINX_DIR="/etc/nginx"
NGINX_TEMPLATE_DIR="/etc/nginx/templates"
LOG_DIR="/var/log/nginx"
DHPARAM_PATH="/etc/nginx/dhparam.pem"
RSTUDIO_PORT="8787"
WEB_TERMINAL_PORT="7681"
NEXTCLOUD_TARGET_URL="https://192.0.2.10"
SSL_CERT_DIR="/etc/nginx/ssl"
LE_CERT_DIR="/etc/letsencrypt/live"
EOF

# shellcheck disable=SC2034  # OUT/RC read inside eval'd check strings
run() { OUT="$(HU_ROOT="$ROOT" HU_NO_SYSLOG=1 HU_SKIP_ROOT_CHECK=1 LOG_FILE="$T/cu.log" \
               HU_NGINX_BIN="$T/bin/nginx" HU_SYSTEMCTL_BIN="$T/bin/systemctl" \
               bash "$SUT" --nginx-vars "$T/nginx.vars.conf" "$@" 2>&1)"; RC=$?; }
has() { grep -qF -- "$1" <<< "$OUT"; }
tree_sha() { (cd "$ROOT" && find etc -type f ! -path 'etc/biome-calc/*' -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum) | sha256sum | cut -d' ' -f1; }
last_journal() { find "$ROOT/var/backups/biome-calc" -mindepth 1 -maxdepth 1 -type d -name 'update-*' | sort | tail -n 1; }
NT="$ROOT/etc/nginx/templates"
SITE="$ROOT/etc/nginx/sites-available/calc.test.conf"

echo "== 1. Byte-identical with the historical installer output (existing hosts plan 0 diff)"
# What 30_install_nginx.sh / update_nginx_templates.sh wrote before this change:
# process_template + `echo "$processed_content" | tee`.
mkdir -p "$NT" "$(dirname "$SITE")"
(
    export LOG_FILE="$T/cu.log"
    # shellcheck source=../lib/common_utils.sh disable=SC1091
    source "${REPO}/lib/common_utils.sh" >/dev/null 2>&1
    # shellcheck disable=SC1091
    source "$T/nginx.vars.conf"
    # Verbatim timeout logic of the old installer/updater (bug-compatible on purpose).
    rstudio_vars_file="${REPO}/config/configure_rstudio.vars.conf"
    rsession_timeout_minutes=10080
    if [[ -f "$rstudio_vars_file" ]]; then
      extracted_timeout=$(grep -E '^[[:space:]]*RSESSION_TIMEOUT_MINUTES=' "$rstudio_vars_file" | cut -d= -f2- | tr -d '"'\''[:space:]')
      if [[ -n "$extracted_timeout" && "$extracted_timeout" =~ ^[0-9]+$ ]]; then
        rsession_timeout_minutes="$extracted_timeout"
      fi
    fi
    old_timeout_s=$(( rsession_timeout_minutes * 60 ))
    args=("DOMAIN_OR_IP=calc.test" "RSTUDIO_PORT=8787" "WEB_TERMINAL_PORT=7681"
          "NEXTCLOUD_TARGET_URL=https://192.0.2.10" "LOG_DIR=/var/log/nginx" "NGINX_TEMPLATE_DIR=/etc/nginx/templates"
          "CERT_FULLPATH=/etc/nginx/ssl/calc.test.crt" "KEY_FULLPATH=/etc/nginx/ssl/calc.test.key"
          "DHPARAM_FULLPATH=/etc/nginx/dhparam.pem" "TIMEOUT_STANDARD=600"
          "RSESSION_TIMEOUT_SECONDS=${old_timeout_s}")
    for n in nginx_ssl_params.conf nginx_ssl_certificate.conf nginx_performance.conf nginx_proxy_location.conf; do
        out=""; process_template "${REPO}/templates/${n}.template" out "${args[@]}"; echo "$out" > "$NT/$n"
    done
    out=""; process_template "${REPO}/templates/nginx_site.conf.template" out "${args[@]}"; echo "$out" > "$SITE"
)
chmod 0640 "$NT/nginx_proxy_location.conf"
run --plan
check '[[ $RC -eq 0 ]]' "plan on a host installed by the old code: exit 0 (got $RC)"
check 'has "files to change: 0"' "plan reports 0 files to change"
check '[[ ! -d $ROOT/var/backups/biome-calc ]]' "plan wrote no journal (read-only)"

echo "== 2. Drift is detected and shown, nothing is written"
printf '# hand edit on the host\n' >> "$NT/nginx_proxy_location.conf"
# shellcheck disable=SC2034  # read inside eval'd check strings
BEFORE="$(tree_sha)"
run --plan
check '[[ $RC -eq 10 ]]' "plan with drift: exit 10 (got $RC)"
check 'has "CHANGED  /etc/nginx/templates/nginx_proxy_location.conf"' "plan names the drifted file"
check 'has "+++ release:/etc/nginx/templates/nginx_proxy_location.conf"' "plan shows a diff"
check '[[ "$(tree_sha)" == "$BEFORE" ]]' "plan changed no deployed file"

echo "== 3. --apply refuses an untagged checkout unless --allow-untagged"
if git -C "$REPO" describe --tags --exact-match >/dev/null 2>&1 && [[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]]; then
    ok "checkout is at a clean tag — refusal path not exercised here"
else
    run --apply
    check '[[ $RC -eq 3 ]]' "apply on untagged checkout: exit 3 (got $RC)"
    check '[[ "$(tree_sha)" == "$BEFORE" ]]' "refused apply changed nothing"
fi

echo "== 4. Apply: backup, atomic swap, validator, reload (not restart), release.json"
: > "$T/calls"
run --apply --allow-untagged
check '[[ $RC -eq 0 ]]' "apply: exit 0 (got $RC)"
J="$(last_journal)"
check '[[ -n "$J" && -f "$J/manifest.tsv" ]]' "journal with manifest created"
check '[[ "$(wc -l < "$J/manifest.tsv")" -eq 1 ]]' "only the drifted file was replaced (manifest has 1 row)"
check '[[ -f "$J/files/etc/nginx/templates/nginx_proxy_location.conf" ]]' "previous file backed up in the journal"
check '[[ "$(stat -c %a "$NT/nginx_proxy_location.conf")" == "640" ]]' "mode of the replaced file preserved (0640)"
check 'grep -q "# hand edit" "$NT/nginx_proxy_location.conf"; [[ $? -ne 0 ]]' "drift removed"
check 'grep -qx "nginx -t" "$T/calls"' "nginx -t ran"
check 'grep -qx "systemctl reload nginx" "$T/calls"' "nginx reloaded"
check '! grep -q "restart" "$T/calls"' "no service restarted (rstudio-server untouched)"
check 'jq -e ".components.nginx.commit and .journal and (.hotfixes|type==\"array\")" "$ROOT/etc/biome-calc/release.json" >/dev/null' "release.json records component, commit, journal"
check '! find "$ROOT/etc" -name ".*.hu.*" | grep -q .' "no temp files left next to the config"

echo "== 5. Idempotence (M3): a second apply changes 0 files"
# shellcheck disable=SC2034  # read inside eval'd check strings
AFTER="$(tree_sha)"
# shellcheck disable=SC2034  # read inside eval'd check strings
NJ_BEFORE="$(find "$ROOT/var/backups/biome-calc" -mindepth 1 -maxdepth 1 -type d | wc -l)"
run --apply --allow-untagged
check '[[ $RC -eq 0 ]]' "second apply: exit 0 (got $RC)"
check 'has "nothing to apply"' "second apply reports nothing to apply"
check '[[ "$(tree_sha)" == "$AFTER" ]]' "second apply changed 0 files"
check '[[ "$(find "$ROOT/var/backups/biome-calc" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq "$NJ_BEFORE" ]]' "second apply created no journal"

echo "== 6. Rollback (M4): restores every original sha256 and the release record"
: > "$T/calls"
run --rollback "${J#"$ROOT"}"
check '[[ $RC -eq 0 ]]' "rollback: exit 0 (got $RC)"
check '[[ "$(tree_sha)" == "$BEFORE" ]]' "tree back to the exact pre-apply sha256"
check '[[ "$(stat -c %a "$NT/nginx_proxy_location.conf")" == "640" ]]' "mode restored"
check 'grep -qx "systemctl reload nginx" "$T/calls"' "nginx reloaded after rollback"
check '[[ ! -f "$ROOT/etc/biome-calc/release.json" ]]' "release.json removed (did not exist before the apply)"

echo "== 7. Guard: failing nginx -t leaves the previous files in place, no reload"
printf '1\n' > "$T/nginx_rc"
: > "$T/calls"
run --apply --allow-untagged
check '[[ $RC -eq 1 ]]' "apply with failing validator: exit 1 (got $RC)"
check '[[ "$(tree_sha)" == "$BEFORE" ]]' "previous files restored byte for byte"
check '! grep -q "systemctl" "$T/calls"' "nginx NOT reloaded"
check 'has "nginx was NOT reloaded"' "operator told the running config is the old one"
printf '0\n' > "$T/nginx_rc"

echo "== 8. Fresh host: new files are created 0644, rollback removes them"
rm -rf "${ROOT:?}/etc" "${ROOT:?}/var"
run --plan
check '[[ $RC -eq 10 ]] && has "NEW      /etc/nginx/sites-available/calc.test.conf"' "plan lists NEW files"
check 'has "is not enabled"' "plan warns that the site is not enabled"
run --apply --allow-untagged
check '[[ $RC -eq 0 && "$(stat -c %a "$SITE")" == "644" ]]' "new file created with 0644"
check '[[ "$(find "$ROOT/etc/nginx" -type f | wc -l)" -eq 5 ]]' "all 5 nginx files rendered (performance.conf included)"
run --rollback "$(last_journal | sed "s|^$ROOT||")"
check '[[ $RC -eq 0 && ! -e "$SITE" ]]' "rollback removed files the apply had created"

echo "== 9. Render refuses placeholders"
sed -i 's/^DOMAIN_OR_IP=.*/DOMAIN_OR_IP="your_domain_or_ip"/' "$T/nginx.vars.conf"
run --plan
check '[[ $RC -eq 1 ]] && has "placeholder"' "placeholder DOMAIN_OR_IP: exit 1, nothing rendered"
sed -i 's/^DOMAIN_OR_IP=.*/DOMAIN_OR_IP="calc.test"/' "$T/nginx.vars.conf"

echo "== 10. Concurrency: a held lock blocks a second apply"
mkdir -p "$ROOT/run/lock"
printf '# drift\n' >> "$SITE" 2>/dev/null || { mkdir -p "$(dirname "$SITE")"; printf '# drift\n' > "$SITE"; }
exec 8>"$ROOT/run/lock/biome-calc-update.lock"; flock -n 8
run --apply --allow-untagged
check '[[ $RC -eq 3 ]] && has "refusing to run concurrently"' "second writer refused while the lock is held (got $RC)"
exec 8>&-

echo
if (( FAILS )); then echo "update_host_test: ${FAILS} FAILED"; exit 1; fi
echo "update_host_test: all checks passed"
