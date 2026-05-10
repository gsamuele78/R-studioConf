#!/usr/bin/env bash
# scripts/99_check_user_renviron_overrides.sh
# -----------------------------------------------------------------------------
# Audit (and optionally cleanup) ~/.Renviron overrides.
#
# Default mode is READ-ONLY audit. Cleanup mode (--fix) only triggers on
# explicit operator opt-in, and ONLY comments out the offending lines with
# a dated marker after writing a timestamped backup. Cleanup never deletes
# any file and never touches lines unrelated to R_LIBS_USER / R_LIBS_SITE /
# R_LIBS.
#
# Why this exists
#   v12.4 deploys the per-user local-disk lib path via /etc/R/Renviron.site:
#     R_LIBS_USER=/var/lib/biome-Rlibs/%u/%v:${HOME}/R/x86_64-pc-linux-gnu-library/%v
#   R precedence: $R_HOME/etc/Renviron → /etc/R/Renviron.site → ~/.Renviron
#   (LAST WINS). Pre-v12.4 .Renviron files (often arrived via rsync from
#   the previous server) carry a hard-coded R_LIBS_USER override that
#   (a) hides /var/lib/biome-Rlibs (loss of local-disk speed-up),
#   (b) may point to a stale R version (e.g. 4.6 path while R is 4.5.3).
#
# HC-13 interpretation
#   Invariant #17 forbids "silently patching user scripts/files".  This
#   script is NOT silent: cleanup is opt-in, dry-run by default, fully
#   logged, comments-only (reversible), and writes a backup.  When the
#   operator runs `--fix --commit` they have given explicit consent to
#   apply the cleanup; the script still leaves a clear audit trail.
#
# Usage:
#   sudo $0                          # audit, no changes
#   sudo $0 -o /tmp/audit.csv        # audit + CSV report
#   sudo $0 -d /nfs/home             # custom NFS home base
#   sudo $0 --fix                    # DRY-RUN cleanup (shows diffs only)
#   sudo $0 --fix --commit           # ACTUAL cleanup: backup + comment-out
#   sudo $0 --fix --commit -y        # skip the y/N confirmation prompt
#
# Cleanup behaviour (--fix --commit):
#   - Backs up each affected file to  <file>.bak.<UTC timestamp>
#   - Comments out matching lines in-place by prepending:
#       # [biome-cleanup YYYY-MM-DD] disabled (was: <original line>)
#     The original line is left after the marker as a real comment so the
#     user can trivially re-enable it if they really want to.
#   - Preserves owner/group/permissions of the original file.
#   - Touches NOTHING else in the file.
#
# Exit codes:
#   0 — audit / fix completed
#   2 — usage error or NFS base unreadable
#
# Tier: T1 (host) — audit/cleanup helper, no version bump.
# See:  docs/operations/UPGRADE_TO_v12.4.md  §10
# -----------------------------------------------------------------------------
set -euo pipefail

# --- Color vars (mirror lib/common_utils.sh) -----------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Defaults ------------------------------------------------------------------
NFS_HOME_DEFAULT="/nfs/home"
NFS_HOME=""
CSV_OUT=""
FIX_MODE=0
COMMIT=0
ASSUME_YES=0
SCRIPT_DIR="$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")"
CONF_FILE="${SCRIPT_DIR}/../config/setup_nodes.vars.conf"

# Read NFS_HOME from project conf if available (single source of truth)
if [[ -r "$CONF_FILE" ]]; then
    NFS_HOME_FROM_CONF="$(awk -F'=' '/^[[:space:]]*NFS_HOME[[:space:]]*=/ {gsub(/"/,"",$2); gsub(/[[:space:]]/,"",$2); print $2; exit}' "$CONF_FILE" || true)"
    [[ -n "${NFS_HOME_FROM_CONF:-}" ]] && NFS_HOME="$NFS_HOME_FROM_CONF"
fi
NFS_HOME="${NFS_HOME:-$NFS_HOME_DEFAULT}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-d DIR] [-o CSV] [--fix [--commit] [-y]] [-h]

Read-only audit of ~/.Renviron files for R_LIBS_USER / R_LIBS_SITE / R_LIBS
overrides that defeat the system-wide /etc/R/Renviron.site.

Options:
  -d DIR        NFS home base (default: ${NFS_HOME})
  -o FILE       Also write CSV report to FILE
  --fix         Cleanup mode: comment out offending lines (DRY-RUN unless --commit)
  --commit      With --fix: actually write changes (backup + in-place comment-out)
  -y, --yes     Skip confirmation prompt for --fix --commit
  -h, --help    This help

Without --fix, this script DOES NOT modify any user file.
EOF
}

# --- Argument parsing (manual, for long opts) ----------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) NFS_HOME="${2:?}"; shift 2 ;;
        -o) CSV_OUT="${2:?}"; shift 2 ;;
        --fix) FIX_MODE=1; shift ;;
        --commit) COMMIT=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf "${RED}ERROR:${NC} unknown argument: %s\n" "$1" >&2; usage >&2; exit 2 ;;
    esac
done

# --- Sanity --------------------------------------------------------------------
if [[ ! -d "$NFS_HOME" ]]; then
    printf "${RED}ERROR:${NC} home base not found or not readable: %s\n" "$NFS_HOME" >&2
    exit 2
fi
if [[ $COMMIT -eq 1 && $FIX_MODE -eq 0 ]]; then
    printf "${RED}ERROR:${NC} --commit requires --fix\n" >&2
    exit 2
fi

# Detect installed R version (X.Y).
R_VER_INSTALLED=""
if command -v R >/dev/null 2>&1; then
    R_VER_INSTALLED="$(R --version 2>/dev/null | awk '/^R version/ {print $3; exit}' | awk -F. '{print $1"."$2}')"
fi
[[ -z "$R_VER_INSTALLED" ]] && R_VER_INSTALLED="?.?"

# --- Header --------------------------------------------------------------------
MODE_STR="AUDIT (read-only)"
[[ $FIX_MODE -eq 1 && $COMMIT -eq 0 ]] && MODE_STR="FIX (DRY-RUN — no changes)"
[[ $FIX_MODE -eq 1 && $COMMIT -eq 1 ]] && MODE_STR="FIX (COMMIT — files WILL be modified)"

printf "${CYAN}====================================================================${NC}\n"
printf "${CYAN}  ~/.Renviron override audit${NC}\n"
printf "${CYAN}====================================================================${NC}\n"
printf "  NFS home base : %s\n"  "$NFS_HOME"
printf "  Installed R   : %s\n"  "$R_VER_INSTALLED"
printf "  Mode          : %s\n"  "$MODE_STR"
[[ -n "$CSV_OUT" ]] && printf "  CSV output    : %s\n" "$CSV_OUT"
printf "\n"

# --- Confirmation prompt for destructive mode ---------------------------------
if [[ $FIX_MODE -eq 1 && $COMMIT -eq 1 && $ASSUME_YES -eq 0 ]]; then
    printf "${YELLOW}About to comment-out R_LIBS_USER/R_LIBS_SITE/R_LIBS lines in %s/*/.Renviron files.${NC}\n" "$NFS_HOME"
    printf "${YELLOW}A timestamped backup will be created next to each modified file.${NC}\n"
    printf "Continue? [y/N] "
    read -r ans
    if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
        printf "${RED}Aborted by operator.${NC}\n"
        exit 0
    fi
fi

# --- CSV header ----------------------------------------------------------------
if [[ -n "$CSV_OUT" ]]; then
    : > "$CSV_OUT"
    printf 'user,renviron_path,line_no,variable,value,flags,action\n' >> "$CSV_OUT"
fi

# --- Collect .Renviron files (recursive: catches OldUsers/* too) --------------
mapfile -t RFILES < <(find "$NFS_HOME" -maxdepth 4 -type f -name '.Renviron' 2>/dev/null | sort)

# Pattern (extended regex)
PATTERN='^[[:space:]]*(R_LIBS_USER|R_LIBS_SITE|R_LIBS)[[:space:]]*='

SHOWN_TABLE_HEADER=0
declare -i FILES_SCANNED=0
declare -i FILES_TOUCHED=0
declare -i USERS_WITH_OVERRIDE=0
declare -i HITS_TOTAL=0
declare -i HITS_STALE=0
declare -i HITS_FIXED=0

TODAY="$(date -u +%Y-%m-%d)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

for rfile in "${RFILES[@]}"; do
    FILES_SCANNED+=1
    # Derive a "user" label from the parent dir (handles /nfs/home/<u>/.Renviron
    # and /nfs/home/OldUsers/<u>/.Renviron alike).
    parent_dir="$(dirname "$rfile")"
    user="$(basename "$parent_dir")"
    grandparent="$(basename "$(dirname "$parent_dir")")"
    if [[ "$grandparent" != "$(basename "$NFS_HOME")" ]]; then
        # nested (e.g. OldUsers/<u>) → prefix for clarity
        user="${grandparent}/${user}"
    fi

    matches="$(grep -nE "$PATTERN" "$rfile" 2>/dev/null || true)"
    [[ -z "$matches" ]] && continue
    USERS_WITH_OVERRIDE+=1

    if [[ $SHOWN_TABLE_HEADER -eq 0 ]]; then
        printf "${YELLOW}Findings:${NC}\n\n"
        printf "| %-30s | %-3s | %-13s | %-45s | %-30s | %s\n" "user" "ln" "variable" "value" "flags" "action"
        printf "|--------------------------------|-----|---------------|-----------------------------------------------|--------------------------------|---------------\n"
        SHOWN_TABLE_HEADER=1
    fi

    file_modified_this_run=0
    declare -a LINES_TO_COMMENT=()

    while IFS= read -r line; do
        HITS_TOTAL+=1
        ln="${line%%:*}"
        rest="${line#*:}"
        var="$(printf '%s' "$rest" | sed -E 's/^[[:space:]]*([A-Z_]+)[[:space:]]*=.*/\1/')"
        val="$(printf '%s' "$rest" | sed -E 's/^[[:space:]]*[A-Z_]+[[:space:]]*=[[:space:]]*//')"
        val_clean="$(printf '%s' "$val" | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/')"

        flags=()
        [[ "$var" == "R_LIBS_USER" ]] && flags+=("OVERRIDES-SYSTEM")

        # v12.9.2: WRITER-CONFLICT — file has BOTH a previous biome-cleanup
        # comment-out marker AND a still-live R_LIBS_* line. This means a
        # third writer in the deploy chain re-introduced the override after
        # an earlier `--fix --commit` run. Fragment 04 v12.9.2 makes this
        # benign at runtime via the canonical-path fallback, but ops should
        # still know the file is under contention.
        if grep -qE '^# \[biome-cleanup [0-9-]+\] disabled \(was: R_LIBS_(USER|SITE|LIBS)' "$rfile" 2>/dev/null; then
            cleanup_date="$(grep -m1 -oE '\[biome-cleanup [0-9-]+\]' "$rfile" 2>/dev/null \
                | sed -E 's/^\[biome-cleanup ([0-9-]+)\]$/\1/')"
            flags+=("WRITER-CONFLICT:since-${cleanup_date:-?}")
        fi

        stale_ver="$(printf '%s' "$val_clean" | sed -nE 's|.*/library/([0-9]+\.[0-9]+).*|\1|p' | head -n1)"
        [[ -z "$stale_ver" ]] && stale_ver="$(printf '%s' "$val_clean" | sed -nE 's|.*x86_64-pc-linux-gnu-library/([0-9]+\.[0-9]+).*|\1|p' | head -n1)"
        if [[ -n "$stale_ver" && "$R_VER_INSTALLED" != "?.?" && "$stale_ver" != "$R_VER_INSTALLED" ]]; then
            flags+=("STALE-VERSION:${stale_ver}≠${R_VER_INSTALLED}")
            HITS_STALE+=1
        fi
        flags_csv="$(IFS=';'; printf '%s' "${flags[*]:-}")"
        flags_disp="${flags_csv:-(none)}"

        # Decide action
        action="audit-only"
        if [[ $FIX_MODE -eq 1 ]]; then
            if [[ $COMMIT -eq 1 ]]; then
                action="will-comment"
            else
                action="dry-run-comment"
            fi
            LINES_TO_COMMENT+=("$ln")
        fi

        flag_color="${YELLOW}"
        [[ "$flags_csv" == *"STALE-VERSION"* ]] && flag_color="${RED}"

        val_disp="$val_clean"
        [[ ${#val_disp} -gt 45 ]] && val_disp="${val_disp:0:42}..."

        printf "| %-30s | %3s | %-13s | %-45s | ${flag_color}%-30s${NC} | %s\n" \
            "$user" "$ln" "$var" "$val_disp" "$flags_disp" "$action"

        if [[ -n "$CSV_OUT" ]]; then
            val_csv="${val_clean//\"/\"\"}"
            printf '%s,%s,%s,%s,"%s","%s","%s"\n' "$user" "$rfile" "$ln" "$var" "$val_csv" "$flags_csv" "$action" >> "$CSV_OUT"
        fi
    done <<< "$matches"

    # ------------------------------------------------------------------
    # Apply cleanup (only with --fix --commit)
    # ------------------------------------------------------------------
    if [[ $FIX_MODE -eq 1 && $COMMIT -eq 1 && ${#LINES_TO_COMMENT[@]} -gt 0 ]]; then
        backup="${rfile}.bak.${TS}"
        # Preserve attributes via cp -p
        cp -p -- "$rfile" "$backup"

        # Build sed program: for each target line N, replace with
        #   # [biome-cleanup YYYY-MM-DD] disabled (was: <orig>)
        #   # <orig>
        # Use a temp file for safety.
        tmp="$(mktemp "${rfile}.tmpXXXXXX")"
        # Preserve owner/group of original
        chown --reference="$rfile" "$tmp" 2>/dev/null || true
        chmod --reference="$rfile" "$tmp" 2>/dev/null || true

        awk -v marker="# [biome-cleanup ${TODAY}] disabled (was:" \
            -v lines="$(IFS=,; echo "${LINES_TO_COMMENT[*]}")" '
            BEGIN {
                n = split(lines, arr, ",")
                for (i = 1; i <= n; i++) target[arr[i]] = 1
            }
            {
                if (NR in target) {
                    printf "%s %s)\n", marker, $0
                    printf "# %s\n", $0
                    fixed++
                } else {
                    print $0
                }
            }
            END { exit 0 }
        ' "$rfile" > "$tmp"

        mv -f -- "$tmp" "$rfile"
        FILES_TOUCHED+=1
        HITS_FIXED=$((HITS_FIXED + ${#LINES_TO_COMMENT[@]}))
        printf "    ${GREEN}↳ patched${NC} %s  (backup: %s)\n" "$rfile" "$backup"
    fi
    unset LINES_TO_COMMENT
done

# --- Summary -------------------------------------------------------------------
printf "\n${CYAN}--------------------------------------------------------------------${NC}\n"
printf "Files scanned         : %d\n" "$FILES_SCANNED"
printf "Users with override   : %d\n" "$USERS_WITH_OVERRIDE"
printf "Total override lines  : %d\n" "$HITS_TOTAL"
printf "Stale R version hits  : %d  (installed R = %s)\n" "$HITS_STALE" "$R_VER_INSTALLED"
if [[ $FIX_MODE -eq 1 ]]; then
    if [[ $COMMIT -eq 1 ]]; then
        printf "Files modified        : %d\n" "$FILES_TOUCHED"
        printf "Lines commented out   : %d\n" "$HITS_FIXED"
        printf "Backups suffix        : .bak.%s\n" "$TS"
    else
        printf "${YELLOW}DRY-RUN:${NC} re-run with --fix --commit to actually apply.\n"
    fi
fi
[[ -n "$CSV_OUT" ]] && printf "CSV report written to : %s\n" "$CSV_OUT"

if [[ $USERS_WITH_OVERRIDE -gt 0 && $FIX_MODE -eq 0 ]]; then
    printf "\n${YELLOW}NEXT STEPS:${NC}\n"
    printf "  • To clean up legacy rsync'd .Renviron files (operator opt-in):\n"
    printf "      sudo $(basename "$0") --fix              # dry-run preview\n"
    printf "      sudo $(basename "$0") --fix --commit     # apply (with backups)\n"
    printf "  • Or email each user the template in:\n"
    printf "      docs/operations/UPGRADE_TO_v12.4.md  §10\n"
    printf "  • Verify per user post-cleanup:\n"
    printf "      su - <user> -c 'R --no-init-file -e \".libPaths()\"'\n"
    printf "    The first path should be /var/lib/biome-Rlibs/<user>/%s\n" "$R_VER_INSTALLED"
elif [[ $USERS_WITH_OVERRIDE -eq 0 ]]; then
    printf "\n${GREEN}OK:${NC} no R_LIBS_USER / R_LIBS_SITE / R_LIBS overrides detected.\n"
fi

exit 0
