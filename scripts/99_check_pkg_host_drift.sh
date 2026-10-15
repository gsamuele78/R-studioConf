#!/usr/bin/env bash
# scripts/99_check_pkg_host_drift.sh
# ============================================================================
# BIOME-CALC — Cross-host R package drift check (read-only)
# ----------------------------------------------------------------------------
# Why: bspm (enabled by Rprofile.site) installs a researcher's
# install.packages() through apt into /usr/lib/R/site-library of the host the
# researcher is on — and only that host. The same script then runs on one
# host and fails on another (2026-10-15: mlr3 present on biome-calc01,
# missing on biome-calc04; future 1.76.0 vs 1.70.0). See ADR-0004.
#
# scripts/99_check_pkg_drift.sh compares ONE host with its own past baseline.
# This script compares SEVERAL hosts with each other.
#
# Two steps:
#   1. --snapshot  on every host: lists the R packages in the system
#                  libraries (no R start, no Rprofile, no NFS lookups).
#   2. --compare   on any host: diffs two or more snapshots.
#
# Usage:
#   ./99_check_pkg_host_drift.sh                          # = --snapshot to stdout
#   ./99_check_pkg_host_drift.sh --snapshot --out FILE
#   ./99_check_pkg_host_drift.sh --compare calc01.tsv calc04.tsv [...]
#   --lib DIR (repeatable) overrides the scanned libraries, in .libPaths() order.
#
# Collect from all hosts (example):
#   for h in biome-calc01 biome-calc04; do
#     ssh "$h" /home/ladmin/configServices/R-studioConf/scripts/99_check_pkg_host_drift.sh \
#       > "/tmp/pkg_${h}.tsv"
#   done
#   ./99_check_pkg_host_drift.sh --compare /tmp/pkg_*.tsv
#
# Read-only: never installs, removes or writes outside --out.
# Exit: 0 = no drift | 1 = drift | 2 = usage error | 3 = unreadable/invalid input
# ============================================================================
set -euo pipefail

# ── colors (off when stdout is not a terminal) ──
if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[1;33m'; NC=$'\033[0m'
else
  GREEN=""; RED=""; YEL=""; NC=""
fi

readonly SNAPSHOT_MAGIC="# biome-pkg-snapshot v1"
DEFAULT_LIBS=(/usr/local/lib/R/site-library /usr/lib/R/site-library /usr/lib/R/library)

die() { printf "%s[ERROR]%s %s\n" "$RED" "$NC" "$2" >&2; exit "$1"; }

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }

for bin in awk sort hostname date; do
  command -v "$bin" >/dev/null 2>&1 || die 3 "required binary not found: $bin"
done

MODE="snapshot"
OUT=""
LIBS=()
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) MODE="snapshot" ;;
    --compare)  MODE="compare" ;;
    --out)      [[ $# -ge 2 ]] || die 2 "--out needs a file"; OUT="$2"; shift ;;
    --out=*)    OUT="${1#--out=}" ;;
    --lib)      [[ $# -ge 2 ]] || die 2 "--lib needs a directory"; LIBS+=("$2"); shift ;;
    --lib=*)    LIBS+=("${1#--lib=}") ;;
    -h|--help)  usage; exit 0 ;;
    --*)        die 2 "unknown option: $1 (see --help)" ;;
    *)          FILES+=("$1") ;;
  esac
  shift
done

# ── snapshot ────────────────────────────────────────────────────────────────
# Reads Package:/Version: from each <lib>/<pkg>/DESCRIPTION. The first library
# that has a package wins, as in R's .libPaths() order.
snapshot() {
  local -a libs=("$@")
  local lib r_version="unknown"
  for lib in "${libs[@]}"; do
    if [[ -f "$lib/base/DESCRIPTION" ]]; then
      r_version="$(awk -F': *' '$1=="Version"{print $2; exit}' "$lib/base/DESCRIPTION")"
      break
    fi
  done

  printf '%s\n' "$SNAPSHOT_MAGIC"
  printf '# host=%s\n' "$(hostname -s)"
  printf '# taken_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# r_version=%s\n' "${r_version:-unknown}"
  printf '# libs=%s\n' "${libs[*]}"

  # One awk per library (not per package): ~700 packages in well under a second.
  local -a descs
  for lib in "${libs[@]}"; do
    [[ -d "$lib" ]] || continue
    descs=("$lib"/*/DESCRIPTION)
    [[ -f "${descs[0]}" ]] || continue
    awk -F': *' -v lib="$lib" '
      function flush() { if (p != "" && v != "") printf "%s\t%s\t%s\n", p, v, lib; p = ""; v = "" }
      FNR == 1 { flush() }
      $1 == "Package" { p = $2 }
      $1 == "Version" { v = $2 }
      END { flush() }
    ' "${descs[@]}"
  done | awk -F'\t' '!seen[$1]++' | LC_ALL=C sort -t$'\t' -k1,1
}

# ── compare ─────────────────────────────────────────────────────────────────
compare() {
  local f
  for f in "$@"; do
    [[ -r "$f" ]] || die 3 "cannot read snapshot: $f"
    [[ "$(head -n1 "$f")" == "$SNAPSHOT_MAGIC" ]] || die 3 "not a snapshot (missing '$SNAPSHOT_MAGIC'): $f"
  done

  awk -F'\t' -v red="$RED" -v yel="$YEL" -v green="$GREEN" -v nc="$NC" '
    FNR == 1 { n++; host[n] = "file" n; rver[n] = "unknown" }
    /^# host=/      { h = substr($0, 8); used[h]++; host[n] = (used[h] > 1) ? h "#" used[h] : h; next }
    /^# r_version=/ { rver[n] = substr($0, 13); next }
    /^#/ { next }
    NF >= 2 { ver[$1, n] = $2; if (!($1 in pkgs)) { pkgs[$1] = 1; np++; plist[np] = $1 } }
    END {
      drift = 0
      rv = rver[1]; rdiff = 0
      for (i = 2; i <= n; i++) if (rver[i] != rv) rdiff = 1
      if (rdiff) {
        drift = 1
        printf "%sR version differs:%s", red, nc
        for (i = 1; i <= n; i++) printf " %s=%s", host[i], rver[i]
        printf "\n\n"
      }
      # stable order: sort package names
      for (i = 1; i <= np; i++) for (j = i + 1; j <= np; j++) if (plist[j] < plist[i]) { t = plist[i]; plist[i] = plist[j]; plist[j] = t }
      printf "%-28s", "PACKAGE"
      for (i = 1; i <= n; i++) printf " %-16s", host[i]
      printf "\n"
      missing = 0; mismatch = 0
      for (k = 1; k <= np; k++) {
        p = plist[k]; first = ""; differs = 0; absent = 0
        for (i = 1; i <= n; i++) {
          v = ((p, i) in ver) ? ver[p, i] : "-"
          if (v == "-") absent = 1
          if (i == 1) first = v; else if (v != first) differs = 1
        }
        if (!differs) continue
        if (absent) missing++; else mismatch++
        printf "%-28s", p
        for (i = 1; i <= n; i++) { v = ((p, i) in ver) ? ver[p, i] : "-"; printf " %-16s", v }
        printf "\n"
      }
      printf "\nHosts compared: %d | packages: %d | missing on some host: %d | version mismatch: %d\n", n, np, missing, mismatch
      if (missing + mismatch > 0) drift = 1
      if (drift) { printf "%s[DRIFT]%s hosts do not have the same R packages.\n", yel, nc; exit 1 }
      printf "%s[OK]%s no drift.\n", green, nc
      exit 0
    }
  ' "$@"
}

case "$MODE" in
  snapshot)
    [[ ${#FILES[@]} -eq 0 ]] || die 2 "--snapshot takes no file arguments (use --out FILE)"
    [[ ${#LIBS[@]} -gt 0 ]] || LIBS=("${DEFAULT_LIBS[@]}")
    found=0
    for lib in "${LIBS[@]}"; do [[ -d "$lib" ]] && found=1; done
    [[ "$found" -eq 1 ]] || die 3 "none of the libraries exist: ${LIBS[*]}"
    if [[ -n "$OUT" ]]; then
      tmp="$(mktemp "${OUT}.XXXXXX")" || die 3 "cannot write next to $OUT"
      trap 'rm -f "$tmp"' EXIT
      snapshot "${LIBS[@]}" > "$tmp"
      mv -f "$tmp" "$OUT"
      trap - EXIT
      printf "%s[OK]%s snapshot written: %s\n" "$GREEN" "$NC" "$OUT" >&2
    else
      snapshot "${LIBS[@]}"
    fi
    ;;
  compare)
    [[ ${#FILES[@]} -ge 2 ]] || die 2 "--compare needs at least two snapshot files"
    set +e
    compare "${FILES[@]}"
    rc=$?
    set -e
    exit "$rc"
    ;;
esac
