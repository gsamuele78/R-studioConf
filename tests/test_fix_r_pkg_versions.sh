#!/usr/bin/env bash
# tests/test_fix_r_pkg_versions.sh — scripts/fix_r_pkg_versions_inplace.sh
#
# apt-get, apt-cache, dpkg-query, pgrep and id are stubbed on PATH; the fake
# dpkg state is a TSV under mktemp. Never touches apt, dpkg or /var.
#
# Exit: 0 all pass | 1 at least one failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SUT="${SCRIPT_DIR}/../scripts/fix_r_pkg_versions_inplace.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; NC=""; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { printf "%sPASS%s %s\n" "$GREEN" "$NC" "$1"; }
fail() { printf "%sFAIL%s %s\n" "$RED" "$NC" "$1"; fails=$((fails + 1)); }

# ── stubs ──
mkdir -p "$T/bin"
cat > "$T/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
# dpkg-query -W -f=FMT PATTERN|PKG
fmt="${2#-f=}"; what="$3"
if [[ "$what" == 'r-cran-*' ]]; then
  awk -F'\t' '{print "ii \t" $1 "\t" $2}' "$STUB_STATE"; exit 0
fi
v="$(awk -F'\t' -v p="$what" '$1==p{print $2}' "$STUB_STATE")"
[[ -n "$v" ]] || exit 1
printf '%s' "$v"
EOF
cat > "$T/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STUB_LOG"
case "$*" in
  update*) exit 0 ;;
  "-s -q install --only-upgrade"*) cat "$STUB_SIM"; exit 0 ;;
  download*) p="${3%%=*}"; v="${3#*=}"; touch "${p}_${v}_all.deb"; exit 0 ;;
  "install -y -q --only-upgrade"*)
    [[ "${STUB_INSTALL_FAIL:-0}" == 1 ]] && exit 100
    shift 4
    for p in "$@"; do
      nv="$(awk -v p="$p" '$1=="Inst" && $2==p {v=$4; sub(/^\(/,"",v); print v}' "$STUB_SIM")"
      awk -F'\t' -v p="$p" -v v="$nv" 'BEGIN{OFS="\t"} $1==p{$2=v} {print}' "$STUB_STATE" > "$STUB_STATE.n" && mv "$STUB_STATE.n" "$STUB_STATE"
    done; exit 0 ;;
  "install -y -q --allow-downgrades"*)
    shift 4
    for d in "$@"; do
      b="$(basename "$d" .deb)"; p="${b%%_*}"; r="${b#*_}"; v="${r%_*}"
      awk -F'\t' -v p="$p" -v v="$v" 'BEGIN{OFS="\t"} $1==p{$2=v} {print}' "$STUB_STATE" > "$STUB_STATE.n" && mv "$STUB_STATE.n" "$STUB_STATE"
    done; exit 0 ;;
esac
echo "unexpected apt-get call: $*" >&2; exit 99
EOF
cat > "$T/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
# apt-cache madison PKG → versions listed in $STUB_REPO (pkg<TAB>ver)
awk -F'\t' -v p="$2" '$1==p {printf "%s | %s | r2u\n", p, $2}' "$STUB_REPO"
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
chmod +x "$T/bin/"*

# fresh scenario: two upgrades (one rollback via cache, one via repo), one up to date
setup() {
  rm -rf "$T/s"; mkdir -p "$T/s/archives" "$T/s/backup"
  printf 'r-cran-future\t1.70.0-1.ca2404.1\nr-cran-rlang\t1.2.0-1.ca2404.1\nr-cran-terra\t1.9-50-1.ca2404.1\n' > "$T/s/state.tsv"
  cat > "$T/s/sim.txt" <<'EOS'
NOTE: This is only a simulation!
Inst r-cran-future [1.70.0-1.ca2404.1] (1.76.0-1.ca2404.1 r2u:noble [all])
Inst r-cran-rlang [1.2.0-1.ca2404.1] (1.3.0-1.ca2404.1 r2u:noble [amd64])
Conf r-cran-future (1.76.0-1.ca2404.1 r2u:noble [all])
Conf r-cran-rlang (1.3.0-1.ca2404.1 r2u:noble [amd64])
EOS
  touch "$T/s/archives/r-cran-future_1.70.0-1.ca2404.1_all.deb"
  printf 'r-cran-rlang\t1.3.0-1.ca2404.1\nr-cran-rlang\t1.2.0-1.ca2404.1\n' > "$T/s/repo.tsv"
  : > "$T/s/apt.log"
  export STUB_STATE="$T/s/state.tsv" STUB_SIM="$T/s/sim.txt" STUB_REPO="$T/s/repo.tsv" STUB_LOG="$T/s/apt.log"
  export FIX_PKG_BACKUP_ROOT="$T/s/backup" FIX_PKG_APT_ARCHIVES="$T/s/archives"
  export STUB_UID=0 STUB_SESSIONS=0 STUB_INSTALL_FAIL=0
}
run() { set +e; OUT="$(PATH="$T/bin:$PATH" bash "$SUT" "$@" 2>&1)"; RC=$?; set -e; }
installs() { grep -c '^apt-get install' "$STUB_LOG" || true; }
ver() { awk -F'\t' -v p="$1" '$1==p{print $2}' "$STUB_STATE"; }

# S0
if sed -n '1,3p' "$SUT" | grep -q '^set -euo pipefail$'; then pass "S0 set -euo pipefail on line 2"; else fail "S0"; fi

# T1 dry-run: plan + coverage, no install
setup; run
if [[ $RC -eq 0 ]] && grep -q '2 package(s) to upgrade' <<<"$OUT" && grep -q 'r-cran-future .*1.70.0-1.ca2404.1 -> 1.76.0-1.ca2404.1' <<<"$OUT" \
   && grep -q 'rollback possible for 2/2' <<<"$OUT" && [[ "$(installs)" -eq 0 ]] && [[ -z "$(ls "$T/s/backup")" ]]; then
  pass "T1 dry-run shows plan and rollback coverage, changes nothing"
else fail "T1 (rc=$RC): $OUT"; fi

# T2 plan touching r-base-core → refused even in dry-run
setup; printf 'Inst r-base-core [4.6.0-1] (4.6.1-1 CRAN:noble [amd64])\n' >> "$T/s/sim.txt"; run --commit
if [[ $RC -eq 1 ]] && grep -q 'HARD RULE 19' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then pass "T2 r-base-core in plan → refused"; else fail "T2 (rc=$RC): $OUT"; fi

# T3 plan removing a package → refused
setup; printf 'Remv r-cran-old [1.0-1]\n' >> "$T/s/sim.txt"; run --commit
if [[ $RC -eq 1 ]] && grep -q 'removes packages' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then pass "T3 removal in plan → refused"; else fail "T3 (rc=$RC): $OUT"; fi

# T4 commit as non-root → refused
setup; export STUB_UID=1000; run --commit
if [[ $RC -eq 1 ]] && grep -q 'needs root' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then pass "T4 non-root commit → refused"; else fail "T4 (rc=$RC): $OUT"; fi

# T5 active sessions → refused; override proceeds
setup; export STUB_SESSIONS=3; run --commit
if [[ $RC -eq 1 ]] && grep -q '3 RStudio session' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then pass "T5a active sessions → refused"; else fail "T5a (rc=$RC): $OUT"; fi
run --commit --allow-active-sessions
if [[ $RC -eq 0 ]]; then pass "T5b --allow-active-sessions proceeds"; else fail "T5b (rc=$RC): $OUT"; fi

# T6 commit: backup first, upgrade, verify; up-to-date package untouched
setup; run --commit
BK="$(find "$T/s/backup" -maxdepth 1 -name 'r-pkg-align-*' | head -1)"
if [[ $RC -eq 0 ]] && [[ -f "$BK/before.tsv" && -f "$BK/plan.tsv" && -f "$BK/after.tsv" ]] \
   && [[ -f "$BK/debs/r-cran-future_1.70.0-1.ca2404.1_all.deb" && -f "$BK/debs/r-cran-rlang_1.2.0-1.ca2404.1_all.deb" ]] \
   && [[ "$(ver r-cran-future)" == 1.76.0-1.ca2404.1 && "$(ver r-cran-rlang)" == 1.3.0-1.ca2404.1 && "$(ver r-cran-terra)" == 1.9-50-1.ca2404.1 ]] \
   && grep -q '^apt-get install -y -q --only-upgrade r-cran-future r-cran-rlang$' "$STUB_LOG" \
   && [[ "$(grep -n 'download' "$STUB_LOG" | cut -d: -f1)" -lt "$(grep -n '^apt-get install' "$STUB_LOG" | cut -d: -f1)" ]]; then
  pass "T6 commit: old debs saved before upgrade, versions verified, terra untouched"
else fail "T6 (rc=$RC): $OUT"; fi

# T7 rollback restores old versions
run --rollback "$BK"
if [[ $RC -eq 0 && "$(ver r-cran-future)" == 1.70.0-1.ca2404.1 && "$(ver r-cran-rlang)" == 1.2.0-1.ca2404.1 ]]; then pass "T7 rollback restores old versions"; else fail "T7 (rc=$RC): $OUT"; fi

# T8 partial rollback coverage → refused before any change; override proceeds
setup; : > "$T/s/repo.tsv"; run --commit
if [[ $RC -eq 1 ]] && grep -q 'rollback possible for 1/2' <<<"$OUT" && grep -q 'cannot be rolled back' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then
  pass "T8a partial rollback → refused, nothing installed"
else fail "T8a (rc=$RC): $OUT"; fi
run --commit --accept-partial-rollback
if [[ $RC -eq 0 && "$(ver r-cran-rlang)" == 1.3.0-1.ca2404.1 ]]; then pass "T8b --accept-partial-rollback proceeds"; else fail "T8b (rc=$RC): $OUT"; fi

# T9 nothing to upgrade
setup; grep -v '^Inst\|^Conf' "$T/s/sim.txt" > "$T/s/sim2" && mv "$T/s/sim2" "$T/s/sim.txt"; run --commit
if [[ $RC -eq 0 ]] && grep -q 'nothing to do' <<<"$OUT" && [[ "$(installs)" -eq 0 ]]; then pass "T9 up to date → nothing to do"; else fail "T9 (rc=$RC): $OUT"; fi

# T10 apt failure after backup → exit 1 with rollback hint
setup; export STUB_INSTALL_FAIL=1; run --commit
if [[ $RC -eq 1 ]] && grep -q -- '--rollback' <<<"$OUT"; then pass "T10 apt failure → exit 1 + rollback hint"; else fail "T10 (rc=$RC): $OUT"; fi

# T11 usage errors
setup; run --bogus
if [[ $RC -eq 2 ]]; then pass "T11a unknown arg → 2"; else fail "T11a rc=$RC"; fi
run --rollback
if [[ $RC -eq 2 ]]; then pass "T11b --rollback without dir → 2"; else fail "T11b rc=$RC"; fi

echo
if [[ $fails -eq 0 ]]; then echo "${GREEN}ALL PASS${NC}"; exit 0; fi
echo "${RED}${fails} FAILURE(S)${NC}"; exit 1
