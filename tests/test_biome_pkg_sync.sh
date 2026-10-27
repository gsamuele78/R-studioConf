#!/usr/bin/env bash
set -euo pipefail
# tests/test_biome_pkg_sync.sh — scripts/biome_pkg_sync.sh (ADR-0004 step 4)
#
# apt-get, apt-cache, dpkg-query, pgrep, id and systemctl are stubbed on PATH;
# the shared directory, dpkg state and fix script are fakes under mktemp.
# Never touches apt, dpkg, systemd or /var.
#
# Exit: 0 all pass | 1 at least one failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SUT="${SCRIPT_DIR}/../scripts/biome_pkg_sync.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; NC=""; }

command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { printf "%sPASS%s %s\n" "$GREEN" "$NC" "$1"; }
fail() { printf "%sFAIL%s %s\n" "$RED" "$NC" "$1"; fails=$((fails + 1)); }

# ── stubs ──
mkdir -p "$T/bin"
cat > "$T/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
what="${*: -1}"
if [[ "$what" == 'r-cran-*' ]]; then awk -F'\t' '{print "ii \t" $1 "\t" $2}' "$STUB_STATE"; exit 0; fi
if [[ "$what" == r-base-core ]]; then printf '%s' "${STUB_R:-4.6.0-1.2404.0}"; exit 0; fi
exit 1
EOF
cat > "$T/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STUB_LOG"
args=(); for a in "$@"; do [[ "$a" == -* || "$a" == DPkg::* ]] || args+=("$a"); done
case "$1" in
  update) exit 0 ;;
  -s)
    case "${args[0]}" in
      install) for p in "${args[@]:1}"; do echo "Inst $p ($(awk -F'\t' -v p="$p" '$1==p{print $2}' "$STUB_REPO") r2u [all])"; done
               [[ -n "${STUB_SIM_EXTRA:-}" ]] && echo "$STUB_SIM_EXTRA"; exit 0 ;;
      remove)  for p in "${args[@]:1}"; do echo "Remv $p [x]"; done
               [[ -n "${STUB_SIM_EXTRA:-}" ]] && echo "$STUB_SIM_EXTRA"; exit 0 ;;
    esac ;;
  install)
    [[ "${STUB_INSTALL_FAIL:-0}" == 1 ]] && exit 100
    for p in "${args[@]:1}"; do printf '%s\t%s\n' "$p" "$(awk -F'\t' -v p="$p" '$1==p{print $2}' "$STUB_REPO")" >> "$STUB_STATE"; done
    sort -o "$STUB_STATE" "$STUB_STATE"; exit 0 ;;
  remove)
    for p in "${args[@]:1}"; do awk -F'\t' -v p="$p" '$1!=p' "$STUB_STATE" > "$STUB_STATE.n" && mv "$STUB_STATE.n" "$STUB_STATE"; done; exit 0 ;;
esac
echo "unexpected apt-get call: $*" >&2; exit 99
EOF
cat > "$T/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == pkgnames ]] && { cut -f1 "$STUB_REPO"; exit 0; }
exit 1
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *rsession* ]] && { echo "${STUB_SESSIONS:-0}"; [[ "${STUB_SESSIONS:-0}" -gt 0 ]]; exit; }
echo 0; exit 1
EOF
cat > "$T/bin/id" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_UID:-0}"
EOF
cat > "$T/bin/runuser" <<'EOF'
#!/usr/bin/env bash
# runuser -u USER -- cmd...: USER can write only when listed in STUB_WRITERS
[[ " ${STUB_WRITERS:-} " == *" $2 "* ]] || exit 1
shift 3; "$@"
EOF
cat > "$T/bin/nfs4_getfacl" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${STUB_ACL:-}" ]]; then printf '%s\n' "$STUB_ACL"
else printf '%s\n' "# file: $1" 'A::OWNER@:rwaDxtTnNcCy' 'A:g:GROUP@:rxtncy' 'A::EVERYONE@:rxtncy'; fi
EOF
cat > "$T/bin/nfs4_setfacl" <<'EOF'
#!/usr/bin/env bash
echo "nfs4_setfacl $*" >> "$STUB_LOG"
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
EOF
cat > "$T/fix.sh" <<'EOF'
#!/usr/bin/env bash
echo "fix $*" >> "$STUB_LOG"
[[ "${STUB_ALIGN_RC:-0}" == 0 ]] && echo "[ OK ] 1 package(s) upgraded. Backup: ${FIX_PKG_BACKUP_ROOT}/r-pkg-align-20261021T013000Z"
[[ "${STUB_ALIGN_RC:-0}" == 3 ]] && echo "[FAIL] 2 upgrade(s) cannot be rolled back — refused"
exit "${STUB_ALIGN_RC:-0}"
EOF
chmod +x "$T/bin/"* "$T/fix.sh"

manifest() {  # HOST AGE_SECONDS PKG...
  local h="$1" age="$2"; shift 2
  local at; at="$(date -u -d "@$(( $(date -u +%s) - age ))" +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "$@" | jq -R -s --arg h "$h" --arg at "$at" \
    '{schema: 1, host: $h, generated_at: $at, r_version: "4.6.0", mode: "apply",
      apt: (split("\n") | map(select(length > 0) | {package: ., version: "1.0-1"})), other: []}' \
    > "$T/sync/hosts/$h.json"
}

setup() {
  rm -rf "${T:?}/sync" "${T:?}/state" "${T:?}/backup" "${T:?}/lib" "${T:?}/systemd"
  mkdir -p "$T/sync/hosts" "$T/lib/mypkg" "$T/systemd"
  printf 'Package: mypkg\nVersion: 0.1\n' > "$T/lib/mypkg/DESCRIPTION"
  printf 'r-cran-future\t1.70.0-1\nr-cran-rlang\t1.2.0-1\n' > "$T/state.tsv"
  printf 'r-cran-future\t1.76.0-1\nr-cran-rlang\t1.3.0-1\nr-cran-mlr3\t1.8.0-1\nr-cran-ranger\t0.18.0-1\nr-cran-secret\t1.0-1\n' > "$T/repo.tsv"
  : > "$T/log"
  manifest biome-calc01 600 r-cran-future r-cran-rlang r-cran-mlr3 r-cran-ranger r-cran-secret r-cran-gone 'r-cran-BAD;rm'
}

run() {
  set +e
  OUT="$(env PATH="$T/bin:$PATH" STUB_STATE="$T/state.tsv" STUB_REPO="$T/repo.tsv" STUB_LOG="$T/log" \
    PKG_SYNC_DIR="${SYNC_DIR-$T/sync}" PKG_SYNC_HOST=biome-calc04 PKG_SYNC_STATE_DIR="$T/state" \
    PKG_SYNC_BACKUP_ROOT="$T/backup" PKG_SYNC_FIX_SCRIPT="$T/fix.sh" PKG_SYNC_LOCK="$T/lock" \
    PKG_SYNC_OTHER_LIBS="$T/lib" PKG_SYNC_SYSTEMD_DIR="$T/systemd" PKG_SYNC_NOW="${NOW:-0400}" \
    PKG_SYNC_TODAY=2026-10-21 PKG_SYNC_MODE="${MODE:-apply}" PKG_SYNC_MAX_NEW="${MAX_NEW:-50}" \
    bash "${RUN_SUT:-$SUT}" "$@" 2>&1)"
  RC=$?
  set -e
}
installs() { grep -c '^apt-get install' "$T/log" || true; }
has() { awk -F'\t' -v p="$1" '$1==p{f=1} END{exit !f}' "$T/state.tsv"; }
rep() { jq -r "$1" "$T/state/last_report.json"; }

# S1 not configured
setup; SYNC_DIR="" run
if [[ $RC -eq 1 ]] && grep -q 'PKG_SYNC_DIR is not set' <<<"$OUT"; then pass "S1 no shared dir → refused"; else fail "S1 (rc=$RC): $OUT"; fi

# S2/S3 outside the window: manifest only, nothing installed
setup; NOW=1200 run
m="$T/sync/hosts/biome-calc04.json"
if [[ $RC -eq 0 ]] && grep -q 'outside the window' <<<"$OUT" && [[ "$(installs)" -eq 0 ]] \
   && jq -e '.schema==1 and .host=="biome-calc04" and .r_version=="4.6.0" and (.apt|length)==2
             and .apt[0].package=="r-cran-future" and .other[0].package=="mypkg"' "$m" >/dev/null; then
  pass "S2 manifest published (apt + not-apt packages, R version); S3 outside window → no change"
else fail "S2/S3 (rc=$RC): $OUT $(cat "$m" 2>/dev/null)"; fi

# S4 first slot publishes only
setup; NOW=0315 run
if [[ $RC -eq 0 ]] && grep -q 'manifest only, so every host publishes first' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then
  pass "S4 before APPLY_FROM → publish only"; else fail "S4 (rc=$RC): $OUT"; fi

# S5 dry-run: plan only, marks the night done
setup; printf '{"exclude":["r-cran-secret"]}\n' > "$T/sync/policy.json"; MODE=dry-run run
if [[ $RC -eq 0 ]] && grep -q '2 package(s) missing on biome-calc04' <<<"$OUT" && grep -q 'r-cran-mlr3' <<<"$OUT" \
   && [[ "$(installs)" -eq 0 ]] && ! grep -q '^fix' "$T/log" && [[ "$(rep .status)" == dry-run ]] \
   && [[ "$(cat "$T/state/done_date")" == 2026-10-21 ]]; then
  pass "S5 dry-run: plan (excluded + unavailable left out), nothing changed, night marked done"
else fail "S5 (rc=$RC): $OUT"; fi
MODE=dry-run run
if [[ $RC -eq 0 ]] && grep -q 'already synced tonight' <<<"$OUT"; then pass "S6 second slot the same night → nothing to do"; else fail "S6 (rc=$RC): $OUT"; fi

# S7 sessions active → deferred, nothing changed
setup; STUB_SESSIONS=2; export STUB_SESSIONS; run; unset STUB_SESSIONS
if [[ $RC -eq 75 ]] && [[ "$(installs)" -eq 0 ]] && ! grep -q '^fix' "$T/log" && [[ "$(rep .status)" == deferred ]] \
   && [[ ! -f "$T/state/done_date" ]] && [[ -f "$T/sync/reports/biome-calc04.json" ]] \
   && grep -q 'retry at 04:15' <<<"$OUT"; then
  pass "S7 active sessions → deferred (75), no change, retried next slot"
else fail "S7 (rc=$RC): $OUT"; fi
setup; STUB_SESSIONS=2; export STUB_SESSIONS; NOW=0445 run; unset STUB_SESSIONS
if [[ $RC -eq 75 ]] && [[ "$(installs)" -eq 0 ]] && grep -q 'last slot tonight, the sync moves to the next night' <<<"$OUT"; then
  pass "S7b busy at the last slot (04:45) → moves to the next night"
else fail "S7b (rc=$RC): $OUT"; fi

# S8 apply: align, then install missing (capped), report
setup; printf '{"exclude":["r-cran-secret"]}\n' > "$T/sync/policy.json"; MAX_NEW=1 run
BK="$(find "$T/backup" -maxdepth 1 -name 'r-pkg-sync-*' | head -1)"
if [[ $RC -eq 0 ]] && has r-cran-mlr3 && ! has r-cran-ranger && ! has r-cran-secret \
   && grep -q '^fix --commit --no-update$' "$T/log" \
   && [[ "$(grep -n '^fix' "$T/log" | cut -d: -f1)" -lt "$(grep -n '^apt-get install' "$T/log" | cut -d: -f1)" ]] \
   && [[ "$(cat "$BK/new.tsv")" == r-cran-mlr3 ]] && [[ "$(cat "$BK/align_backup")" == "$T/backup/r-pkg-align-20261021T013000Z" ]] \
   && [[ "$(rep .status)" == "done" ]] && [[ "$(rep '.not_in_apt[0].package')" == r-cran-gone ]] \
   && grep -q 'invalid package names' <<<"$OUT" && grep -q -- '--no-remove' "$T/log" \
   && jq -e '[.apt[].package] | index("r-cran-mlr3")' "$T/sync/hosts/biome-calc04.json" >/dev/null; then
  pass "S8 apply: versions aligned first, 1 missing installed (cap), excluded/unavailable/invalid skipped, manifest republished"
else fail "S8 (rc=$RC): $OUT"; fi

# S9 rollback removes exactly what the run installed
run --rollback "$BK"
if [[ $RC -eq 0 ]] && ! has r-cran-mlr3 && has r-cran-future && grep -q -- '--rollback' <<<"$OUT"; then
  pass "S9 rollback removes the run's packages, points to the alignment rollback"
else fail "S9 (rc=$RC): $OUT"; fi
printf 'r-cran-mlr3\n' > "$BK/new.tsv"; printf 'r-cran-mlr3\t1.8.0-1\n' >> "$T/state.tsv"
STUB_SIM_EXTRA="Remv r-cran-mlr3spatiotempcv [2.3.5]"; export STUB_SIM_EXTRA; run --rollback "$BK"; unset STUB_SIM_EXTRA
if [[ $RC -eq 3 ]] && has r-cran-mlr3 && grep -q 'did not install' <<<"$OUT"; then
  pass "S10 rollback that would remove other packages → refused"; else fail "S10 (rc=$RC): $OUT"; fi

# S11 stale manifest ignored
setup; rm -f "$T/sync/hosts/biome-calc01.json"; manifest biome-calc02 $((40 * 3600)) r-cran-mlr3; run
if [[ $RC -eq 0 ]] && grep -q 'skipping biome-calc02.json: stale' <<<"$OUT" && ! has r-cran-mlr3; then
  pass "S11 manifest older than 36h ignored"; else fail "S11 (rc=$RC): $OUT"; fi

# S12 R not at the pin → refused
setup; STUB_R=4.5.3-1.2404.0; export STUB_R; run; unset STUB_R
if [[ $RC -eq 3 ]] && grep -q 'R 4.5.3 is not the pinned 4.6.0' "$T/state/last_report.json" && [[ "$(installs)" -eq 0 ]]; then
  pass "S12 R not at the pinned version → refused, nothing changed"; else fail "S12 (rc=$RC): $OUT"; fi

# S13 install plan that removes or upgrades packages → refused
setup; STUB_SIM_EXTRA="Remv r-cran-rlang [1.2.0-1]"; export STUB_SIM_EXTRA; run; unset STUB_SIM_EXTRA
if [[ $RC -eq 3 ]] && [[ "$(installs)" -eq 0 ]] && [[ "$(rep .note)" == *"removes packages"* ]]; then
  pass "S13a removal in the install plan → refused"; else fail "S13a (rc=$RC): $OUT"; fi
setup; STUB_SIM_EXTRA="Inst r-cran-rlang [1.2.0-1] (1.3.0-1 r2u [all])"; export STUB_SIM_EXTRA; run; unset STUB_SIM_EXTRA
if [[ $RC -eq 3 ]] && [[ "$(installs)" -eq 0 ]] && [[ "$(rep .note)" == *"without a saved .deb"* ]]; then
  pass "S13b unsaved upgrade in the install plan → refused"; else fail "S13b (rc=$RC): $OUT"; fi
setup; STUB_SIM_EXTRA="Inst r-base-core [4.6.0-1] (4.6.1-1 CRAN [amd64])"; export STUB_SIM_EXTRA; run; unset STUB_SIM_EXTRA
if [[ $RC -eq 3 ]] && [[ "$(installs)" -eq 0 ]] && [[ "$(rep .note)" == *"HARD RULE 19"* ]]; then
  pass "S13c r-base in the install plan → refused"; else fail "S13c (rc=$RC): $OUT"; fi

# S14 alignment refused (3) → still installs; alignment failed (1) → stops
setup; STUB_ALIGN_RC=3; export STUB_ALIGN_RC; run; unset STUB_ALIGN_RC
if [[ $RC -eq 0 ]] && has r-cran-mlr3 && [[ "$(rep .version_alignment)" == refused* ]]; then
  pass "S14a alignment refused (host unchanged) → missing packages still installed"; else fail "S14a (rc=$RC): $OUT"; fi
setup; STUB_ALIGN_RC=1; export STUB_ALIGN_RC; run; unset STUB_ALIGN_RC
if [[ $RC -eq 1 ]] && [[ "$(installs)" -eq 0 ]] && [[ "$(rep .status)" == failed ]]; then
  pass "S14b alignment failed → stop before installing"; else fail "S14b (rc=$RC): $OUT"; fi

# S15 apt install failure → exit 1 with rollback hint
setup; STUB_INSTALL_FAIL=1; export STUB_INSTALL_FAIL; run; unset STUB_INSTALL_FAIL
if [[ $RC -eq 1 ]] && [[ "$(rep .note)" == *"--rollback"* ]] && [[ ! -f "$T/state/done_date" ]]; then
  pass "S15 apt failure → failed, rollback hint, night not marked done"; else fail "S15 (rc=$RC): $OUT"; fi

# S16 status: differ → 4; same → 0
setup; NOW=1200 run; run --status
if [[ $RC -eq 4 ]] && grep -q 'biome-calc04' <<<"$OUT" && grep -q 'missing (sum over hosts): 5' <<<"$OUT"; then
  pass "S16a status: hosts differ → exit 4"; else fail "S16a (rc=$RC): $OUT"; fi
setup; rm -f "$T/sync/hosts/biome-calc01.json"; NOW=1200 run; cp "$T/sync/hosts/biome-calc04.json" "$T/x.json"
jq '.host="biome-calc03"' "$T/x.json" > "$T/sync/hosts/biome-calc03.json"; run --status
if [[ $RC -eq 0 ]] && grep -q 'same R packages' <<<"$OUT"; then pass "S16b status: same packages → exit 0"; else fail "S16b (rc=$RC): $OUT"; fi

# S17 timer install / remove
setup; run --install-timer
if [[ $RC -eq 0 ]] && grep -q 'OnCalendar=\*-\*-\* 03..04:00/15:00' "$T/systemd/biome-pkg-sync.timer" \
   && grep -q "ExecStart=/usr/bin/env bash .*/scripts/biome_pkg_sync.sh" "$T/systemd/biome-pkg-sync.service" \
   && grep -q "RequiresMountsFor=$T/sync" "$T/systemd/biome-pkg-sync.service" \
   && grep -q 'systemctl enable --now biome-pkg-sync.timer' "$T/log"; then
  pass "S17a timer rendered every 15 min 03:00-04:45 and enabled"; else fail "S17a (rc=$RC): $OUT"; fi
run --remove-timer
if [[ $RC -eq 0 ]] && [[ ! -f "$T/systemd/biome-pkg-sync.timer" ]]; then pass "S17b timer removed"; else fail "S17b (rc=$RC): $OUT"; fi

# S19 shared directory check
setup; run --check-dir
if [[ $RC -eq 0 ]] && grep -q 'root on biome-calc04 can write' <<<"$OUT" && grep -q "user 'nobody' cannot write" <<<"$OUT" \
   && grep -q 'PKG_SYNC_TEST_USER is not set' <<<"$OUT" && grep -q 'no NFSv4 ACL entry gives write' <<<"$OUT" \
   && grep -q 'hosts that reached the directory:.*biome-calc04' <<<"$OUT" && [[ ! -e "$T/sync/hosts/.probe-biome-calc04" ]]; then
  pass "S19a check-dir: root writes, others cannot, host listed, probe removed"; else fail "S19a (rc=$RC): $OUT"; fi
setup; chmod 777 "$T/sync/hosts"; run --check-dir
if [[ $RC -eq 1 ]] && grep -q 'writable by group/others (mode 777)' <<<"$OUT"; then
  pass "S19b check-dir: world-writable hosts/ → fail"; else fail "S19b (rc=$RC): $OUT"; fi
setup; STUB_WRITERS=nobody; export STUB_WRITERS; run --check-dir; unset STUB_WRITERS
if [[ $RC -eq 1 ]] && grep -q "user 'nobody' can write" <<<"$OUT" && [[ ! -e "$T/sync/hosts/.probe-biome-calc04" ]]; then
  pass "S19c check-dir: non-root can write → fail"; else fail "S19c (rc=$RC): $OUT"; fi
# S19d an inherited ACL (TrueNAS home share) giving an AD group write → fail with the fix
setup; STUB_ACL=$'# file: x\nA:fdg:164159874:rwaDdxtTnNcy\nA::OWNER@:rwaDxtTnNcCoy\nA:g:GROUP@:rxtncy\nA::EVERYONE@:rxtncy'
export STUB_ACL; run --check-dir; unset STUB_ACL
if [[ $RC -eq 1 ]] && grep -q 'NFSv4 ACL entries give write' <<<"$OUT" && grep -q 'A:fdg:164159874' <<<"$OUT" \
   && grep -q 'nfs4_setfacl -s' <<<"$OUT"; then
  pass "S19d check-dir: ACL entry granting a group write → fail, fix printed"; else fail "S19d (rc=$RC): $OUT"; fi
# S19e a configured researcher account that can write → fail; one that cannot → pass, no warning
setup; STUB_WRITERS=alice; export STUB_WRITERS; PKG_SYNC_TEST_USER=alice; export PKG_SYNC_TEST_USER; run --check-dir
if [[ $RC -eq 1 ]] && grep -q "user 'alice' can write" <<<"$OUT" && grep -q "user 'nobody' cannot write" <<<"$OUT"; then
  pass "S19e check-dir: researcher account can write → fail (nobody alone would pass)"; else fail "S19e (rc=$RC): $OUT"; fi
STUB_WRITERS=""; run --check-dir; unset STUB_WRITERS PKG_SYNC_TEST_USER
if [[ $RC -eq 0 ]] && grep -q "user 'alice' cannot write" <<<"$OUT" && ! grep -q 'PKG_SYNC_TEST_USER is not set' <<<"$OUT"; then
  pass "S19f check-dir: researcher account cannot write → pass"; else fail "S19f (rc=$RC): $OUT"; fi

# S20 init-dir: creates the directory, sets ACL and mode, writes the site
# config, then runs the check
setup; WS="$T/ws"; rm -rf "$WS"; mkdir -p "$WS/scripts" "$WS/config"
cp "$SUT" "$WS/scripts/"; cp "$SCRIPT_DIR/../config/pkg_sync.vars.conf" "$SCRIPT_DIR/../config/pin_r_version.vars.conf" "$WS/config/"
mkdir -p "$T/share"; ND="$T/share/.biome-pkg-sync"
RUN_SUT="$WS/scripts/biome_pkg_sync.sh"
SYNC_DIR="" run --init-dir "$ND" --test-user alice
if [[ $RC -eq 0 ]] && [[ -d "$ND/hosts" && -d "$ND/reports" ]] && [[ "$(stat -c %a "$ND/hosts")" == 755 ]] \
   && [[ "$(grep -c "^nfs4_setfacl -s A::OWNER@" "$T/log")" -eq 3 ]] \
   && grep -qx "PKG_SYNC_DIR=\"$ND\"" "$WS/config/site/pkg_sync.site.vars.conf" \
   && grep -qx 'PKG_SYNC_TEST_USER="alice"' "$WS/config/site/pkg_sync.site.vars.conf" \
   && grep -q "user 'alice' cannot write" <<<"$OUT" && [[ -f "$ND/hosts/biome-calc04.json" ]]; then
  pass "S20a init-dir: dir + ACL + 755 + site config, check passes, manifest published"; else fail "S20a (rc=$RC): $OUT"; fi
chmod 2775 "$ND/hosts"; : > "$T/log"; SYNC_DIR="" run --init-dir "$ND/"
if [[ $RC -eq 0 ]] && [[ "$(stat -c %a "$ND/hosts")" == 755 ]] && [[ -f "$ND/hosts/biome-calc04.json" ]] \
   && ! grep -q 'exists with PKG_SYNC_DIR' <<<"$OUT"; then
  pass "S20b init-dir again: mode 2775 back to 755, content kept, site config left"; else fail "S20b (rc=$RC): $OUT"; fi
SYNC_DIR="" run --init-dir relative/path
if [[ $RC -eq 2 ]]; then pass "S20c init-dir with a relative path → 2"; else fail "S20c (rc=$RC): $OUT"; fi
unset RUN_SUT; rm -rf "$WS"

# S18 usage errors
setup; run --bogus
if [[ $RC -eq 2 ]]; then pass "S18a unknown argument → 2"; else fail "S18a rc=$RC"; fi
MODE=yolo run
if [[ $RC -eq 2 ]]; then pass "S18b invalid mode → 2"; else fail "S18b rc=$RC"; fi
STUB_UID=1000; export STUB_UID; run; unset STUB_UID
if [[ $RC -eq 1 ]] && grep -q 'needs root' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then pass "S18c apply as non-root → refused"; else fail "S18c (rc=$RC): $OUT"; fi

echo
[[ $fails -eq 0 ]] && { echo "${GREEN}ALL PASS${NC}"; exit 0; }
echo "${RED}${fails} FAILURE(S)${NC}"; exit 1
