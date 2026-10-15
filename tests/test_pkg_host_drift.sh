#!/usr/bin/env bash
# tests/test_pkg_host_drift.sh — scripts/99_check_pkg_host_drift.sh
#
# Builds fake R library trees under mktemp and checks snapshot + compare.
# Reproduces the 2026-10-15 case: mlr3 on biome-calc01 only, future
# 1.76.0 vs 1.70.0 (ADR-0004). No R, no root, no network needed.
#
# Exit: 0 all pass | 1 at least one failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TOOL="${SCRIPT_DIR}/../scripts/99_check_pkg_host_drift.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; NC=""; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { printf "%sPASS%s %s\n" "$GREEN" "$NC" "$1"; }
fail() { printf "%sFAIL%s %s\n" "$RED" "$NC" "$1"; fails=$((fails + 1)); }

# mkpkg LIB PACKAGE VERSION
mkpkg() {
  mkdir -p "$1/$2"
  printf 'Package: %s\nType: Package\nVersion: %s\nTitle: fake\n' "$2" "$3" > "$1/$2/DESCRIPTION"
}

# run CMD... → sets RC and OUTPUT (never aborts the test on non-zero)
run() { set +e; OUTPUT="$("$@" 2>&1)"; RC=$?; set -e; }

# expect_rc WANT LABEL — after run()
expect_rc() { if [[ $RC -eq $1 ]]; then pass "$2"; else fail "$2 (rc=$RC)"; fi; }

# set_host FILE NAME — snapshots taken here all carry this machine's hostname
set_host() { sed -i "s/^# host=.*/# host=$2/" "$1"; }

# ── host A: biome-calc01-like ──
A="$WORK/a"
mkpkg "$A/usr_local" ranger 0.17.0
mkpkg "$A/usr_site" ranger 0.18.0
mkpkg "$A/usr_site" future 1.76.0
mkpkg "$A/usr_site" mlr3 1.8.0
mkpkg "$A/usr_site" mlr3spatiotempcv 2.3.5
mkpkg "$A/base_lib" base 4.6.0
LIBS_A=(--lib "$A/usr_local" --lib "$A/usr_site" --lib "$A/base_lib")

# ── host B: biome-calc04-like ──
B="$WORK/b"
mkpkg "$B/usr_local" ranger 0.17.0
mkpkg "$B/usr_site" ranger 0.18.0
mkpkg "$B/usr_site" future 1.70.0
mkpkg "$B/base_lib" base 4.6.0
LIBS_B=(--lib "$B/usr_local" --lib "$B/usr_site" --lib "$B/base_lib")

# S0: script hygiene
if sed -n '2,40p' "$TOOL" | grep -q '^set -euo pipefail$'; then pass "S0 set -euo pipefail present"; else fail "S0 set -euo pipefail missing"; fi

# T1: snapshot format, first-library-wins, sorted, R version
run "$TOOL" --snapshot "${LIBS_A[@]}"
if [[ $RC -eq 0 ]] \
   && [[ "$(head -n1 <<<"$OUTPUT")" == "# biome-pkg-snapshot v1" ]] \
   && grep -q '^# r_version=4.6.0$' <<<"$OUTPUT" \
   && grep -qP '^ranger\t0\.17\.0\t' <<<"$OUTPUT" \
   && ! grep -qP '^ranger\t0\.18\.0' <<<"$OUTPUT" \
   && [[ "$(grep -v '^#' <<<"$OUTPUT" | cut -f1 | tr '\n' ' ')" == "base future mlr3 mlr3spatiotempcv ranger " ]]; then
  pass "T1 snapshot: header, R version, first library wins, sorted"
else
  fail "T1 snapshot (rc=$RC): $OUTPUT"
fi

# T2: snapshot is the default mode
run "$TOOL" "${LIBS_A[@]}"
if [[ $RC -eq 0 && "$(head -n1 <<<"$OUTPUT")" == "# biome-pkg-snapshot v1" ]]; then pass "T2 default mode is --snapshot"; else fail "T2 default mode (rc=$RC)"; fi

# T3: --out writes atomically, no temp file left
"$TOOL" --snapshot "${LIBS_A[@]}" --out "$WORK/a.tsv" 2>/dev/null
"$TOOL" --snapshot "${LIBS_B[@]}" --out "$WORK/b.tsv" 2>/dev/null
set_host "$WORK/a.tsv" biome-calc01
set_host "$WORK/b.tsv" biome-calc04
if [[ -s "$WORK/a.tsv" && -s "$WORK/b.tsv" ]] && [[ -z "$(find "$WORK" -maxdepth 1 -name '*.tsv.*')" ]]; then
  pass "T3 --out written, no temp file left"
else
  fail "T3 --out"
fi

# T4: identical hosts → exit 0
cp "$WORK/a.tsv" "$WORK/a2.tsv"; set_host "$WORK/a2.tsv" biome-calc02
run "$TOOL" --compare "$WORK/a.tsv" "$WORK/a2.tsv"
if [[ $RC -eq 0 ]] && grep -q 'no drift' <<<"$OUTPUT"; then pass "T4 identical hosts → exit 0"; else fail "T4 (rc=$RC): $OUTPUT"; fi

# T5: the 2026-10-15 case → exit 1, mlr3 missing on calc04, future mismatch
run "$TOOL" --compare "$WORK/a.tsv" "$WORK/b.tsv"
if [[ $RC -eq 1 ]] \
   && grep -qE '^mlr3 +1\.8\.0 +- *$' <<<"$OUTPUT" \
   && grep -qE '^mlr3spatiotempcv +2\.3\.5 +- *$' <<<"$OUTPUT" \
   && grep -qE '^future +1\.76\.0 +1\.70\.0 *$' <<<"$OUTPUT" \
   && ! grep -qE '^ranger ' <<<"$OUTPUT" \
   && grep -q 'missing on some host: 2 | version mismatch: 1' <<<"$OUTPUT" \
   && grep -qE 'PACKAGE +biome-calc01 +biome-calc04' <<<"$OUTPUT"; then
  pass "T5 calc01 vs calc04: mlr3 missing, future 1.76.0≠1.70.0, ranger equal not listed"
else
  fail "T5 (rc=$RC): $OUTPUT"
fi

# T6: R version differs alone → drift
cp "$WORK/a.tsv" "$WORK/a3.tsv"; set_host "$WORK/a3.tsv" biome-calc03
sed -i 's/^# r_version=.*/# r_version=4.5.2/' "$WORK/a3.tsv"
run "$TOOL" --compare "$WORK/a.tsv" "$WORK/a3.tsv"
if [[ $RC -eq 1 ]] && grep -q 'R version differs' <<<"$OUTPUT"; then pass "T6 R version mismatch → exit 1"; else fail "T6 (rc=$RC): $OUTPUT"; fi

# T7: same hostname twice is kept apart
cp "$WORK/b.tsv" "$WORK/b2.tsv"
run "$TOOL" --compare "$WORK/b.tsv" "$WORK/b2.tsv"
if [[ $RC -eq 0 ]] && grep -qE 'PACKAGE +biome-calc04 +biome-calc04#2' <<<"$OUTPUT"; then pass "T7 duplicate host label → host#2"; else fail "T7 (rc=$RC): $OUTPUT"; fi

# T8: error handling
printf 'not a snapshot\n' > "$WORK/bad.tsv"
run "$TOOL" --compare "$WORK/a.tsv" "$WORK/bad.tsv"; expect_rc 3 "T8a invalid snapshot → 3"
run "$TOOL" --compare "$WORK/a.tsv" "$WORK/nope.tsv"; expect_rc 3 "T8b missing file → 3"
run "$TOOL" --compare "$WORK/a.tsv"; expect_rc 2 "T8c one file → 2"
run "$TOOL" --bogus; expect_rc 2 "T8d unknown option → 2"
run "$TOOL" --snapshot --lib "$WORK/does-not-exist"; expect_rc 3 "T8e no library → 3"

# T9: read-only — library trees unchanged after snapshot
before="$(find "$A" -type f -exec md5sum {} + | sort)"
"$TOOL" --snapshot "${LIBS_A[@]}" >/dev/null
after="$(find "$A" -type f -exec md5sum {} + | sort)"
if [[ "$before" == "$after" ]]; then pass "T9 snapshot is read-only"; else fail "T9 library tree changed"; fi

echo
if [[ $fails -eq 0 ]]; then echo "${GREEN}ALL PASS${NC}"; exit 0; fi
echo "${RED}${fails} FAILURE(S)${NC}"; exit 1
