#!/usr/bin/env bash
set -euo pipefail
# tests/test_fix_r_version.sh — scripts/fix_r_version_inplace.sh
# Stubs apt-get, apt-cache, apt-mark, dpkg-query, dpkg-deb, pgrep, id,
# systemctl, Rscript and R; no real package is touched. Run: bash tests/test_fix_r_version.sh

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_RESET='\033[0m'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="${ROOT}/scripts/fix_r_version_inplace.sh"
TARGET="$(grep -m1 '^DEFAULT_R_VERSION=' "${ROOT}/config/pin_r_version.vars.conf" | cut -d= -f2- | tr -d '"')"
T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
FAILS=0
pass() { printf '%bPASS%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { printf '%bFAIL%b %s\n' "$C_RED" "$C_RESET" "$*"; FAILS=$((FAILS + 1)); }

mkdir -p "$T/bin"
cat > "$T/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
fmt=""; pkgs=()
for a in "$@"; do case "$a" in -W) ;; -f=*) fmt="${a#-f=}" ;; *) pkgs+=("$a") ;; esac; done
for p in "${pkgs[@]}"; do
  if [[ "$p" == *'*' ]]; then
    awk -F'\t' -v pre="${p%\*}" -v f="$fmt" 'index($1, pre) == 1 {
      if (f ~ /Version/) print "ii \t" $1 "\t" $2; else print "ii \t" $1 }' "$STUB_STATE"; continue
  fi
  v="$(awk -F'\t' -v p="$p" '$1==p{print $2}' "$STUB_STATE")"
  [[ -n "$v" ]] || exit 1
  if [[ "$fmt" == *Package* ]]; then printf 'ii \t%s\t%s\n' "$p" "$v"; else printf 'ii \t%s\n' "$v"; fi
done
EOF
cat > "$T/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STUB_LOG"
sim=false; args=(); skip=false
for a in "$@"; do
  $skip && { skip=false; continue; }
  case "$a" in -s) sim=true ;; -o) skip=true ;; -*) ;; *) args+=("$a") ;; esac
done
pv() {  # ARG -> "pkg<TAB>ver" (a bare name takes the repository version)
  if [[ "$1" == *.deb ]]; then b="$(basename "$1" .deb)"; IFS=_ read -r p v _ <<<"$b"; printf '%s\t%s\n' "$p" "${v//%3a/:}"
  elif [[ "$1" == *=* ]]; then printf '%s\t%s\n' "${1%%=*}" "${1#*=}"
  else printf '%s\t%s\n' "$1" "$(awk -F'\t' -v p="$1" '$1==p{print $2}' "$STUB_REPO")"; fi
}
case "${args[0]:-}" in
  update) exit 0 ;;
  download) p="${args[1]%%=*}"; v="${args[1]#*=}"; : > "${p}_${v//:/%3a}_amd64.deb"; exit 0 ;;
  install)
    if $sim; then
      for x in "${args[@]:1}"; do IFS=$'\t' read -r p v <<<"$(pv "$x")"
        o="$(awk -F'\t' -v p="$p" '$1==p{print $2}' "$STUB_STATE")"
        [[ -z "$v" || "$v" == "$o" ]] && continue   # no newer build in the repository
        if [[ -n "$o" ]]; then echo "Inst $p [$o] ($v CRAN [amd64])"; else echo "Inst $p ($v CRAN [amd64])"; fi
      done
      [[ -n "${STUB_SIM_EXTRA:-}" ]] && echo "$STUB_SIM_EXTRA"; exit 0
    fi
    [[ "${STUB_INSTALL_FAIL:-0}" == 1 ]] && exit 100
    for x in "${args[@]:1}"; do IFS=$'\t' read -r p v <<<"$(pv "$x")"
      awk -F'\t' -v p="$p" '$1!=p' "$STUB_STATE" > "$STUB_STATE.n"; printf '%s\t%s\n' "$p" "$v" >> "$STUB_STATE.n"
      sort -o "$STUB_STATE" "$STUB_STATE.n"; rm -f "$STUB_STATE.n"
    done; exit 0 ;;
esac
exit 0
EOF
cat > "$T/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == madison ]] || exit 0
awk -F'\t' -v p="$2" '$1==p{print " " p " | " $2 " | https://cloud.r-project.org noble-cran40/ Packages"}' "$STUB_REPO"
EOF
cat > "$T/bin/apt-mark" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_HELD:-}" ]] && echo "$STUB_HELD"; exit 0
EOF
cat > "$T/bin/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
b="$(basename "$2" .deb)"; IFS=_ read -r _p v _a <<<"$b"; echo "${v//%3a/:}"
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
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"; exit 0
EOF
cat > "$T/bin/Rscript" <<'EOF'
#!/usr/bin/env bash
rv="$(awk -F'\t' '$1=="r-base-core"{print $2}' "$STUB_STATE")"
if [[ "$*" == *--vanilla\ -e* ]]; then [[ "${STUB_NOPKGS:-0}" == 1 ]] || printf '%s\n' stats mlr3 sf; exit 0; fi
shift 2
for p in "$@"; do
  if [[ "$p" == "${STUB_BROKEN:-none}" && "$rv" != 4.5* ]]; then printf '%s\tFAIL\n' "$p"; else printf '%s\tOK\n' "$p"; fi
done
EOF
cat > "$T/bin/R" <<'EOF'
#!/usr/bin/env bash
rv="$(awk -F'\t' '$1=="r-base-core"{print $2}' "$STUB_STATE")"; echo "R version ${rv%%-*} (stub)"
EOF
chmod +x "$T/bin/"*

setup() {
  rm -rf "${T:?}/state.tsv" "${T:?}/repo.tsv" "${T:?}/log" "${T:?}/backup" "${T:?}/cache" "${T:?}/debs" "${T:?}/home" "${T:?}/export"
  # user libraries: alice 4.5 only, bob 4.5 and 4.6, carol an empty 4.5 (ignored)
  local L=R/x86_64-pc-linux-gnu-library
  mkdir -p "$T/cache" "$T/debs" "$T/home/alice/$L/4.5/vegan" "$T/home/bob/$L/4.5/sf" "$T/home/bob/$L/4.6/sf" \
           "$T/home/carol/$L/4.5"
  printf '%s\t%s\n' r-base 4.5.3-1.2404.0 r-base-core 4.5.3-1.2404.0 r-base-dev 4.5.3-1.2404.0 \
    r-cran-mlr3 1.2.0-1 r-cran-sf 1.1-0-1 r-recommended 4.5.3-1.2404.0 | sort > "$T/state.tsv"
  # the repository no longer has the pinned version, only 4.6.1; it has a newer
  # build of mlr3 and the same sf
  printf '%s\t%s\n' r-base-core 4.6.1-9.2404.0 r-base 4.6.1-9.2404.0 r-base-dev 4.6.1-9.2404.0 r-recommended 4.6.1-9.2404.0 \
    r-cran-mlr3 1.3.0-1 r-cran-sf 1.1-0-1 > "$T/repo.tsv"
  : > "$T/cache/r-cran-mlr3_1.2.0-1_amd64.deb"
  for p in r-base r-base-core r-base-dev r-recommended; do
    : > "$T/cache/${p}_4.5.3-1.2404.0_amd64.deb"          # old .debs in the apt cache
    : > "$T/debs/${p}_${TARGET}-1.2404.0_amd64.deb"       # exported from calc01
  done
  : > "$T/log"
}
run() {
  set +e
  OUT="$(env PATH="$T/bin:$PATH" STUB_STATE="$T/state.tsv" STUB_REPO="$T/repo.tsv" STUB_LOG="$T/log" \
    FIX_R_BACKUP_ROOT="$T/backup" FIX_R_APT_ARCHIVES="$T/cache" FIX_R_USER_LIB_ROOT="$T/home" \
    bash "$SUT" "$@" 2>&1)"
  RC=$?
  set -e
}
ver() { awk -F'\t' -v p="$1" '$1==p{print $2}' "$T/state.tsv"; }
installs() { grep -c '^apt-get install -y' "$T/log" || true; }

# R1 repository without the target → refused
setup; run
if [[ $RC -eq 3 ]] && grep -q "R ${TARGET} (r-base) is not in the apt repositories (newest: 4.6.1-9.2404.0)" <<<"$OUT" \
   && grep -q -- '--export-debs' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then
  pass "R1 target not in the repository → refused, points to --export-debs"; else fail "R1 (rc=$RC): $OUT"; fi

# R2 dry-run with exported .debs: plan, user-library report, no change
setup; run --debs "$T/debs"
if [[ $RC -eq 0 ]] && grep -q "r-base-core *4.5.3-1.2404.0 -> ${TARGET}-1.2404.0" <<<"$OUT" \
   && grep -q '2 user(s) have packages for 4.5, 1 of them none for 4.6' <<<"$OUT" \
   && grep -q 'rollback possible for 5/5' <<<"$OUT" && grep -q 'dry-run: nothing changed' <<<"$OUT" \
   && grep -q '1 installed r-cran-\* package(s) are upgraded' <<<"$OUT" && grep -q 'r-cran-mlr3 *1.2.0-1 -> 1.3.0-1' <<<"$OUT" \
   && [[ "$(installs)" -eq 0 ]] && [[ "$(ver r-base-core)" == 4.5.3-1.2404.0 ]]; then
  pass "R2 dry-run --debs: plan with the r-cran rebuild, non-empty user libraries reported, nothing changed"; else fail "R2 (rc=$RC): $OUT"; fi

# R3 sessions → refused
setup; STUB_SESSIONS=2; export STUB_SESSIONS; run --debs "$T/debs" --commit; unset STUB_SESSIONS
if [[ $RC -eq 3 ]] && grep -q 'upgrade R when idle' <<<"$OUT" && [[ "$(installs)" -eq 0 ]] && [[ ! -d "$T/backup" ]]; then
  pass "R3 active sessions → refused, host unchanged"; else fail "R3 (rc=$RC): $OUT"; fi

# R4 held core package → refused
setup; STUB_HELD=r-base-core; export STUB_HELD; run --debs "$T/debs"; unset STUB_HELD
if [[ $RC -eq 3 ]] && grep -q 'held by apt-mark: r-base-core' <<<"$OUT"; then pass "R4 held package → refused"; else fail "R4 (rc=$RC): $OUT"; fi

# R5 commit: old .debs saved, R upgraded, rstudio restarted, load test clean
setup; run --debs "$T/debs" --commit
BK="$(find "$T/backup" -maxdepth 1 -name 'r-version-*' 2>/dev/null | head -1)"
if [[ $RC -eq 0 ]] && [[ "$(ver r-base-core)" == "${TARGET}-1.2404.0" ]] && [[ "$(ver r-recommended)" == "${TARGET}-1.2404.0" ]] \
   && [[ "$(ver r-cran-mlr3)" == 1.3.0-1 ]] && [[ "$(ver r-cran-sf)" == 1.1-0-1 ]] \
   && [[ "$(find "$BK/debs" -name '*.deb' | wc -l)" -eq 5 ]] && grep -q 'systemctl restart rstudio-server' "$T/log" \
   && grep -q 'load test batch 1/1 (mlr3' <<<"$OUT" \
   && grep -q "R is now R version ${TARGET}" <<<"$OUT" && grep -q 'no package stopped loading' <<<"$OUT" \
   && [[ "$(grep -c $'\tOK$' "$BK/load_before.tsv")" -eq 3 ]] && grep -q -- '--no-remove' "$T/log"; then
  pass "R5 commit: 5 old .debs saved, R ${TARGET} and mlr3 rebuilt in one transaction, progress shown, 3/3 packages load"
else fail "R5 (rc=$RC): $OUT"; fi

# R6 rollback reinstalls the saved .debs
run --rollback "$BK"
if [[ $RC -eq 0 ]] && [[ "$(ver r-base-core)" == 4.5.3-1.2404.0 ]] && grep -q 'apt-get.*--allow-downgrades' "$T/log" \
   && grep -q 'apt-mark hold' <<<"$OUT"; then
  pass "R6 rollback: back to 4.5.3, hint to hold against the pin"; else fail "R6 (rc=$RC): $OUT"; fi
if [[ "$(ver r-cran-mlr3)" == 1.2.0-1 ]]; then pass "R6b rollback also restores the old r-cran build"; else fail "R6b mlr3 is $(ver r-cran-mlr3)"; fi

# R7 a package that stops loading → exit 5 with the rollback command
setup; STUB_BROKEN=sf; export STUB_BROKEN; run --debs "$T/debs" --commit; unset STUB_BROKEN
BK="$(find "$T/backup" -maxdepth 1 -name 'r-version-*' | head -1)"
if [[ $RC -eq 5 ]] && grep -q 'loaded before and fail now: sf' <<<"$OUT" && [[ "$(cat "$BK/regressions.txt")" == sf ]] \
   && grep -q -- "--rollback $BK" <<<"$OUT"; then
  pass "R7 load regression → exit 5, regressions.txt, rollback command"; else fail "R7 (rc=$RC): $OUT"; fi

# R8 old .debs not saveable → refused before any change
setup; rm -f "$T/cache/"*.deb; run --debs "$T/debs" --commit
if [[ $RC -eq 3 ]] && grep -q 'cannot be rolled back' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then
  pass "R8 no old .deb for rollback → refused"; else fail "R8 (rc=$RC): $OUT"; fi

# R9 checksum mismatch in the exported directory → refused
setup; ( cd "$T/debs" && sha256sum ./*.deb > SHA256SUMS ); echo x >> "$T/debs/r-base_${TARGET}-1.2404.0_amd64.deb"
run --debs "$T/debs"
if [[ $RC -eq 3 ]] && grep -q 'checksum mismatch' <<<"$OUT"; then pass "R9 checksum mismatch → refused"; else fail "R9 (rc=$RC): $OUT"; fi

# R10 plan that removes a package → refused
setup; STUB_SIM_EXTRA="Remv r-cran-mlr3 [1.2.0-1]"; export STUB_SIM_EXTRA; run --debs "$T/debs" --commit; unset STUB_SIM_EXTRA
if [[ $RC -eq 3 ]] && grep -q 'the plan removes packages' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then
  pass "R10 removal in the plan → refused"; else fail "R10 (rc=$RC): $OUT"; fi

# R11 already at the target → nothing to do
setup; sed -i "s/4.5.3-1.2404.0/${TARGET}-1.2404.0/" "$T/state.tsv"; run --debs "$T/debs"
if [[ $RC -eq 0 ]] && grep -q "already at the pinned ${TARGET}" <<<"$OUT"; then pass "R11 at target → nothing to do"; else fail "R11 (rc=$RC): $OUT"; fi

# R12 export on the reference host (calc01): .debs + SHA256SUMS
for p in r-base r-base-core r-base-dev r-recommended; do : > "$T/cache/${p}_${TARGET}-1.2404.0_amd64.deb"; done
run --export-debs "$T/export"
if [[ $RC -eq 0 ]] && [[ "$(find "$T/export" -name '*.deb' | wc -l)" -eq 4 ]] && [[ -f "$T/export/SHA256SUMS" ]] \
   && ( cd "$T/export" && sha256sum -c --quiet SHA256SUMS ); then
  pass "R12 export: 4 .debs from the apt cache + SHA256SUMS"; else fail "R12 (rc=$RC): $OUT"; fi
rm -f "$T/cache/r-base-dev_${TARGET}"*; rm -rf "$T/export"; run --export-debs "$T/export"
if [[ $RC -eq 1 ]] && grep -q 'r-base-dev=.*no .deb' <<<"$OUT"; then pass "R12b export without a source → fail, names dpkg-repack"; else fail "R12b (rc=$RC): $OUT"; fi

# R13 downgrade needs --allow-downgrade
setup; sed -i 's/4.5.3-1.2404.0/4.6.1-9.2404.0/' "$T/state.tsv"; for p in r-base r-base-core r-base-dev r-recommended; do : > "$T/cache/${p}_4.6.1-9.2404.0_amd64.deb"; done
run --debs "$T/debs" --commit
if [[ $RC -eq 3 ]] && grep -q 'downgrade of R' <<<"$OUT"; then pass "R13 downgrade without --allow-downgrade → refused"; else fail "R13 (rc=$RC): $OUT"; fi

# R14 usage errors / not root
setup; run --bogus; [[ $RC -eq 2 ]] && pass "R14a unknown argument → 2" || fail "R14a (rc=$RC)"
STUB_UID=1000; export STUB_UID; run --debs "$T/debs" --commit; unset STUB_UID
if [[ $RC -eq 1 ]] && grep -q -- '--commit needs root' <<<"$OUT"; then pass "R14b commit as non-root → refused"; else fail "R14b (rc=$RC): $OUT"; fi

# R15 --core-only leaves the r-cran packages and warns
setup; run --debs "$T/debs" --commit --core-only
if [[ $RC -eq 0 ]] && [[ "$(ver r-base-core)" == "${TARGET}-1.2404.0" ]] && [[ "$(ver r-cran-mlr3)" == 1.2.0-1 ]] \
   && grep -q -- '--core-only: 1 installed r-cran-\* package(s) have a newer build and stay' <<<"$OUT"; then
  pass "R15 --core-only: R upgraded, r-cran-mlr3 left, warning"; else fail "R15 (rc=$RC): $OUT"; fi

# R16 empty load-test baseline → refused before the change
setup; STUB_NOPKGS=1; export STUB_NOPKGS; run --debs "$T/debs" --commit; unset STUB_NOPKGS
if [[ $RC -eq 3 ]] && grep -q 'the load test loaded no package' <<<"$OUT" && [[ "$(installs)" -eq 0 ]] \
   && [[ "$(ver r-base-core)" == 4.5.3-1.2404.0 ]]; then
  pass "R16 load test without a baseline → refused, host unchanged"; else fail "R16 (rc=$RC): $OUT"; fi

# R17 same minor version (4.6.0 -> 4.6.x): no r-cran rebuild in the plan
setup; sed -i 's/4.5.3-1.2404.0/4.6.0-0.2404.0/' "$T/state.tsv"; for p in r-base r-base-core r-base-dev r-recommended; do : > "$T/cache/${p}_4.6.0-0.2404.0_amd64.deb"; done
run --debs "$T/debs"
if [[ $RC -eq 0 ]] && ! grep -q 'r-cran-mlr3' <<<"$OUT" && ! grep -q 'user libraries' <<<"$OUT"; then
  pass "R17 patch-level change: only the core packages"; else fail "R17 (rc=$RC): $OUT"; fi

echo
if [[ $FAILS -eq 0 ]]; then printf '%bALL PASS%b\n' "$C_GREEN" "$C_RESET"; else printf '%b%d FAILURE(S)%b\n' "$C_RED" "$FAILS" "$C_RESET"; exit 1; fi
