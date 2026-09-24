#!/usr/bin/env bash
set -euo pipefail
# scripts/99_check_rprofile_health.sh — RPROFILE HEALTH CHECK + PER-USER REPAIR
# HEALTH_VERSION="2.0"  (script-level only — does NOT bump RPROFILE_VERSION)
# ==============================================================================
# Sysadmin tool for the startup chain every RStudio OSS web session runs:
#
#   rsession-profile → Renviron.site → ~/.Renviron → Rprofile.site (dispatcher)
#   → Rprofile_site.d/ fragments (or .compiled/bundle.Rc) → ~/.Rprofile
#   → workspace restore (~/.RData, when RStudio's load_workspace is on)
#
# It answers two questions and, only on request, repairs the second:
#   1. Is the SYSTEM profile healthy on this node?        sections 1-6, 8-10
#   2. What in <user>'s own files/state breaks or         section 7 (--user)
#      degrades their session, compared with the system
#      baseline measured in the same run?
#
# ── MODES (nothing is modified without --commit) ─────────────────────────────
#   (default)                     check only
#   --fix                         check + print the repair plan for --user (dry-run)
#   --fix --commit [-y]           apply the plan, then re-run the checks to verify
#   --reset-profile [--commit]    quarantine <user>'s startup state into
#                                 ~/.biome-profile-quarantine/<STAMP>/ (reversible)
#   --undo-reset STAMP|list [--commit]
#                                 move a quarantined state back / list stamps
#
# ── WHAT IT MUTATES, EXACTLY ─────────────────────────────────────────────────
#   STATIC tier (1,2,3,5a-c,6,7a-f,10): read-only. Static R parsing uses
#     `R --vanilla` (no profile loaded, nothing created).
#   RUNTIME tier (4,5d,6-runtime,7g,8,9): loads the real dispatcher in a real R,
#     so the dispatcher's own side effects happen — exactly the ones a login
#     causes: /Rtmp/biome_<user>/{stan_compile,...}, /var/lib/biome-Rlibs/<user>/
#     <Rver> (fragment 04), ~/R/x86_64-pc-linux-gnu-library/<Rver>. Probes then
#     deregister deferred task callbacks (no Smart Cleanup run) and delete their
#     own /tmp/biome_{boot,frag}_errors_<pid>.log after reporting them.
#     7g additionally executes <user>'s own ~/.Renviron + ~/.Rprofile AS <user>
#     (what their RStudio login does anyway). --static-only skips the tier.
#   Probes run AS THE PROBED USER, never as root:
#     * root + --user NAME → `runuser -u NAME`, env -i (hermetic), cwd /
#       (7g: cwd = the user's home, like rsession)
#     * root without --user → runtime tier SKIPPED (would create root-owned
#       /Rtmp/biome_root/ + /var/lib/biome-Rlibs/root/). --allow-root-probes
#       overrides. Mirrors the HC-13 refuse-root guard of 99_diagnose_user_script.sh.
#     * non-root → probes as yourself; --user must then be yourself.
#   --fix --commit / --reset-profile --commit / --undo-reset --commit change
#     <user>'s files; every change is backed up (<file>.bak.<UTC stamp>) or
#     moved into the quarantine dir — never deleted.
#
# ── OWNERSHIP BOUNDARIES ─────────────────────────────────────────────────────
#   ~/.Renviron R_LIBS_USER / R_LIBS_SITE / R_LIBS are REPORTED, never changed
#   here: they are owned by scripts/50_setup_nodes.sh option 4 (Step 9, strips
#   them for all users, keeps .bak) and scripts/99_check_user_renviron_overrides.sh
#   (--fix --commit). System files (/etc/R, /etc/profile.d, /etc/rstudio) are
#   never modified: findings carry the exact redeploy command instead.
#   The user's .R scripts are never read or touched (HC-13).
#
# Exit codes:
#   0 — all checks passed
#   1 — at least one CRIT/FAIL (profile non-functional or a user file breaks it)
#   2 — warnings only (degraded, or runtime tier skipped)
#   3 — invocation error / refused (bad flags, unknown user, no TTY without -y)
#   4 — a requested fix / reset / undo could not be (fully) applied
#
# Environment:
#   BIOME_HEALTH_ROOT=<dir>            Test seam: prefix every deployed path,
#                                      the probed user's home and /Rtmp with
#                                      <dir>. Empty in production.
#   BIOME_HEALTH_ALLOW_ROOT_PROBES=1   Same as --allow-root-probes.
#   BIOME_HEALTH_PROBE_TIMEOUT_S=<n>   Per-probe timeout (default 60).
#
# Tier: T1 (host) — diagnostic/repair. See docs/operations/DIAGNOSTICS_INDEX.md §1
# ==============================================================================

# ── Colors (PSE convention; disabled when stdout is not a terminal) ────────
if [[ -t 1 ]]; then
    RED=$'\e[0;31m'; YELLOW=$'\e[0;33m'; GREEN=$'\e[0;32m'
    CYAN=$'\e[0;36m'; BOLD=$'\e[1m'; NC=$'\e[0m'
else
    RED=""; YELLOW=""; GREEN=""; CYAN=""; BOLD=""; NC=""
fi

# ── Path resolution ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

# ── Defaults ─────────────────────────────────────────────────────────────
TARGET_USER=""
STATIC_ONLY=false
ALLOW_ROOT_PROBES="${BIOME_HEALTH_ALLOW_ROOT_PROBES:-0}"
MODE="check"              # check | fix | reset | undo
COMMIT=false
ASSUME_YES=false
UNDO_STAMP=""
PROBE_TIMEOUT_S="${BIOME_HEALTH_PROBE_TIMEOUT_S:-60}"

FAILURES=0; WARNINGS=0; CHECKS_RUN=0
SYS_FAILS=0; USER_FAILS=0; USER_WARNS=0
SCOPE="system"            # attribution of report() lines: system | user
FAILED_CHECKS=()

# Thresholds (bytes / ms)
RDATA_FAIL_BYTES=$((1024 * 1024 * 1024))     # ≥1 GiB workspace restored at login
RSTATE_WARN_BYTES=$((1024 * 1024 * 1024))    # ≥1 GiB of RStudio session state
SLOW_START_WARN_MS=5000
SLOW_START_FAIL_MS=30000

# Known-good fragment inventory (must match templates/Rprofile_site.d/).
# Last synced: v12.10. Section 2f cross-checks against the repo templates.
EXPECTED_FRAGMENTS=(
    "04_user_lib_bootstrap.R" "05_thread_guard.R" "20_cgroup_reader.R"
    "30_psock_factory.R" "35_compile_routing.R" "40_wrapper_installer.R"
    "42_install_block.R" "45_memory_guards.R" "50_pkg_hooks.R"
    "52_mclapply_guard.R" "55_options_guard.R" "60_safe_setwd.R"
    "70_persistent_tools.R" "80_tools_ext.R"
)

# ── Deployed paths (BIOME_HEALTH_ROOT is empty in production) ─────────────
BIOME_HEALTH_ROOT="${BIOME_HEALTH_ROOT:-}"
RPROFILE="${BIOME_HEALTH_ROOT}/etc/R/Rprofile.site"
RPROFILE_FRAG_DIR="${BIOME_HEALTH_ROOT}/etc/R/Rprofile_site.d"
RPROFILE_BUNDLE_DIR="${BIOME_HEALTH_ROOT}/etc/R/Rprofile_site.d/.compiled"
RENVIRON="${BIOME_HEALTH_ROOT}/etc/R/Renviron.site"
RPROFILE_MINIMAL="${BIOME_HEALTH_ROOT}/etc/R/Rprofile_minimal.R"
CORETYPE_PROFILE="${BIOME_HEALTH_ROOT}/etc/profile.d/biome-coretype.sh"
RSESSION_PROFILE="${BIOME_HEALTH_ROOT}/etc/rstudio/rsession-profile"
RSERVER_CONF="${BIOME_HEALTH_ROOT}/etc/rstudio/rserver.conf"
RSTUDIO_SYS_PREFS="${BIOME_HEALTH_ROOT}/etc/rstudio/rstudio-prefs.json"
R_LIBS_LOCAL_ROOT_DEFAULT="${BIOME_HEALTH_ROOT}/var/lib/biome-Rlibs"
RTMP_ROOT="${BIOME_HEALTH_ROOT}/Rtmp"
VARS_CONF="${WORKSPACE_ROOT}/config/setup_nodes.vars.conf"
RSTUDIO_VARS_CONF="${WORKSPACE_ROOT}/config/configure_rstudio.vars.conf"
TEMPLATE_DIR="${WORKSPACE_ROOT}/templates/Rprofile_site.d"

# Login script deployed by 20_configure_rstudio.sh (menu 1/3). Its path is
# defined once in configure_rstudio.vars.conf.
LOGIN_SCRIPT_PATH="/etc/profile.d/00_rstudio_user_logins.sh"
if [[ -r "$RSTUDIO_VARS_CONF" ]]; then
    _lsp="$(grep -m1 -E '^RSTUDIO_PROFILE_SCRIPT_PATH=' "$RSTUDIO_VARS_CONF" | cut -d= -f2- | tr -d '"' || true)"
    if [[ -n "$_lsp" ]]; then LOGIN_SCRIPT_PATH="$_lsp"; fi
fi
LOGIN_SCRIPT="${BIOME_HEALTH_ROOT}${LOGIN_SCRIPT_PATH}"

# =============================================================================
# HELPERS
# =============================================================================

usage() {
    local me
    me="$(basename "$0")"
    cat <<EOF
Usage: ${me} [--user NAME] [--static-only] [--allow-root-probes]
       ${me} --user NAME --fix [--commit [-y]]
       ${me} --user NAME --reset-profile [--commit [-y]]
       ${me} --user NAME --undo-reset STAMP|list [--commit [-y]]

RStudio OSS R-profile health check: dispatcher, fragments, bundle, guards,
BLAS, Renviron.site, and (with --user) everything in that user's startup
files and session state that breaks or slows their RStudio web session.

Options:
  --user NAME           Check NAME's startup files/state (section 7) and run
                        the runtime probes as NAME (root drops privileges via
                        runuser). Non-root may only name themselves.
  --static-only         Read-only tier only. Safe for cron.
  --allow-root-probes   Run the runtime tier as root without --user (creates
                        root-owned /Rtmp/biome_root/). Not recommended.
  --fix                 Print the repair plan for NAME (dry-run).
  --reset-profile       Plan a quarantine of NAME's startup state (dry-run):
                        ~/.local/share/rstudio, ~/.Rprofile, ~/.Renviron,
                        ~/.RData and an unparseable rstudio-prefs.json are
                        MOVED to ~/.biome-profile-quarantine/<STAMP>/.
  --undo-reset STAMP    Plan moving a quarantine back ('list' shows stamps).
  --commit              Actually apply --fix / --reset-profile / --undo-reset,
                        then re-run the checks to verify.
  -y, --yes             Skip the confirmation prompt (needed without a TTY).
  -h, --help            This help

Exit codes: 0 clear | 1 CRIT/FAIL | 2 warnings only | 3 invocation error |
            4 requested change not (fully) applied

Examples:
  sudo bash ${me} --static-only                     # node integrity (cron)
  sudo bash ${me} --user researcher1                # full check as that user
  sudo bash ${me} --user researcher1 --fix          # preview repairs
  sudo bash ${me} --user researcher1 --fix --commit # apply + verify
  sudo bash ${me} --user researcher1 --reset-profile --commit
  sudo bash ${me} --user researcher1 --undo-reset list

Owned elsewhere (reported, not changed here):
  ~/.Renviron R_LIBS_*  → sudo bash scripts/50_setup_nodes.sh (option 4)
                          or scripts/99_check_user_renviron_overrides.sh --fix --commit
EOF
}

die_usage() {
    printf "%bERROR:%b %s\n" "$RED" "$NC" "$1" >&2
    exit 3
}

# is_num VALUE — bare non-negative integer. Guards every numeric test: a
# failed probe yields "" or "?", and `[[ "?" -gt 0 ]]` is a bash syntax error.
is_num() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

report() {
    local severity="$1" check_name="$2" detail="${3:-}" line
    case "$severity" in
        PASS) line="${GREEN}  PASS${NC}  ${check_name}" ;;
        WARN) line="${YELLOW}  WARN${NC}  ${check_name}"; WARNINGS=$((WARNINGS + 1)) ;;
        FAIL) line="${RED}  FAIL${NC}  ${check_name}";    FAILURES=$((FAILURES + 1)) ;;
        CRIT) line="${RED}${BOLD}  CRIT${NC}  ${check_name}"; FAILURES=$((FAILURES + 1)) ;;
        *) printf "INTERNAL: bad severity %q\n" "$severity" >&2; return 1 ;;
    esac
    CHECKS_RUN=$((CHECKS_RUN + 1))
    printf "%s\n" "$line"
    if [[ -n "$detail" ]]; then printf '%s\n' "$detail" | sed 's/^/        /'; fi
    case "$severity" in
        FAIL|CRIT)
            FAILED_CHECKS+=("${severity}  ${check_name}")
            if [[ "$SCOPE" == "user" ]]; then USER_FAILS=$((USER_FAILS + 1)); else SYS_FAILS=$((SYS_FAILS + 1)); fi
            ;;
        WARN)
            if [[ "$SCOPE" == "user" ]]; then USER_WARNS=$((USER_WARNS + 1)); fi
            ;;
    esac
    return 0
}

section() { printf "\n%s\n" "${CYAN}${BOLD}── ${1}${NC}"; }
sub()     { printf "  %s\n" "${BOLD}· ${1}${NC}"; }

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1073741824) printf "%.1f GiB", b / 1073741824;
        else if (b >= 1048576) printf "%.1f MiB", b / 1048576;
        else printf "%d B", b }'
}

# kvof TEXT KEY — value of the first "@@BIOME@@KEY=value" line in TEXT.
# The marker is anchored at line start, so R's echo of the probe source
# (interactive mode) and stray profile output can never match.
kvof() {
    local line
    line="$(printf '%s\n' "$1" | grep -m1 "^@@BIOME@@${2}=" || true)"
    printf '%s' "${line#"@@BIOME@@${2}="}"
}

# renv_last FILE VAR — value of the LAST definition (R applies lines in order,
# so the last one wins), surrounding quotes stripped.
renv_last() {
    local v
    v="$(grep -E "^[[:space:]]*${2}[[:space:]]*=" "$1" 2>/dev/null | tail -n1 | sed -E 's/^[^=]*=[[:space:]]*//' || true)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    printf '%s' "$v"
}
renv_count() { grep -cE "^[[:space:]]*${2}[[:space:]]*=" "$1" 2>/dev/null || true; }

# u_run CMD... — run as the checked user (runuser when we are root). Every
# read of a user's files goes through this: it is the user's own view, and it
# still works on NFS homes exported with root_squash.
AS_USER=()
u_run() {
    if [[ ${#AS_USER[@]} -gt 0 ]]; then "${AS_USER[@]}" "$@"; else "$@"; fi
}
user_stat() { u_run stat -c "$1" -- "$2" 2>/dev/null || true; }
user_is()   { u_run test "$1" "$2" 2>/dev/null; }

# u_bash FUNC ARGS... — run a helper function below as the checked user, in a
# fresh strict-mode bash with a clean environment.
u_bash() {
    local fn="$1"; shift
    u_run env -i "PATH=${PROBE_PATH}" "HOME=${U_HOME_REAL:-/}" "LANG=C.UTF-8" \
        bash -c "set -euo pipefail; $(declare -f "$fn"); $fn \"\$@\"" "$fn" "$@"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

set_mode() {
    if [[ "$MODE" != "check" && "$MODE" != "$1" ]]; then
        die_usage "--fix, --reset-profile and --undo-reset are mutually exclusive"
    fi
    MODE="$1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            if [[ $# -lt 2 || -z "${2:-}" || "${2}" == -* ]]; then die_usage "--user requires a username"; fi
            TARGET_USER="$2"; shift 2 ;;
        --static-only)       STATIC_ONLY=true; shift ;;
        --allow-root-probes) ALLOW_ROOT_PROBES=1; shift ;;
        --fix)               set_mode fix; shift ;;
        --reset-profile)     set_mode reset; shift ;;
        --undo-reset)
            if [[ $# -lt 2 || -z "${2:-}" || "${2}" == -* ]]; then die_usage "--undo-reset requires a STAMP (or 'list')"; fi
            set_mode undo; UNDO_STAMP="$2"; shift 2 ;;
        --commit)            COMMIT=true; shift ;;
        -y|--yes)            ASSUME_YES=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)
            printf "%bERROR:%b Unknown option: %s\n" "$RED" "$NC" "$1" >&2
            usage >&2
            exit 3 ;;
    esac
done

if [[ "$COMMIT" == true && "$MODE" == "check" ]]; then
    die_usage "--commit requires --fix, --reset-profile or --undo-reset"
fi
if [[ "$MODE" != "check" && -z "$TARGET_USER" ]]; then
    die_usage "--fix / --reset-profile / --undo-reset act on one user: add --user NAME"
fi
if [[ "$MODE" == "undo" && "$UNDO_STAMP" != "list" && ! "$UNDO_STAMP" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    die_usage "--undo-reset STAMP must look like 20260923T101500Z (or 'list')"
fi
if ! is_num "$PROBE_TIMEOUT_S"; then die_usage "BIOME_HEALTH_PROBE_TIMEOUT_S must be an integer"; fi

# =============================================================================
# PRE-FLIGHT
# =============================================================================

R_BIN="$(command -v R 2>/dev/null || true)"
if [[ -z "$R_BIN" ]]; then die_usage "R not found on PATH — cannot run profile checks"; fi
JQ_BIN="$(command -v jq 2>/dev/null || true)"
PROBE_PATH="$(dirname "$R_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EUID_NOW="$(id -u)"
ME_NAME="$(id -un)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TODAY="$(date -u +%Y-%m-%d)"

U_NAME=""; U_UID=""; U_GID=""; U_HOME_REAL=""; U_HOME=""
if [[ -n "$TARGET_USER" ]]; then
    _pw="$(getent passwd -- "$TARGET_USER" 2>/dev/null || true)"
    if [[ -z "$_pw" ]]; then die_usage "user ${TARGET_USER} not found via getent passwd"; fi
    IFS=: read -r U_NAME _ U_UID U_GID _ U_HOME_REAL _ <<< "$_pw"
    U_HOME="${BIOME_HEALTH_ROOT}${U_HOME_REAL}"
    if [[ "$EUID_NOW" -ne 0 && "$U_UID" != "$EUID_NOW" ]]; then
        die_usage "--user ${U_NAME} is not you: run with sudo so files are read and probes run as ${U_NAME}"
    fi
fi

# Identity for reading/writing the checked user's files.
USER_ACCESS_NOTE=""
if [[ -n "$U_NAME" && "$EUID_NOW" -eq 0 && "$U_UID" != "0" ]]; then
    if command -v runuser &>/dev/null; then
        AS_USER=(runuser -u "$U_NAME" --)
    else
        USER_ACCESS_NOTE="runuser(1) missing: ${U_NAME}'s files are read as root (NFS root_squash may hide them)"
    fi
fi

# ── Privilege gate for the RUNTIME tier ───────────────────────────────────
PROBE_RUNAS=""; RUNTIME_TIER=true; RUNTIME_SKIP_REASON=""
if [[ "$STATIC_ONLY" == true ]]; then
    RUNTIME_TIER=false; RUNTIME_SKIP_REASON="--static-only requested"
elif [[ "$EUID_NOW" -eq 0 ]]; then
    if [[ -n "$U_NAME" && "$U_UID" != "0" ]]; then
        if command -v runuser &>/dev/null; then
            PROBE_RUNAS="$U_NAME"
        else
            RUNTIME_TIER=false; RUNTIME_SKIP_REASON="runuser(1) not available — cannot drop privileges"
        fi
    elif [[ "$ALLOW_ROOT_PROBES" != "1" ]]; then
        RUNTIME_TIER=false
        RUNTIME_SKIP_REASON="running as root without --user <non-root user> (would create root-owned /Rtmp/biome_root/ and ${R_LIBS_LOCAL_ROOT_DEFAULT}/root/)"
    fi
fi

if [[ -n "$U_NAME" ]]; then
    PROBE_USER="$U_NAME"; PROBE_HOME_REAL="$U_HOME_REAL"
else
    PROBE_USER="$ME_NAME"
    PROBE_HOME_REAL="$(getent passwd -- "$ME_NAME" | cut -d: -f6 || true)"
fi
PROBE_HOME="${BIOME_HEALTH_ROOT}${PROBE_HOME_REAL:-/}"

# R major.minor from `R --version`: parsing the banner loads no profile.
# (Rscript -e … would source the full site profile — as root that creates
# exactly the root-owned /Rtmp/biome_root litter the gate above prevents.)
R_VER_MM="$("$R_BIN" --version 2>/dev/null | awk '/^R version/ {split($3, v, "."); print v[1] "." v[2]; exit}' || true)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rprofile_health.XXXXXX")"
cleanup_work_dir() { rm -rf -- "$WORK_DIR"; }
trap cleanup_work_dir EXIT

# =============================================================================
# R PROBE PROGRAMS
# =============================================================================
# Written to the private (0700) WORK_DIR and fed on stdin by this shell, so the
# probed user never needs read access to them. Every value goes out as an
# anchored "@@BIOME@@KEY=value" line; base:: prefixes keep a user .Rprofile
# that masks cat()/paste() from corrupting the protocol.

write_r_programs() {
    cat > "${WORK_DIR}/scan_static.R" <<'RCODE'
local({
  .m <- function(k, v) base::cat("\n@@BIOME@@", k, "=", base::paste(base::as.character(v), collapse = " "), "\n", sep = "")
  scan1 <- function(f) {
    p <- tryCatch(parse(file = f, keep.source = TRUE), error = function(e) e)
    if (inherits(p, "error"))
      return(list(ok = FALSE, err = gsub("[\r\n]+", " ", conditionMessage(p)), ph = character(0)))
    pd <- utils::getParseData(p)
    # Placeholders only count in CODE tokens: the rendered dispatcher legitimately
    # keeps "%%PLACEHOLDER%%" in a comment that process_template never substitutes.
    toks <- if (is.null(pd)) character(0) else pd$text[pd$terminal & pd$token != "COMMENT"]
    list(ok = TRUE, err = "", ph = unique(unlist(regmatches(toks, gregexpr("%%[A-Z0-9_]+%%", toks)))))
  }
  d <- Sys.getenv("BIOME_HC_DISPATCHER")
  if (nzchar(d) && file.exists(d)) {
    r <- scan1(d)
    .m("DISP_PARSE", if (r$ok) "OK" else "FAIL")
    .m("DISP_ERR", r$err)
    .m("DISP_PH", r$ph)
  }
  fd <- Sys.getenv("BIOME_HC_FRAGDIR")
  if (nzchar(fd) && dir.exists(fd)) {
    fs <- sort(list.files(fd, pattern = "^[0-9]{2}_.*[.]R$", full.names = TRUE))
    bad <- character(0); ph <- character(0)
    for (f in fs) {
      r <- scan1(f)
      if (!r$ok) bad <- c(bad, sprintf("%s: %s", basename(f), r$err))
      if (length(r$ph)) ph <- c(ph, sprintf("%s:%s", basename(f), paste(r$ph, collapse = ",")))
    }
    .m("FRAG_PARSED", length(fs))
    .m("FRAG_BAD", length(bad))
    .m("FRAG_BAD_TEXT", paste(bad, collapse = "; "))
    .m("FRAG_PH", paste(ph, collapse = " "))
  }
  .m("SCAN_DONE", TRUE)
})
RCODE

    # Shared tail: report + delete this R process's own dispatcher error logs.
    local errlogs
    errlogs='  for (kind in c("boot", "frag")) {
    lf <- file.path("/tmp", sprintf("biome_%s_errors_%d.log", kind, Sys.getpid()))
    l <- if (file.exists(lf)) readLines(lf, warn = FALSE) else character(0)
    l <- l[nzchar(trimws(l))]
    K <- toupper(kind)
    .m(paste0(K, "_ERRORS"), length(l))
    if (length(l)) .m(paste0(K, "_ERROR_TEXT"),
        paste(utils::head(unique(sub("^\\[[0-9: -]+\\] *", "", l)), 3L), collapse = " | "))
    if (file.exists(lf)) unlink(lf)
  }'

    cat > "${WORK_DIR}/sys_probe.R" <<RCODE
local({
  .m <- function(k, v) base::cat("\n@@BIOME@@", k, "=", base::paste(base::as.character(v), collapse = " "), "\n", sep = "")
  # Deregister deferred callbacks (Smart Cleanup, adaptive resources): the
  # probe must not trigger /Rtmp cleanups when it exits.
  for (n in getTaskCallbackNames()) try(removeTaskCallback(n), silent = TRUE)
  tryCatch({
    .m("STARTUP_MS", round(proc.time()[["elapsed"]] * 1000))
    # biome.profile.loaded is set BEFORE the MAIN block runs: it only proves
    # the dispatcher was entered. MAIN completion = .biome_env\$API_VERSION.
    .m("DISPATCHER_ENTERED", isTRUE(getOption("biome.profile.loaded")))
    be <- if (exists(".biome_env", envir = .GlobalEnv, inherits = FALSE)) get(".biome_env", envir = .GlobalEnv) else NULL
    ok <- is.environment(be)
    .m("MAIN_VERSION", if (ok && !is.null(be\$VERSION)) be\$VERSION else "unset")
    .m("MAIN_API", if (ok && !is.null(be\$API_VERSION)) be\$API_VERSION else "unset")
    .m("MAIN_TIMERS", if (ok) tryCatch(length(be\$shared_env\$timers), error = function(e) 0L) else 0L)
    fl <- if (ok) tryCatch(be\$shared_env\$diag_logs\$FragLoader\$msg, error = function(e) NULL) else NULL
    .m("FRAG_LOADER", if (is.null(fl)) "unknown" else fl)
    g <- c(solve = "base", dist = "stats", outer = "base", expand.grid = "base")
    for (x in names(g)) {
      f <- tryCatch(get(x, envir = asNamespace(g[[x]])), error = function(e) NULL)
      .m(paste0("GUARD_", gsub(".", "_", x, fixed = TRUE)), isTRUE(attr(f, "biome_guard")))
    }
    if ("tools:biome_calc" %in% search()) {
      av <- ls(as.environment("tools:biome_calc"))
      .m("TOOLS_COUNT", length(av))
      for (t in c("biome_make_cluster", "biome_future_plan", "status")) .m(paste0("TOOL_", t), t %in% av)
    } else .m("TOOLS_COUNT", 0L)
    si <- tryCatch(sessionInfo(), error = function(e) NULL)
    bp <- tryCatch(if (is.null(si) || is.null(si\$BLAS)) "" else si\$BLAS, error = function(e) "")
    .m("BLAS_PATH", if (nzchar(bp)) bp else "unknown")
    .m("BLAS_VARIANT", if (grepl("pthread", bp, fixed = TRUE)) "pthread" else if (grepl("serial", bp, fixed = TRUE)) "serial" else "unknown")
    for (v in c("OPENBLAS_CORETYPE", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "TMPDIR")) .m(v, Sys.getenv(v, "unset"))
    .m("TEMPDIR", tempdir())
  }, error = function(e) .m("PROBE_ERROR", gsub("[\r\n]+", " ", conditionMessage(e))))
${errlogs}
  .m("PROBE_DONE", TRUE)
})
RCODE

    # Interactive session probe. Three leading blank lines are sacrificial: a
    # readline()/menu() in the user's startup code consumes them, not the probe.
    cat > "${WORK_DIR}/session_probe.R" <<RCODE



local({
  .m <- function(k, v) base::cat("\n@@BIOME@@", k, "=", base::paste(base::as.character(v), collapse = " "), "\n", sep = "")
  for (n in getTaskCallbackNames()) try(removeTaskCallback(n), silent = TRUE)
  tryCatch({
    .m("STARTUP_MS", round(proc.time()[["elapsed"]] * 1000))
    .m("INTERACTIVE", interactive())
    be <- if (exists(".biome_env", envir = .GlobalEnv, inherits = FALSE)) get(".biome_env", envir = .GlobalEnv) else NULL
    .m("MAIN_API", if (is.environment(be) && !is.null(be\$API_VERSION)) be\$API_VERSION else "unset")
    g <- c(solve = "base", dist = "stats", outer = "base", expand.grid = "base")
    n <- 0L
    for (x in names(g)) {
      f <- tryCatch(get(x, envir = asNamespace(g[[x]])), error = function(e) NULL)
      if (isTRUE(attr(f, "biome_guard"))) n <- n + 1L
    }
    .m("GUARDS", n)
    .m("LIBPATH1", .libPaths()[1L])
    .m("TEMPDIR", tempdir())
    for (v in c("TMPDIR", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
                "BIOME_DISABLE_FRAGMENTS", "BIOME_WORKER_MODE")) .m(v, Sys.getenv(v, "unset"))
    mc <- getOption("mc.cores")
    .m("MC_CORES", if (is.null(mc)) "unset" else mc)
    d <- getOption("device")
    dev <- if (is.null(d)) "unset" else if (is.character(d)) d[1L] else if (is.function(d)) {
      en <- tryCatch(environmentName(environment(d)), error = function(e) "")
      if (!length(en) || !nzchar(en)) en <- "anonymous"
      paste0("function:", en)
    } else class(d)[1L]
    .m("DEVICE", dev)
  }, error = function(e) .m("PROBE_ERROR", gsub("[\r\n]+", " ", conditionMessage(e))))
${errlogs}
  .m("PROBE_DONE", TRUE)
})
q(save = "no", runLast = FALSE)
RCODE

    cat > "${WORK_DIR}/worker_probe.R" <<'RCODE'
local({
  .m <- function(k, v) base::cat("\n@@BIOME@@", k, "=", base::paste(base::as.character(v), collapse = " "), "\n", sep = "")
  .m("WORKER_ALIVE", TRUE)
  .m("MAIN_RAN", exists(".biome_env", envir = .GlobalEnv, inherits = FALSE))
  lf <- file.path("/tmp", sprintf("biome_boot_errors_%d.log", Sys.getpid()))
  if (file.exists(lf)) {
    l <- readLines(lf, warn = FALSE)
    .m("BOOT_ERRORS", length(l[nzchar(trimws(l))]))
    unlink(lf)
  } else .m("BOOT_ERRORS", 0L)
  .m("PROBE_DONE", TRUE)
})
RCODE

    cat > "${WORK_DIR}/rprof_scan.R" <<'RCODE'
local({
  .m <- function(k, v) base::cat("\n@@BIOME@@", k, "=", base::paste(base::as.character(v), collapse = " "), "\n", sep = "")
  p <- tryCatch(parse(file = Sys.getenv("BIOME_HC_FILE"), keep.source = TRUE), error = function(e) e)
  if (inherits(p, "error")) {
    .m("PARSE", "FAIL")
    .m("PARSE_ERR", gsub("[\r\n]+", " ", conditionMessage(p)))
  } else {
    .m("PARSE", "OK")
    sr <- attr(p, "srcref")
    is_opts <- function(fn) identical(fn, as.name("options")) ||
      (is.call(fn) && length(fn) == 3L && identical(fn[[1L]], as.name("::")) &&
       identical(fn[[3L]], as.name("options")))
    ranges <- character(0)
    for (i in seq_along(p)) {
      e <- p[[i]]
      if (is.call(e) && is_opts(e[[1L]]) && "device" %in% names(as.list(e)))
        ranges <- c(ranges, sprintf("%d-%d", sr[[i]][1L], sr[[i]][3L]))
    }
    # Top-level options(device = ...) statements: whole-statement line ranges
    # (the only form --fix comments out automatically).
    .m("DEVICE_TOPLEVEL", paste(ranges, collapse = " "))
  }
  .m("SCAN_DONE", TRUE)
})
RCODE
}

# ── Probe runner ──────────────────────────────────────────────────────────
# MODE  system        full system profile, NO user startup files, non-interactive
#       worker        system profile via the PSOCK-worker fast path
#       session_base  like system, but interactive (what the RStudio console sees)
#       session_user  interactive, WITH the user's ~/.Renviron + ~/.Rprofile, cwd=home
# All modes: env -i (the operator's exported vars — e.g. a BIOME_DISABLE_FRAGMENTS
# left over from bisecting — cannot leak in), R_PROFILE = the deployed site file,
# --no-restore (~/.RData is assessed statically, never loaded).
build_probe_env() {
    local mode="$1" cwd="/"
    if [[ "$mode" == "session_user" ]]; then cwd="$PROBE_HOME"; fi
    PROBE_ENV=(env -i -C "$cwd" "PATH=${PROBE_PATH}" "HOME=${PROBE_HOME}"
               "USER=${PROBE_USER}" "LOGNAME=${PROBE_USER}" "SHELL=/bin/bash"
               "LANG=C.UTF-8" "LANGUAGE=en" "TERM=dumb" "R_PROFILE=${RPROFILE}")
    # Fixture mode: R cannot find the fixture's site Renviron by itself.
    if [[ -n "$BIOME_HEALTH_ROOT" ]]; then PROBE_ENV+=("R_ENVIRON=${RENVIRON}"); fi
    # Empty R_ENVIRON_USER = read no user environ file (neither ./.Renviron
    # nor ~/.Renviron): system probes must not inherit the user's settings.
    if [[ "$mode" != "session_user" ]]; then PROBE_ENV+=("R_ENVIRON_USER="); fi
    if [[ "$mode" == "worker" ]]; then PROBE_ENV+=("BIOME_WORKER_MODE=1" "BIOME_WORKER_THREADS=1"); fi
    return 0
}

R_OUT=""; R_ERR=""; R_RC=0
run_r_probe() {
    local mode="$1" code="$2"
    local -a rflags=(--no-echo --no-save --no-restore)
    case "$mode" in
        system|worker) rflags+=(--no-init-file) ;;
        session_base)  rflags+=(--interactive --no-init-file) ;;
        session_user)  rflags+=(--interactive) ;;
    esac
    build_probe_env "$mode"
    local -a cmd=("${PROBE_ENV[@]}" timeout -k 5 "$PROBE_TIMEOUT_S" "$R_BIN" "${rflags[@]}")
    if [[ -n "$PROBE_RUNAS" ]]; then cmd=(runuser -u "$PROBE_RUNAS" -- "${cmd[@]}"); fi
    local errf="${WORK_DIR}/probe.err"
    if R_OUT="$("${cmd[@]}" < "$code" 2>"$errf")"; then R_RC=0; else R_RC=$?; fi
    R_ERR="$(head -c 8192 -- "$errf" 2>/dev/null || true)"
    return 0
}

# probe_outcome TEXT RC → ok | timeout | crashed | incomplete
probe_outcome() {
    if [[ "$2" -eq 124 || "$2" -eq 137 ]]; then
        printf 'timeout'
    elif [[ -z "$(kvof "$1" PROBE_DONE)" ]]; then
        if [[ "$2" -ne 0 ]]; then printf 'crashed'; else printf 'incomplete'; fi
    else
        printf 'ok'
    fi
}

one_line() { printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-"${2:-220}"; }

SYS_OUT=""; SYS_ERR=""; SYS_RC=0; SYS_STATE="skipped"
sk() { kvof "$SYS_OUT" "$1"; }
run_system_probe() {
    if [[ "$RUNTIME_TIER" != true || ! -f "$RPROFILE" ]]; then return 0; fi
    run_r_probe system "${WORK_DIR}/sys_probe.R"
    SYS_OUT="$R_OUT"; SYS_ERR="$R_ERR"; SYS_RC="$R_RC"
    SYS_STATE="$(probe_outcome "$SYS_OUT" "$SYS_RC")"
    return 0
}

# runtime_gate LABEL — WARN + return 1 when the runtime tier cannot report.
runtime_gate() {
    if [[ "$RUNTIME_TIER" != true ]]; then
        report WARN "$1 SKIPPED" "$RUNTIME_SKIP_REASON"; return 1
    elif [[ ! -f "$RPROFILE" ]]; then
        report WARN "$1 SKIPPED" "no Rprofile.site to load"; return 1
    elif [[ "$SYS_STATE" != "ok" ]]; then
        report WARN "$1 not evaluated" "the system profile probe did not complete (see section 4)"; return 1
    fi
    return 0
}

# =============================================================================
# CHANGE ENGINE (--fix --commit / --reset-profile / --undo-reset)
# =============================================================================
# Contract shared with 99_check_user_renviron_overrides.sh: nothing changes
# without --commit, every edited file gets <file>.bak.<UTC stamp> first, lines
# are commented out (never deleted) with "# [biome-cleanup DATE] disabled (was:"
# and writes into the user's home happen AS THE USER.

FIX_FAILED=0

confirm_or_exit() {
    if [[ "$ASSUME_YES" == true ]]; then return 0; fi
    if [[ ! -t 0 ]]; then
        printf "%sREFUSED:%s no terminal to confirm on — re-run with -y to apply non-interactively\n" "$RED" "$NC" >&2
        exit 3
    fi
    local ans=""
    read -r -p "$1 [y/N] " ans || true
    if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
        printf "Aborted — nothing was changed.\n"
        exit 0
    fi
    return 0
}

require_runuser_for_changes() {
    if [[ "$EUID_NOW" -eq 0 && "$U_UID" != "0" && ${#AS_USER[@]} -eq 0 ]]; then
        die_usage "runuser(1) is required to change ${U_NAME}'s files as ${U_NAME} (refusing to write them as root)"
    fi
    return 0
}

# run_fn user|self FUNC ARGS... — execute FUNC in a fresh strict-mode bash,
# either as the checked user or as the invoking identity.
run_fn() {
    local who="$1" fn="$2"; shift 2
    if [[ "$who" == "user" ]]; then
        u_bash "$fn" "$@"
    else
        env -i "PATH=${PROBE_PATH}" "LANG=C.UTF-8" \
            bash -c "set -euo pipefail; $(declare -f "$fn"); $fn \"\$@\"" "$fn" "$@"
    fi
}

_fx_comment_lines() {
    local f="$1" lines="$2" stamp="$3" today="$4" bak tmp
    bak="${f}.bak.${stamp}"
    cp -p -- "$f" "$bak"
    tmp="$(mktemp "${f}.tmp.XXXXXX")"
    trap 'rm -f -- "$tmp"' EXIT
    awk -v marker="# [biome-cleanup ${today}] disabled (was:" -v lines="$lines" '
        BEGIN { n = split(lines, a, " "); for (i = 1; i <= n; i++) t[a[i]] = 1 }
        (FNR in t) { printf "%s %s)\n# %s\n", marker, $0, $0; next }
        { print }' "$f" > "$tmp"
    chmod --reference="$f" -- "$tmp"
    mv -f -- "$tmp" "$f"
    trap - EXIT
    printf '%s' "$bak"
}

_fx_prefs_workspace() {
    local f="$1" stamp="$2" d tmp
    d="$(dirname -- "$f")"
    if [[ -e "$f" ]]; then
        jq -e 'type == "object"' "$f" > /dev/null
        cp -p -- "$f" "${f}.bak.${stamp}"
        tmp="$(mktemp "${f}.tmp.XXXXXX")"
        trap 'rm -f -- "$tmp"' EXIT
        jq '.load_workspace = false | .save_workspace = "never"' "$f" > "$tmp"
        chmod --reference="$f" -- "$tmp"
        mv -f -- "$tmp" "$f"
        trap - EXIT
        printf '%s' "${f}.bak.${stamp}"
    else
        mkdir -p -- "$d"
        chmod 700 -- "$d"
        tmp="$(mktemp "${d}/.rstudio-prefs.tmp.XXXXXX")"
        trap 'rm -f -- "$tmp"' EXIT
        jq -n '{load_workspace: false, save_workspace: "never"}' > "$tmp"
        chmod 600 -- "$tmp"
        mv -f -- "$tmp" "$f"
        trap - EXIT
        printf '(new file, nothing to back up)'
    fi
}

_fx_chown()      { chown "$2:$3" -- "$1"; }
_fx_chmod_read() { chmod u+r -- "$1"; }
_fx_rlib_heal()  { mkdir -p -- "$2"; chmod 0755 -- "$1" "$2"; chown "$3:$4" -- "$1" "$2"; }
_fx_rtmp_heal()  { chown -R "$2:$3" -- "$1"; chmod 0700 -- "$1"; }

rprof_parses() {
    local out
    out="$(u_run env -i "PATH=${PROBE_PATH}" "HOME=${U_HOME_REAL}" "LANG=C.UTF-8" "LANGUAGE=en" \
        "BIOME_HC_FILE=$1" timeout -k 5 "$PROBE_TIMEOUT_S" "$R_BIN" --vanilla --no-echo \
        < "${WORK_DIR}/rprof_scan.R" 2>&1 || true)"
    if [[ "$(kvof "$out" PARSE)" == "OK" ]]; then return 0; fi
    printf '%s' "$(one_line "$(kvof "$out" PARSE_ERR)" 100)"
    return 1
}

apply_one() {
    local i="$1" a="${FIX_A[$1]}" b="${FIX_B[$1]}" bak perr
    case "${FIX_KIND[$i]}" in
        chown)      run_fn self _fx_chown "$a" "$U_UID" "$U_GID" ;;
        chmod_read) run_fn user _fx_chmod_read "$a" ;;
        rlib_heal)  run_fn self _fx_rlib_heal "$a" "$b" "$U_UID" "$U_GID" ;;
        rtmp_heal)  run_fn self _fx_rtmp_heal "$a" "$U_UID" "$U_GID" ;;
        comment_renviron)
            bak="$(run_fn user _fx_comment_lines "$a" "$b" "$STAMP" "$TODAY")" || return 1
            printf 'backup: %s' "$bak" ;;
        comment_rprofile)
            bak="$(run_fn user _fx_comment_lines "$a" "$b" "$STAMP" "$TODAY")" || return 1
            if ! perr="$(rprof_parses "$a")"; then
                u_run cp -p -- "$bak" "$a" || true
                printf 'REVERTED (backup restored): commenting out lines %s would break parsing (%s) — edit by hand' "$b" "$perr"
                return 1
            fi
            printf 'backup: %s (file still parses)' "$bak" ;;
        prefs_workspace)
            bak="$(run_fn user _fx_prefs_workspace "$a" "$STAMP")" || return 1
            printf 'backup: %s' "$bak" ;;
        *) printf 'unknown fix kind %s' "${FIX_KIND[$i]}"; return 1 ;;
    esac
}

apply_fix_plan() {
    local kind i out
    section "Applying ${#FIX_KIND[@]} change(s) for ${U_NAME}"
    for kind in chown chmod_read rlib_heal rtmp_heal comment_renviron comment_rprofile prefs_workspace; do
        for i in "${!FIX_KIND[@]}"; do
            if [[ "${FIX_KIND[$i]}" != "$kind" ]]; then continue; fi
            if [[ "${FIX_ROOT[$i]}" == "yes" && "$EUID_NOW" -ne 0 ]]; then
                printf "  %s✗%s %s\n      needs root — re-run with sudo\n" "$RED" "$NC" "${FIX_DESC[$i]}"
                FIX_FAILED=$((FIX_FAILED + 1))
                continue
            fi
            if out="$(apply_one "$i" 2>&1)"; then
                printf "  %s✓%s %s\n" "$GREEN" "$NC" "${FIX_DESC[$i]}"
            else
                printf "  %s✗%s %s\n" "$RED" "$NC" "${FIX_DESC[$i]}"
                FIX_FAILED=$((FIX_FAILED + 1))
            fi
            if [[ -n "$out" ]]; then printf "      %s\n" "$(one_line "$out" 300)"; fi
        done
    done
    printf "  %s must restart R (Session → Restart R) for the changes to apply.\n" "$U_NAME"
}

run_verification() {
    printf "\n%s\n" "${BOLD}════ VERIFICATION RUN (after the changes above) ════${NC}"
    local -a vargs=(--user "$U_NAME")
    if [[ "$STATIC_ONLY" == true ]]; then vargs+=(--static-only); fi
    if [[ "$ALLOW_ROOT_PROBES" == "1" ]]; then vargs+=(--allow-root-probes); fi
    bash "$SELF" "${vargs[@]}"
}

_rs_quarantine() {
    local home="$1" q="$2" operator="$3" stamp="$4" selfp="$5" user="$6" rel
    shift 6
    umask 077
    mkdir -p -- "$(dirname -- "$q")"
    mkdir -- "$q"
    {
        printf '# BIOME-CALC R profile quarantine %s\n' "$stamp"
        printf '# created %s on %s by %s for %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$operator" "$user"
        printf '# undo: sudo bash %s --user %s --undo-reset %s --commit\n' "$selfp" "$user" "$stamp"
    } > "${q}/MANIFEST.txt"
    for rel in "$@"; do
        mkdir -p -- "${q}/$(dirname -- "$rel")"
        mv -- "${home}/${rel}" "${q}/${rel}"
        printf 'moved\t%s\n' "$rel" >> "${q}/MANIFEST.txt"
    done
}

_rs_restore() {
    local home="$1" q="$2" rel
    shift 2
    for rel in "$@"; do
        if [[ -e "${home}/${rel}" || -L "${home}/${rel}" ]]; then printf 'conflict: ~/%s exists\n' "$rel" >&2; exit 1; fi
    done
    for rel in "$@"; do
        mkdir -p -- "${home}/$(dirname -- "$rel")"
        mv -- "${q}/${rel}" "${home}/${rel}"
        printf 'restored\t%s\t%s\n' "$rel" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${q}/MANIFEST.txt"
    done
}

user_du() { u_run timeout 20 du -sh --apparent-size -- "$1" 2>/dev/null | cut -f1 || true; }

running_rsessions() { pgrep -u "$U_UID" -x rsession 2>/dev/null | tr '\n' ' ' || true; }

block_on_rsession() {
    local pids="$1"
    printf "  %sBLOCKED%s: rsession running for %s (pid %s) — stop it first:\n" "$RED" "$NC" "$U_NAME" "${pids% }"
    printf "      sudo rstudio-server suspend-session <pid>   (or force-suspend-session <pid>, or kill <pid>)\n"
}

do_reset() {
    local qdir="${U_HOME}/.biome-profile-quarantine/${STAMP}" rel pids rpids
    local -a items=()
    section "Reset R profile of ${U_NAME} (quarantine, reversible)"
    if ! user_is -d "$U_HOME" || ! user_is -w "$U_HOME"; then
        printf "  %sERROR%s: %s's home %s is missing or not writable — nothing can be moved\n" "$RED" "$NC" "$U_NAME" "$U_HOME"
        return 4
    fi
    for rel in ".local/share/rstudio" ".Rprofile" ".Renviron" ".RData"; do
        if user_is -e "${U_HOME}/${rel}" || user_is -L "${U_HOME}/${rel}"; then items+=("$rel"); fi
    done
    if user_is -f "${U_HOME}/.config/rstudio/rstudio-prefs.json" && [[ -n "$JQ_BIN" ]] \
       && ! u_run "$JQ_BIN" -e 'type == "object"' "${U_HOME}/.config/rstudio/rstudio-prefs.json" > /dev/null 2>&1; then
        items+=(".config/rstudio/rstudio-prefs.json")
    fi
    if [[ ${#items[@]} -eq 0 ]]; then
        printf "  nothing to quarantine — no R/RStudio startup state in %s\n" "$U_HOME"
        return 0
    fi
    printf "  Will MOVE (never delete) into %s:\n" "$qdir"
    for rel in "${items[@]}"; do printf "    ~/%-40s %s\n" "$rel" "$(user_du "${U_HOME}/${rel}")"; done
    printf "  Kept: valid RStudio preferences, R package libraries, projects and data.\n"
    printf "  Effect: the next login starts from the system profile with a fresh RStudio session\n"
    printf "  (open tabs and unsaved editor buffers stay inside the quarantine copy).\n"
    pids="$(running_rsessions)"
    if [[ -n "${pids// /}" ]]; then block_on_rsession "$pids"; fi
    rpids="$(pgrep -u "$U_UID" -x R 2>/dev/null | tr '\n' ' ' || true)"
    if [[ -n "${rpids// /}" ]]; then
        printf "  %sNOTE%s: R process(es) running for %s (pid %s) — one quitting with save=yes writes a new ~/.RData\n" "$YELLOW" "$NC" "$U_NAME" "${rpids% }"
    fi
    if [[ "$COMMIT" != true ]]; then
        printf "\n  %sDRY-RUN%s — nothing was moved. Apply: sudo bash %s --user %s --reset-profile --commit\n" "$YELLOW" "$NC" "$SELF" "$U_NAME"
        return 0
    fi
    if [[ -n "${pids// /}" ]]; then return 4; fi
    confirm_or_exit "Move ${#items[@]} item(s) of ${U_NAME}'s profile into quarantine?"
    if ! run_fn user _rs_quarantine "$U_HOME" "$qdir" "${SUDO_USER:-$ME_NAME}" "$STAMP" "$SELF" "$U_NAME" "${items[@]}"; then
        printf "  %s✗%s quarantine incomplete — already moved (see %s/MANIFEST.txt):\n" "$RED" "$NC" "$qdir"
        u_run awk -F'\t' '$1 == "moved" { print "      ~/" $2 }' "${qdir}/MANIFEST.txt" 2>/dev/null || true
        return 4
    fi
    printf "  %s✓%s quarantined %d item(s) → %s\n" "$GREEN" "$NC" "${#items[@]}" "$qdir"
    printf "  Undo: sudo bash %s --user %s --undo-reset %s --commit\n" "$SELF" "$U_NAME" "$STAMP"
    return 0
}

# shellcheck disable=SC2088  # "~/..." here is operator-facing display text, never a path
do_undo() {
    local qroot="${U_HOME}/.biome-profile-quarantine" q rel pids s
    local -a items=() conflicts=()
    section "Undo profile reset for ${U_NAME}"
    if [[ "$UNDO_STAMP" == "list" ]]; then
        if ! user_is -d "$qroot"; then printf "  no quarantines in %s\n" "$qroot"; return 0; fi
        while IFS= read -r s; do
            if [[ -z "$s" ]]; then continue; fi
            printf "  %s  %s%s\n" "$s" \
                "$(u_run awk -F'\t' '$1 == "moved" { printf "~/%s ", $2 }' "${qroot}/${s}/MANIFEST.txt" 2>/dev/null || true)" \
                "$(u_run grep -q '^restored' "${qroot}/${s}/MANIFEST.txt" 2>/dev/null && printf '(restored)' || printf '')"
        done < <(u_run find "$qroot" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort || true)
        return 0
    fi
    q="${qroot}/${UNDO_STAMP}"
    if ! user_is -f "${q}/MANIFEST.txt"; then
        printf "  %sERROR%s: no quarantine %s for %s — available: %s\n" "$RED" "$NC" "$UNDO_STAMP" "$U_NAME" \
            "$(u_run find "$qroot" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null || true)"
        return 3
    fi
    if u_run grep -q '^restored' "${q}/MANIFEST.txt" 2>/dev/null; then
        printf "  %sERROR%s: quarantine %s was already restored\n" "$RED" "$NC" "$UNDO_STAMP"
        return 4
    fi
    while IFS= read -r rel; do
        if [[ -n "$rel" ]]; then items+=("$rel"); fi
    done < <(u_run awk -F'\t' '$1 == "moved" { print $2 }' "${q}/MANIFEST.txt" 2>/dev/null || true)
    if [[ ${#items[@]} -eq 0 ]]; then printf "  quarantine %s lists no moved items\n" "$UNDO_STAMP"; return 0; fi
    printf "  Will MOVE back from %s:\n" "$q"
    for rel in "${items[@]}"; do
        printf "    ~/%s\n" "$rel"
        if user_is -e "${U_HOME}/${rel}" || user_is -L "${U_HOME}/${rel}"; then conflicts+=("$rel"); fi
    done
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        printf "  %sBLOCKED%s: these exist again (recreated since the reset): %s\n" "$RED" "$NC" "$(printf '~/%s ' "${conflicts[@]}")"
        printf "      move them aside first, e.g.: mv ~/%s ~/%s.new\n" "${conflicts[0]}" "${conflicts[0]}"
    fi
    pids="$(running_rsessions)"
    if [[ -n "${pids// /}" ]]; then block_on_rsession "$pids"; fi
    if [[ "$COMMIT" != true ]]; then
        printf "\n  %sDRY-RUN%s — nothing was moved. Apply: sudo bash %s --user %s --undo-reset %s --commit\n" "$YELLOW" "$NC" "$SELF" "$U_NAME" "$UNDO_STAMP"
        return 0
    fi
    if [[ ${#conflicts[@]} -gt 0 || -n "${pids// /}" ]]; then return 4; fi
    confirm_or_exit "Move ${#items[@]} item(s) back into ${U_NAME}'s home?"
    if ! run_fn user _rs_restore "$U_HOME" "$q" "${items[@]}"; then
        printf "  %s✗%s restore failed — see %s/MANIFEST.txt for what was restored\n" "$RED" "$NC" "$q"
        return 4
    fi
    printf "  %s✓%s restored %d item(s) from %s\n" "$GREEN" "$NC" "${#items[@]}" "$q"
    return 0
}

write_r_programs

printf "%s\n" "${BOLD}Rprofile health check v2.0${NC}"
printf "  host=%s  uid=%s  R=%s  mode=%s%s\n" "$(hostname)" "$EUID_NOW" "${R_VER_MM:-unknown}" \
    "$MODE" "$( [[ "$COMMIT" == true ]] && printf ' (COMMIT)' || printf '' )"
if [[ -n "$BIOME_HEALTH_ROOT" ]]; then
    printf "  %sFIXTURE MODE%s BIOME_HEALTH_ROOT=%s\n" "$YELLOW" "$NC" "$BIOME_HEALTH_ROOT"
fi
if [[ -n "$U_NAME" ]]; then
    printf "  user=%s uid=%s home=%s%s\n" "$U_NAME" "$U_UID" "$U_HOME_REAL" \
        "$( [[ ${#AS_USER[@]} -gt 0 ]] && printf ' (files read as the user)' || printf '' )"
fi
if [[ -n "$USER_ACCESS_NOTE" ]]; then printf "  %sNOTE%s %s\n" "$YELLOW" "$NC" "$USER_ACCESS_NOTE"; fi

if [[ "$MODE" == "reset" || "$MODE" == "undo" ]]; then
    if [[ "$COMMIT" == true ]]; then require_runuser_for_changes; fi
    change_rc=0
    if [[ "$MODE" == "reset" ]]; then do_reset || change_rc=$?; else do_undo || change_rc=$?; fi
    if [[ "$change_rc" -ne 0 ]]; then exit "$change_rc"; fi
    if [[ "$COMMIT" == true && "$UNDO_STAMP" != "list" ]]; then
        vrc=0
        run_verification || vrc=$?
        exit "$vrc"
    fi
    exit 0
fi

if [[ "$RUNTIME_TIER" == true ]]; then
    printf "  runtime tier: ON (probing as %s)\n" "$PROBE_USER"
else
    printf "  runtime tier: %sOFF%s — %s\n" "$YELLOW" "$NC" "$RUNTIME_SKIP_REASON"
fi

# Static parse of dispatcher + fragments: one `R --vanilla` (no profile, no litter).
STATIC_OUT="$(env -i "PATH=${PROBE_PATH}" "HOME=/" "LANG=C.UTF-8" "LANGUAGE=en" \
    "BIOME_HC_DISPATCHER=${RPROFILE}" "BIOME_HC_FRAGDIR=${RPROFILE_FRAG_DIR}" \
    timeout -k 5 "$PROBE_TIMEOUT_S" "$R_BIN" --vanilla --no-echo \
    < "${WORK_DIR}/scan_static.R" 2>&1 || true)"

# =============================================================================
# 1. DISPATCHER DEPLOYMENT
# =============================================================================

section "1. Dispatcher Deployment"

if [[ -f "$RPROFILE" ]]; then
    rp_size="$(stat -c '%s' "$RPROFILE" 2>/dev/null || echo "?")"
    rp_mtime="$(stat -c '%y' "$RPROFILE" 2>/dev/null | cut -d. -f1 || echo "?")"
    report PASS "Rprofile.site present" "${rp_size} bytes, modified ${rp_mtime}"

    # 1b/1c. Placeholders (code tokens only) + syntax, from the static scan.
    case "$(kvof "$STATIC_OUT" DISP_PARSE)" in
        OK)
            disp_ph="$(kvof "$STATIC_OUT" DISP_PH)"
            if [[ -n "$disp_ph" ]]; then
                report CRIT "Unsubstituted placeholders in dispatcher code: ${disp_ph}" \
                    "process_template was not given these keys — FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
            else
                report PASS "No unsubstituted %%PLACEHOLDERS%% in code" \
                    "(%%…%% inside comments is expected: process_template only substitutes the keys it is passed)"
            fi
            report PASS "R syntax valid (parse OK)"
            ;;
        FAIL)
            disp_ph="$(grep -vE '^[[:space:]]*#' "$RPROFILE" | grep -oE '%%[A-Z0-9_]+%%' | sort -u | tr '\n' ' ' || true)"
            if [[ -n "$disp_ph" ]]; then
                report CRIT "Unsubstituted placeholders in dispatcher code: ${disp_ph}" \
                    "FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
            fi
            report CRIT "R syntax INVALID" \
                "$(one_line "$(kvof "$STATIC_OUT" DISP_ERR)" 160) — FIX: sudo cp ${RPROFILE}.bak ${RPROFILE} (last good copy from 50_setup_nodes.sh) or redeploy (option 3)"
            ;;
        *)
            report CRIT "Static R parse of the dispatcher could not run" "$(one_line "$STATIC_OUT")"
            ;;
    esac

    # 1d. Version detection + config comparison (grep -m1: no SIGPIPE under pipefail).
    deployed_ver="$(grep -m1 -oP 'VERSION\s*<-\s*"\K[0-9.]+' "$RPROFILE" 2>/dev/null || true)"
    if [[ -z "$deployed_ver" ]]; then
        deployed_ver="$(grep -m1 -oE 'v[0-9]+\.[0-9]+' "$RPROFILE" 2>/dev/null | sed 's/^v//' || true)"
    fi
    expected_ver=""
    if [[ -f "$VARS_CONF" ]]; then
        expected_ver="$(grep -m1 -E '^RPROFILE_VERSION=' "$VARS_CONF" | cut -d= -f2 | tr -d "\"'" || true)"
    fi
    if [[ -n "$deployed_ver" && -n "$expected_ver" ]]; then
        if [[ "$deployed_ver" == "$expected_ver" ]]; then
            report PASS "Version match: deployed=${deployed_ver}, config=${expected_ver}"
        else
            report FAIL "Version MISMATCH: deployed=${deployed_ver}, config=${expected_ver}" \
                "FIX: sudo bash scripts/50_setup_nodes.sh (option 3) — or update this checkout if it is older than the deploy"
        fi
    elif [[ -n "$deployed_ver" ]]; then
        report WARN "Deployed version: ${deployed_ver} (repo config not readable: ${VARS_CONF})"
    else
        report WARN "Cannot detect deployed version"
    fi

    # 1e. Version age.
    if [[ -n "$deployed_ver" ]]; then
        case "${deployed_ver%%.*}" in
            9|10) report CRIT "Version ${deployed_ver} — NFS races + top-level return() bug" "FIX: upgrade to v12.x (option 3)" ;;
            11)   report WARN "Version ${deployed_ver} — functional but missing v12.x features" "bundle, fork guard, install block" ;;
            12)   report PASS "Version ${deployed_ver} (v12.x — current architecture)" ;;
            *)    report WARN "Unexpected version: ${deployed_ver}" ;;
        esac
    fi

    # 1f. sys_log target. Every session appends to it as the logged-in user;
    # when it is not world-writable each session instead writes one line per
    # sys_log() call to /tmp/biome_boot_errors_<pid>.log.
    log_path="$(grep -m1 -oP 'LOG_PATH\s*<-\s*"\K[^"]+' "$RPROFILE" 2>/dev/null || true)"
    if [[ -n "$log_path" ]]; then
        lp="$log_path"
        if [[ -n "$BIOME_HEALTH_ROOT" && "$log_path" != "${BIOME_HEALTH_ROOT}"/* ]]; then lp="${BIOME_HEALTH_ROOT}${log_path}"; fi
        if [[ ! -e "$lp" ]]; then
            report FAIL "sys_log target missing: ${log_path}" \
                "sessions cannot log; each writes /tmp/biome_boot_errors_<pid>.log — FIX: sudo install -m 666 /dev/null ${log_path}"
        else
            lp_mode="$(stat -c '%a' "$lp" 2>/dev/null || echo 0)"
            if [[ "$lp_mode" =~ ^[0-7]+$ ]] && (( (8#$lp_mode & 2) != 0 )); then
                report PASS "sys_log target writable by users: ${log_path} (mode ${lp_mode})"
            else
                report FAIL "sys_log target not writable by users: ${log_path} (mode ${lp_mode})" \
                    "FIX: sudo chmod 666 ${log_path} (Step 10 sets 0666; logrotate 'create' must keep it)"
            fi
        fi
    fi

    # 1g. The R that RStudio launches must actually read the deployed file:
    # probes force R_PROFILE, so a mismatch would otherwise go unnoticed.
    if [[ -z "$BIOME_HEALTH_ROOT" ]]; then
        r_cands=("$R_BIN")
        which_r="$(grep -E '^[[:space:]]*rsession-which-r[[:space:]]*=' "$RSERVER_CONF" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
        if [[ -n "$which_r" && "$which_r" != "$R_BIN" ]]; then r_cands+=("$which_r"); fi
        want_rp="$(readlink -f -- "$RPROFILE" 2>/dev/null || true)"
        for rb in "${r_cands[@]}"; do
            rh="$("$rb" RHOME 2>/dev/null || true)"
            site_rp="$(readlink -f -- "${rh}/etc/Rprofile.site" 2>/dev/null || true)"
            if [[ -n "$rh" && -n "$want_rp" && "$site_rp" == "$want_rp" ]]; then
                report PASS "R at ${rb} reads the deployed site profile" "R_HOME=${rh}"
            else
                report CRIT "R at ${rb} does NOT read ${RPROFILE}" \
                    "\${R_HOME}/etc/Rprofile.site → ${site_rp:-missing} (R_HOME=${rh:-?}); sessions on this R never load the BIOME profile"
            fi
        done
    fi
else
    report CRIT "Rprofile.site NOT FOUND at ${RPROFILE}" "FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
fi

# =============================================================================
# 2. FRAGMENT CHAIN
# =============================================================================

section "2. Fragment Chain"

if [[ -d "$RPROFILE_FRAG_DIR" ]]; then
    report PASS "Fragment directory exists: ${RPROFILE_FRAG_DIR}"

    # 2a. Deployed inventory — the dispatcher loads `[0-9][0-9]_*.R`, sorted.
    deployed_frags=()
    while IFS= read -r f; do
        if [[ -n "$f" ]]; then deployed_frags+=("$(basename "$f")"); fi
    done < <(find "$RPROFILE_FRAG_DIR" -maxdepth 1 -name '[0-9][0-9]_*.R' -type f | LC_ALL=C sort)
    deployed_count=${#deployed_frags[@]}
    expected_count=${#EXPECTED_FRAGMENTS[@]}

    if [[ "$deployed_count" -eq 0 ]]; then
        report CRIT "Fragment directory contains ZERO loadable fragments" \
            "the dispatcher runs in degraded mode — FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
    else
        report PASS "Deployed fragments: ${deployed_count}" "$(printf '%s ' "${deployed_frags[@]}")"
    fi

    in_list() { local needle="$1"; shift; local x; for x in "$@"; do if [[ "$x" == "$needle" ]]; then return 0; fi; done; return 1; }

    # 2b. Missing fragments.
    missing_frags=()
    for expected in "${EXPECTED_FRAGMENTS[@]}"; do
        if ! in_list "$expected" ${deployed_frags[@]+"${deployed_frags[@]}"}; then missing_frags+=("$expected"); fi
    done
    if [[ ${#missing_frags[@]} -eq 0 ]]; then
        report PASS "All ${expected_count} expected fragments present"
    else
        report FAIL "Missing fragments: ${#missing_frags[@]}" \
            "$(printf '%s ' "${missing_frags[@]}")— FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
    fi

    # 2c. Unexpected fragments — these DO get loaded by the dispatcher.
    unexpected_frags=()
    for deployed in ${deployed_frags[@]+"${deployed_frags[@]}"}; do
        if ! in_list "$deployed" "${EXPECTED_FRAGMENTS[@]}"; then unexpected_frags+=("$deployed"); fi
    done
    if [[ ${#unexpected_frags[@]} -gt 0 ]]; then
        report WARN "Unexpected fragments: ${#unexpected_frags[@]}" \
            "$(printf '%s ' "${unexpected_frags[@]}")— loaded, but not in the v12.10 set (orphan from an older deploy?)"
    else
        report PASS "No unexpected fragments"
    fi

    # 2d. Load-order hazards: shared 2-digit prefixes, *.R files the glob
    # skips, expected fragments out of canonical relative order.
    dup_prefixes="$(printf '%s\n' ${deployed_frags[@]+"${deployed_frags[@]}"} | cut -c1-2 | LC_ALL=C sort | uniq -d | tr '\n' ' ' || true)"
    if [[ -n "${dup_prefixes// /}" ]]; then
        report WARN "Duplicate fragment prefixes: ${dup_prefixes}" \
            "load order within a prefix depends on the rest of the filename — make prefixes unique"
    else
        report PASS "Fragment prefixes unique (deterministic load order)"
    fi

    unloadable=()
    while IFS= read -r f; do
        if [[ -n "$f" ]]; then unloadable+=("$(basename "$f")"); fi
    done < <(find "$RPROFILE_FRAG_DIR" -maxdepth 1 -name '*.R' -type f -not -name '[0-9][0-9]_*.R' | LC_ALL=C sort)
    if [[ ${#unloadable[@]} -gt 0 ]]; then
        report WARN "*.R files the dispatcher will NEVER load: ${#unloadable[@]}" \
            "$(printf '%s ' "${unloadable[@]}")— glob is [0-9][0-9]_*.R; rename or remove"
    else
        report PASS "No unloadable *.R files in the fragment directory"
    fi

    expected_present=(); deployed_expected_only=()
    for expected in "${EXPECTED_FRAGMENTS[@]}"; do
        if in_list "$expected" ${deployed_frags[@]+"${deployed_frags[@]}"}; then expected_present+=("$expected"); fi
    done
    for deployed in ${deployed_frags[@]+"${deployed_frags[@]}"}; do
        if in_list "$deployed" "${EXPECTED_FRAGMENTS[@]}"; then deployed_expected_only+=("$deployed"); fi
    done
    if [[ "$(printf '%s\n' ${expected_present[@]+"${expected_present[@]}"})" \
       == "$(printf '%s\n' ${deployed_expected_only[@]+"${deployed_expected_only[@]}"})" ]]; then
        report PASS "Expected fragments load in canonical relative order"
    else
        report FAIL "Expected fragments load OUT OF canonical order" \
            "deployed: $(printf '%s ' ${deployed_expected_only[@]+"${deployed_expected_only[@]}"})— a prefix was renamed; guards may install in the wrong sequence"
    fi

    # 2e. Fragment syntax + code placeholders (static scan).
    frag_parsed="$(kvof "$STATIC_OUT" FRAG_PARSED)"
    frag_bad="$(kvof "$STATIC_OUT" FRAG_BAD)"
    if is_num "$frag_bad" && [[ "$frag_bad" -eq 0 ]]; then
        report PASS "All ${frag_parsed:-?} fragments parse successfully"
    elif is_num "$frag_bad"; then
        report CRIT "Fragment syntax errors: ${frag_bad}" \
            "$(one_line "$(kvof "$STATIC_OUT" FRAG_BAD_TEXT)") — the loader skips each broken fragment (FragLoader FAIL)"
    else
        report CRIT "Fragment syntax check returned unparseable output" "$(one_line "$STATIC_OUT")"
    fi
    frag_ph="$(kvof "$STATIC_OUT" FRAG_PH)"
    if [[ -n "$frag_ph" ]]; then
        report CRIT "Unsubstituted placeholders in fragment code" "${frag_ph} — FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
    fi

    # 2f. Template vs deployed count (repo checkout = source of truth).
    if [[ -d "$TEMPLATE_DIR" ]]; then
        template_count="$(find "$TEMPLATE_DIR" -maxdepth 1 -name '[0-9][0-9]_*.R.template' -type f | wc -l)"
        if [[ "$deployed_count" -eq "$template_count" ]]; then
            report PASS "Template/deployed count match: ${template_count}"
        else
            report WARN "Template count (${template_count}) != deployed count (${deployed_count})" \
                "repo and node differ — redeploy (option 3) or update this checkout"
        fi
    fi
else
    report CRIT "Fragment directory MISSING: ${RPROFILE_FRAG_DIR}" "FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
fi

# =============================================================================
# 3. BYTE-COMPILED BUNDLE (v12.3)
# =============================================================================
# The bundle is an optimisation: on ANY mismatch the dispatcher falls back to
# the per-fragment loader, which stays correct — so bundle problems are WARN
# (slower session start), never FAIL. The md5 manifest is the dispatcher's own
# freshness test; file mtimes are irrelevant to it and are not checked.

section "3. Byte-Compiled Bundle (v12.3)"

bundle_rc="${RPROFILE_BUNDLE_DIR}/bundle.Rc"
bundle_mf="${RPROFILE_BUNDLE_DIR}/manifest.txt"
BUNDLE_FRESH=false
if [[ -d "$RPROFILE_BUNDLE_DIR" ]]; then
    report PASS "Bundle directory exists: ${RPROFILE_BUNDLE_DIR}"
    if [[ -f "$bundle_rc" && -f "$bundle_mf" ]]; then
        report PASS "bundle.Rc and manifest.txt present"
        declare -A MF_MD5=() FS_MD5=()
        while read -r h n _; do
            if [[ -n "${n:-}" ]]; then MF_MD5["$n"]="$h"; fi
        done < <(grep -vE '^[[:space:]]*(#|$)' "$bundle_mf" || true)
        while read -r h n; do
            if [[ -n "${n:-}" ]]; then FS_MD5["$n"]="$h"; fi
        done < <(cd "$RPROFILE_FRAG_DIR" 2>/dev/null && find . -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -printf '%f\n' \
                 | LC_ALL=C sort | xargs -r -I{} md5sum -- "{}" || true)
        b_changed=(); b_added=(); b_dropped=()
        for n in "${!FS_MD5[@]}"; do
            if [[ -z "${MF_MD5[$n]:-}" ]]; then b_added+=("$n")
            elif [[ "${MF_MD5[$n]}" != "${FS_MD5[$n]}" ]]; then b_changed+=("$n"); fi
        done
        for n in "${!MF_MD5[@]}"; do
            if [[ -z "${FS_MD5[$n]:-}" ]]; then b_dropped+=("$n"); fi
        done
        if [[ ${#MF_MD5[@]} -eq 0 ]]; then
            report WARN "Bundle manifest is empty — dispatcher uses the per-fragment loader" "FIX: option 3 rebuilds the bundle"
        elif [[ ${#b_changed[@]} -eq 0 && ${#b_added[@]} -eq 0 && ${#b_dropped[@]} -eq 0 ]]; then
            BUNDLE_FRESH=true
            report PASS "Bundle manifest matches on-disk fragments (FRESH)"
        else
            report WARN "Bundle is STALE — dispatcher falls back to the per-fragment loader (slower start)" \
                "changed=${b_changed[*]:-none} added=${b_added[*]:-none} dropped=${b_dropped[*]:-none}; fragments edited after the last deploy? FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
        fi
    else
        if [[ ! -f "$bundle_rc" ]]; then report WARN "bundle.Rc MISSING — per-fragment loader in use" "FIX: option 3 rebuilds the bundle"; fi
        if [[ ! -f "$bundle_mf" ]]; then report WARN "manifest.txt MISSING — per-fragment loader in use" "FIX: option 3 rebuilds the bundle"; fi
    fi
else
    report WARN "Bundle directory not found — per-fragment loader in use" "functional but slower; deploy v12.3+ (option 3)"
fi

# =============================================================================
# 4. GUARD INSTALLATION  [RUNTIME — one hermetic system probe feeds 4, 5d, 6, 9]
# =============================================================================

section "4. Guard Installation (system profile, via R runtime)"

run_system_probe
if [[ "$RUNTIME_TIER" != true ]]; then
    report WARN "Runtime probes SKIPPED" "$RUNTIME_SKIP_REASON"
elif [[ ! -f "$RPROFILE" ]]; then
    report WARN "Runtime probes SKIPPED" "no Rprofile.site to load"
else
    case "$SYS_STATE" in
        ok)
            report PASS "System profile load probe completed ($(sk STARTUP_MS) ms)" \
                "as ${PROBE_USER}; clean env, no user startup files — the baseline every session shares"
            if [[ -n "$(sk PROBE_ERROR)" ]]; then report WARN "Probe hit an internal error" "$(sk PROBE_ERROR)"; fi
            for guard_name in solve dist outer expand_grid; do
                if [[ "$(sk "GUARD_${guard_name}")" == "TRUE" ]]; then
                    report PASS "Guard: ${guard_name}() installed"
                else
                    report FAIL "Guard: ${guard_name}() NOT installed" \
                        "memory safety net incomplete — 45_memory_guards.R / 40_wrapper_installer.R did not install it (see section 9 fragment errors)"
                fi
            done
            if [[ "$(sk MAIN_API)" != "unset" && -n "$(sk MAIN_API)" ]]; then
                report PASS ".biome_env loaded" "VERSION=$(sk MAIN_VERSION) API_VERSION=$(sk MAIN_API)"
            else
                report FAIL ".biome_env NOT loaded" "the dispatcher MAIN block did not complete (see section 9)"
            fi
            tools_count="$(sk TOOLS_COUNT)"
            if is_num "$tools_count" && [[ "$tools_count" -gt 0 ]]; then
                report PASS "tools:biome_calc attached (${tools_count} tools)"
            else
                report WARN "tools:biome_calc not attached" "diagnostic helpers (status(), biome_make_cluster) unavailable"
            fi
            for tool_name in biome_make_cluster biome_future_plan status; do
                if [[ "$(sk "TOOL_${tool_name}")" == "TRUE" ]]; then
                    report PASS "Tool: ${tool_name} available"
                else
                    report WARN "Tool: ${tool_name} MISSING"
                fi
            done
            ;;
        timeout)
            report CRIT "System profile probe TIMED OUT after ${PROBE_TIMEOUT_S}s" \
                "the profile hangs during load for EVERY session on this node — stderr: $(one_line "$SYS_ERR" 160)"
            ;;
        *)
            report CRIT "System profile probe ${SYS_STATE} (rc=${SYS_RC})" "stderr: $(one_line "$SYS_ERR")"
            ;;
    esac
fi

# =============================================================================
# 5. BLAS & THREADING
# =============================================================================

section "5. BLAS & Threading"

# 5a/5b. Package + alternatives (production host only).
if command -v dpkg &>/dev/null && [[ -z "$BIOME_HEALTH_ROOT" ]]; then
    if dpkg -l libopenblas0-pthread 2>/dev/null | grep -q '^ii'; then
        report CRIT "libopenblas0-pthread INSTALLED — SIGSEGV risk in rsession" \
            "FIX: sudo bash scripts/50_setup_nodes.sh (option 2), or: sudo apt-get remove libopenblas0-pthread && sudo apt-get install libopenblas0-serial"
    else
        report PASS "libopenblas0-pthread not installed"
    fi
    if dpkg -l libopenblas0-serial 2>/dev/null | grep -q '^ii'; then
        report PASS "libopenblas0-serial installed"
    else
        report WARN "libopenblas0-serial NOT installed" "BLAS may fall back to reference BLAS (10-50x slower) — FIX: option 2"
    fi
fi
if command -v update-alternatives &>/dev/null && [[ -z "$BIOME_HEALTH_ROOT" ]]; then
    active_blas="$(update-alternatives --display libblas.so.3-x86_64-linux-gnu 2>/dev/null | grep -m1 'currently points to' | awk '{print $NF}' || true)"
    if [[ -n "$active_blas" ]]; then
        case "$active_blas" in
            *serial*)  report PASS "Active BLAS alternative: $(basename "$active_blas") (serial)" ;;
            *pthread*) report CRIT "Active BLAS alternative: ${active_blas} (pthread — SIGSEGV risk)" \
                           "FIX: sudo bash scripts/50_setup_nodes.sh (option 2)" ;;
            *)         report WARN "Active BLAS alternative: ${active_blas} (unknown variant)" ;;
        esac
    fi
fi

# 5c. CORETYPE wrappers (deployed by Step 4 = menu option 2).
if [[ -f "$CORETYPE_PROFILE" ]]; then
    report PASS "CORETYPE wrapper present: ${CORETYPE_PROFILE}"
else
    report WARN "CORETYPE wrapper missing: ${CORETYPE_PROFILE}" \
        "OpenBLAS may pick an unsupported instruction set on QEMU — FIX: sudo bash scripts/50_setup_nodes.sh (option 2)"
fi
if [[ -f "$RSESSION_PROFILE" ]]; then
    report PASS "rsession-profile present: ${RSESSION_PROFILE}"
else
    report WARN "rsession-profile missing: ${RSESSION_PROFILE}" \
        "RStudio sessions do not get the per-boot CORETYPE — FIX: option 2"
fi

# 5d. Runtime BLAS + thread caps (from the system probe).
if runtime_gate "Runtime BLAS check"; then
    blas_path="$(sk BLAS_PATH)"
    case "$(sk BLAS_VARIANT)" in
        serial)  report PASS "Runtime BLAS: serial (${blas_path})" ;;
        pthread) report CRIT "Runtime BLAS: pthread (${blas_path})" \
                     "SIGSEGV risk in rsession. The dispatcher's own startup detector (§-1.5) cannot see this: it calls sessionInfo() before utils is attached. FIX: option 2" ;;
        *)       report WARN "Runtime BLAS variant unknown (${blas_path})" "expected libopenblas0-serial" ;;
    esac
    s_omp="$(sk OMP_NUM_THREADS)"; s_obt="$(sk OPENBLAS_NUM_THREADS)"
    if is_num "$s_omp" && is_num "$s_obt" && [[ "$s_omp" -ge 1 && "$s_obt" -ge 1 ]]; then
        report PASS "Thread caps set in-session: OMP_NUM_THREADS=${s_omp} OPENBLAS_NUM_THREADS=${s_obt}" \
            "cgroup-aware budget from 05_thread_guard / 20_cgroup_reader (values > 1 are expected); OPENBLAS_CORETYPE=$(sk OPENBLAS_CORETYPE)"
    else
        report WARN "Thread caps not set in-session (OMP=${s_omp:-?} OPENBLAS=${s_obt:-?})" \
            "05_thread_guard / 20_cgroup_reader did not run — see section 9"
    fi
fi

# =============================================================================
# 6. RENVIRON.SITE CONTRACT (+ other writers of users' startup files)
# =============================================================================

section "6. Renviron.site Contract"

LOCAL_LIBS_ON=false
LOGIN_WRITES_RLIBS=false
if [[ -f "$RENVIRON" ]]; then
    report PASS "Renviron.site present: ${RENVIRON}"

    required_vars=(OPENBLAS_NUM_THREADS TMPDIR TMP TEMP R_TEMPDIR FONTCONFIG_PATH BSPM_SUDO RETICULATE_PYTHON)
    missing_vars=()
    for v in "${required_vars[@]}"; do
        if ! grep -qE "^[[:space:]]*${v}[[:space:]]*=" "$RENVIRON"; then missing_vars+=("$v"); fi
    done
    if [[ ${#missing_vars[@]} -eq 0 ]]; then
        report PASS "All ${#required_vars[@]} required vars present"
    else
        report FAIL "Missing Renviron.site vars: ${#missing_vars[@]}" \
            "$(printf '%s ' "${missing_vars[@]}")— FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
    fi

    # Temp dirs: R applies Renviron lines in order, so the LAST definition wins.
    tmpdir_last="$(renv_last "$RENVIRON" TMPDIR)"
    if [[ "$tmpdir_last" == "$RTMP_ROOT" ]]; then
        report PASS "TMPDIR=${tmpdir_last} (last definition)"
    else
        report FAIL "TMPDIR=${tmpdir_last:-<unset>} — R temp is NOT on the ${RTMP_ROOT} disk" \
            "T1 invariant: large R temp on /Rtmp (400 GB ext4), never /tmp (tmpfs) or NFS — FIX: sudo bash scripts/50_setup_nodes.sh (option 3) rewrites the file"
    fi
    other_tmp_bad=(); multi_defs=()
    for v in TMPDIR TMP TEMP R_TEMPDIR; do
        vl="$(renv_last "$RENVIRON" "$v")"
        if [[ "$v" != "TMPDIR" && -n "$vl" && "$vl" != "$RTMP_ROOT" ]]; then other_tmp_bad+=("${v}=${vl}"); fi
        vc="$(renv_count "$RENVIRON" "$v")"
        if is_num "$vc" && [[ "$vc" -gt 1 ]]; then multi_defs+=("${v}×${vc}"); fi
    done
    if [[ ${#other_tmp_bad[@]} -gt 0 ]]; then
        report WARN "Temp vars off ${RTMP_ROOT}: ${other_tmp_bad[*]}" "tools reading TMP/TEMP (Python, GDAL) write elsewhere — FIX: option 3"
    fi
    if [[ ${#multi_defs[@]} -gt 0 ]]; then
        report WARN "Renviron.site defines temp vars more than once: ${multi_defs[*]}" \
            "$(printf '%s\n' "R uses the last definition. Known second writer: 20_configure_rstudio.sh menu 1/4" \
               "(configure_rstudio_global_tmp) appends TMPDIR/TMP/TEMP=\"/nfs/home/Rtmp\" (NFS)." \
               "PROPOSED FIX: sudo bash scripts/50_setup_nodes.sh (option 3) rewrites Renviron.site; do not re-run that 20_configure_rstudio.sh step.")"
    fi

    rlibs_user="$(renv_last "$RENVIRON" R_LIBS_USER)"
    if [[ "$rlibs_user" == *"/var/lib/biome-Rlibs"* ]]; then
        LOCAL_LIBS_ON=true
        report PASS "R_LIBS_USER uses the per-user local-disk path (v12.4+)" "${rlibs_user}"
    elif [[ -z "$rlibs_user" ]] && grep -q 'Per-user local R library DISABLED' "$RENVIRON"; then
        report PASS "Per-user local R libs disabled by config (ENABLE_R_LIBS_LOCAL=false)"
    elif [[ -z "$rlibs_user" ]]; then
        report WARN "R_LIBS_USER not set in Renviron.site" "expected the v12.4 local-disk path — FIX: option 3"
    else
        report WARN "R_LIBS_USER does not use /var/lib/biome-Rlibs" "${rlibs_user} — pre-v12.4 config? FIX: option L then 3"
    fi

    # 6x. Did Renviron.site actually reach the session, and where did tempdir() land?
    if runtime_gate "Renviron.site in-session check"; then
        s_tmpdir="$(sk TMPDIR)"; s_tempdir="$(sk TEMPDIR)"
        if [[ -n "$tmpdir_last" && "$s_tmpdir" == "$tmpdir_last" ]]; then
            report PASS "Renviron.site reached the session (TMPDIR=${s_tmpdir})"
        else
            report FAIL "Renviron.site NOT applied in-session (TMPDIR=${s_tmpdir:-unset}, file says ${tmpdir_last:-unset})" \
                "the R that runs sessions reads another Renviron.site (see 1g)"
        fi
        if [[ -n "$s_tmpdir" && "$s_tempdir" == "${s_tmpdir%/}/"* ]]; then
            report PASS "tempdir() is on TMPDIR: ${s_tempdir}"
        else
            report FAIL "tempdir() fell back to ${s_tempdir:-?} instead of ${s_tmpdir:-TMPDIR}" \
                "TMPDIR is missing or not writable for ${PROBE_USER}; R silently falls back to /tmp — check the /Rtmp mount + mode 1777 (50_setup_nodes.sh Step 5)"
        fi
    fi
else
    report CRIT "Renviron.site NOT FOUND at ${RENVIRON}" "FIX: sudo bash scripts/50_setup_nodes.sh (option 3)"
fi

# 6y. Login script (20_configure_rstudio.sh) — the other writer of ~/.Renviron.
if [[ -f "$LOGIN_SCRIPT" ]]; then
    if grep -qE '\[[[:space:]]*"R_LIBS_USER"[[:space:]]*\]' "$LOGIN_SCRIPT"; then
        LOGIN_WRITES_RLIBS=true
        if [[ "$LOCAL_LIBS_ON" == true ]]; then
            report WARN "Login script rewrites R_LIBS_USER in every user's ~/.Renviron" \
                "$(printf '%s\n' "${LOGIN_SCRIPT_PATH} (deployed by 20_configure_rstudio.sh) appends" \
                   "R_LIBS_USER=<home>/R/x86_64-pc-linux-gnu-library/<Rver> on each bash login shell (ssh, ttyd," \
                   "RStudio Terminal) whenever the line is missing: it overrides Renviron.site's local-disk path and" \
                   "re-adds the overrides Step 9 / 99_check_user_renviron_overrides.sh remove. Runtime impact is" \
                   "neutralised by fragment 04 (v12.9.2) while /var/lib/biome-Rlibs/<user>/<Rver> exists and is writable." \
                   "PROPOSED FIX: sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit (patches the deployed" \
                   "file in place; the template is already fixed — do NOT redeploy through 20_configure_rstudio.sh" \
                   "menu 1/3, they chown -R the home root), then clean existing files: sudo bash scripts/50_setup_nodes.sh (option 4).")"
        else
            report PASS "Login script writes R_LIBS_USER — no effect while local R libs are disabled" \
                "$(printf '%s\n' "the value is R's own default (~/R/x86_64-pc-linux-gnu-library/<Rver>) when R_PROJECTS_ROOT is the home root." \
                   "Before setting ENABLE_R_LIBS_LOCAL=true: sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit," \
                   "then sudo bash scripts/50_setup_nodes.sh (option 4) to remove the existing lines, then option L / 3.")"
        fi
    elif grep -q '# \[hotfix [0-9-]*\] R_LIBS_USER entry removed' "$LOGIN_SCRIPT"; then
        report PASS "Login script does not write R_LIBS_USER (fix_login_script_rlibs_inplace.sh applied): ${LOGIN_SCRIPT_PATH}"
    else
        report PASS "Login script does not write R_LIBS_USER: ${LOGIN_SCRIPT_PATH}"
    fi
else
    report PASS "No RStudio login script deployed at ${LOGIN_SCRIPT_PATH} (no other ~/.Renviron writer)"
fi

# =============================================================================
# 7. PER-USER STARTUP (--user)
# =============================================================================
# Every read below runs AS THE USER (u_run): that is RStudio's view of the
# files, and it keeps working on NFS homes exported with root_squash.

FIX_KIND=(); FIX_A=(); FIX_B=(); FIX_ROOT=(); FIX_DESC=()
MANUAL=()
add_fix()    { FIX_KIND+=("$1"); FIX_A+=("$2"); FIX_B+=("$3"); FIX_ROOT+=("$4"); FIX_DESC+=("$5"); }
add_manual() { MANUAL+=("$1"); }

FILE_WRITER_RE='ragg|agg_[a-z]+|png|jpe?g|tiff|bmp|pdf|cairo|svg|postscript'

# code_lines TEXT ERE → "N:line" for non-comment lines matching ERE.
# awk -v expands backslash escapes, so patterns use [(] instead of \(.
code_lines() {
    printf '%s\n' "$1" | awk -v re="$2" '!/^[[:space:]]*#/ && $0 ~ re { print NR ":" $0 }' || true
}

# dotfile_access LABEL FILE — ownership/readability; queues the repairs.
dotfile_access() {
    local label="$1" f="$2" owner
    owner="$(user_stat '%u' "$f")"
    if [[ -n "$owner" && "$owner" != "$U_UID" ]]; then
        report WARN "${label} is owned by uid ${owner}, not ${U_NAME} (uid ${U_UID})" \
            "the user cannot edit or replace it (created by root?)"
        add_fix chown "$f" "" yes "chown ${U_UID}:${U_GID} ${f}   (currently uid ${owner})"
    fi
    if ! user_is -r "$f"; then
        report FAIL "${label} is not readable by ${U_NAME}" \
            "$(user_stat '%A %U:%G' "$f") — R silently skips it, so the user's settings never apply"
        add_fix chmod_read "$f" "" no "chmod u+r ${f}"
        return 1
    fi
    return 0
}

section "7. Per-User Startup${U_NAME:+ (${U_NAME})}"
SCOPE="user"
U_HOME_OK=false
RSESSION_PIDS=""
RENV_FIX_LINES=""
RPROF_FIX_LINES=""
PREFS_INVALID=false

# shellcheck disable=SC2088  # "~/..." in report labels is display text, never a path
if [[ -z "$U_NAME" ]]; then
    SCOPE="system"
    report WARN "Per-user checks SKIPPED" "pass --user <name> to check that user's startup files and session state"
else
    U_RENV="${U_HOME}/.Renviron"
    U_RPROF="${U_HOME}/.Rprofile"
    U_RDATA="${U_HOME}/.RData"
    U_PREFS="${U_HOME}/.config/rstudio/rstudio-prefs.json"
    U_RS_SESSIONS="${U_HOME}/.local/share/rstudio/sessions"

    # ── 7a. Home ──────────────────────────────────────────────────────────
    sub "Home directory"
    if ! user_is -d "$U_HOME"; then
        report CRIT "Home ${U_HOME} does not exist (as seen by ${U_NAME})" \
            "RStudio cannot start a session — NFS not mounted? (TROUBLESHOOTING §4.2)"
    elif ! user_is -x "$U_HOME" || ! user_is -r "$U_HOME"; then
        report CRIT "Home ${U_HOME} is not accessible by ${U_NAME}" "$(stat -c '%A %U:%G' "$U_HOME" 2>/dev/null || true)"
    elif ! user_is -w "$U_HOME"; then
        report FAIL "Home ${U_HOME} is not writable by ${U_NAME}" \
            "RStudio cannot create ~/.local/share/rstudio → login fails ('chmod 700 ~/.local/share/rstudio' errors)"
        U_HOME_OK=true
    else
        report PASS "Home accessible and writable by ${U_NAME}: ${U_HOME}"
        U_HOME_OK=true
    fi
    RSESSION_PIDS="$(pgrep -u "$U_UID" -x rsession 2>/dev/null | tr '\n' ' ' || true)"
    if [[ -n "${RSESSION_PIDS// /}" ]]; then
        printf "        info: running rsession pid(s): %s— changes apply after Session → Restart R\n" "$RSESSION_PIDS"
    fi

    if [[ "$U_HOME_OK" == true ]]; then
        # ── 7b. ~/.Renviron ───────────────────────────────────────────────
        sub "~/.Renviron (read after Renviron.site: every line here overrides the system)"
        if user_is -e "$U_RENV"; then
            if dotfile_access "~/.Renviron" "$U_RENV"; then
                renv_content="$(u_run head -c 1048576 -- "$U_RENV" 2>/dev/null || true)"
                declare -A RC_LINES=() RC_TEXT=()
                renv_add() {
                    RC_LINES["$1"]="${RC_LINES[$1]:-}${RC_LINES[$1]:+ }$2"
                    RC_TEXT["$1"]="${RC_TEXT[$1]:-}${RC_TEXT[$1]:+; }L$2 $3"
                }
                # R's built-in R_LIBS_USER (R-admin §6.2): ~/R/<platform>-library/<major.minor>
                rlibs_is_r_default() {
                    local v="$1" want
                    [[ -n "$R_VER_MM" ]] || return 1
                    want="${U_HOME%/}/R/x86_64-pc-linux-gnu-library/${R_VER_MM}"
                    v="${v//\$\{HOME\}/$U_HOME}"; v="${v//\$HOME/$U_HOME}"
                    if [[ "$v" == "~/"* ]]; then v="${U_HOME%/}/${v#\~/}"; fi
                    v="${v//%v/$R_VER_MM}"; v="${v//%p/x86_64-pc-linux-gnu}"
                    [[ "${v%/}" == "$want" ]]
                }
                RL_NONDEFAULT=false
                ln=0
                while IFS= read -r rline || [[ -n "$rline" ]]; do
                    ln=$((ln + 1))
                    if [[ "$rline" =~ ^[[:space:]]*# ]]; then continue; fi
                    if [[ ! "$rline" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*=(.*)$ ]]; then continue; fi
                    rn="${BASH_REMATCH[1]}"; rv="${BASH_REMATCH[2]}"
                    rv="${rv#"${rv%%[![:space:]]*}"}"; rv="${rv%"${rv##*[![:space:]]}"}"
                    rv="${rv#\"}"; rv="${rv%\"}"; rv="${rv#\'}"; rv="${rv%\'}"
                    case "$rn" in
                        BIOME_WORKER_MODE) renv_add worker "$ln" "${rn}=${rv}" ;;
                        BIOME_DISABLE_FRAGMENTS|BIOME_DISABLE_FORK_GUARD|BIOME_DISABLE_USER_LIB_BOOTSTRAP)
                            renv_add killswitch "$ln" "${rn}=${rv}" ;;
                        BIOME_DISABLE_BUNDLE|BIOME_DEBUG|BIOME_WORKER_DEBUG|BIOME_TERRA_NORAM|BIOME_FORCE_FORK_GUARD|BIOME_FORCE_INSTALL_BLOCK)
                            renv_add switches "$ln" "${rn}=${rv}" ;;
                        TMPDIR|TMP|TEMP|R_TEMPDIR)
                            if [[ "$rv" != "$RTMP_ROOT" ]]; then renv_add tmpdir "$ln" "${rn}=${rv}"; fi ;;
                        OPENBLAS_CORETYPE) renv_add coretype "$ln" "${rn}=${rv}" ;;
                        OMP_NUM_THREADS|OPENBLAS_NUM_THREADS|MKL_NUM_THREADS|MC_CORES)
                            renv_add threads "$ln" "${rn}=${rv}" ;;
                        R_LIBS_USER|R_LIBS_SITE|R_LIBS)
                            renv_add rlibs "$ln" "${rn}=${rv}"
                            if [[ "$rn" != "R_LIBS_USER" ]] || ! rlibs_is_r_default "$rv"; then RL_NONDEFAULT=true; fi ;;
                        RETICULATE_PYTHON|EARTHENGINE_PYTHON)
                            if [[ -n "$rv" && "$rv" != *'$'* ]] && ! user_is -x "$rv"; then
                                renv_add python "$ln" "${rn}=${rv}"
                            fi ;;
                    esac
                done <<< "$renv_content"

                renv_found=false
                renv_class() {
                    local cls="$1" sev="$2" title="$3" why="$4"
                    if [[ -z "${RC_LINES[$cls]:-}" ]]; then return 0; fi
                    renv_found=true
                    report "$sev" "~/.Renviron ${title}: ${RC_TEXT[$cls]}" "$why"
                    RENV_FIX_LINES="${RENV_FIX_LINES}${RENV_FIX_LINES:+ }${RC_LINES[$cls]}"
                    return 0
                }
                renv_class worker CRIT "sets BIOME_WORKER_MODE" \
                    "every R session takes the PSOCK-worker fast path: no memory guards, no tools, no MAIN block (dispatcher §-1)"
                renv_class killswitch FAIL "persists operator kill-switches" \
                    "single-session debug switches (BOTANIST_CHEATSHEET: never in .Renviron) — they disable safety guards in every session"
                renv_class tmpdir FAIL "moves R temp off ${RTMP_ROOT}" \
                    "tempdir() (NIMBLE/terra/Stan scratch) lands on tmpfs /tmp or NFS; 50_setup_nodes.sh Step 9 strips these"
                renv_class coretype FAIL "pins OPENBLAS_CORETYPE" \
                    "inherited by PSOCK workers: a CPU mismatch after a VM migration → SIGILL; biome-coretype.sh detects it per boot"
                renv_class threads WARN "sets static thread counts" \
                    "conflicts with the cgroup-aware budget that 05/20 fragments apply; Step 9 strips these"
                renv_class switches WARN "persists debug/performance switches" \
                    "meant for one session only (slower start, debug logs in /tmp, terra rasters back in RAM)"
                renv_class python WARN "points at a missing Python interpreter" \
                    "reticulate/rgee fail; Renviron.site already sets the system venv"
                if [[ -n "${RC_LINES[rlibs]:-}" ]]; then
                    renv_found=true
                    rl_note=""; rl_login=false
                    if [[ "$LOGIN_WRITES_RLIBS" == true && "${RC_TEXT[rlibs]}" == *"x86_64-pc-linux-gnu-library"* ]]; then
                        rl_login=true
                        rl_note=" — re-written by ${LOGIN_SCRIPT_PATH} at every login shell (section 6)"
                    fi
                    if grep -qE '^# \[biome-cleanup [0-9-]+\] disabled \(was: R_LIBS' <<< "$renv_content"; then
                        rl_note="${rl_note} — re-added after an earlier cleanup (writer conflict)"
                    fi
                    if [[ "$LOCAL_LIBS_ON" != true && "$RL_NONDEFAULT" == false ]]; then
                        report PASS "~/.Renviron sets R_LIBS_USER to R's own default: ${RC_TEXT[rlibs]}" \
                            "no effect while local R libs are disabled (ENABLE_R_LIBS_LOCAL=false)${rl_note}; remove it before enabling them (section 6)"
                    else
                        if [[ "$LOCAL_LIBS_ON" == true ]]; then
                            rl_why="R uses this value instead of Renviron.site's local-disk path; fragment 04 still prepends /var/lib/biome-Rlibs/${U_NAME}/<Rver> when that dir is writable"
                        else
                            rl_why="R uses this value instead of its default ${U_HOME%/}/R/x86_64-pc-linux-gnu-library/${R_VER_MM:-<Rver>}"
                        fi
                        report WARN "~/.Renviron overrides R_LIBS_*: ${RC_TEXT[rlibs]}" "${rl_why}${rl_note}"
                        rl_first=""
                        if [[ "$rl_login" == true ]]; then
                            rl_first=" — first stop the login script re-adding it: sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit"
                        elif [[ -n "$rl_note" ]]; then
                            rl_first=" — fix the login script first (section 6)"
                        fi
                        add_manual "R_LIBS_* in ${U_RENV} (lines ${RC_LINES[rlibs]}): owned by sudo bash scripts/50_setup_nodes.sh (option 4, all users, keeps .bak) or sudo bash scripts/99_check_user_renviron_overrides.sh --fix --commit${rl_first}"
                    fi
                fi
                if [[ "$renv_found" != true ]]; then
                    report PASS "~/.Renviron: no overrides of system-managed variables"
                fi
                if [[ -n "$RENV_FIX_LINES" ]]; then
                    add_fix comment_renviron "$U_RENV" "$RENV_FIX_LINES" no \
                        "comment out lines ${RENV_FIX_LINES} of ${U_RENV} (marker '# [biome-cleanup ${TODAY}]', backup ${U_RENV}.bak.${STAMP})"
                fi
            fi
        else
            report PASS "No ~/.Renviron (system Renviron.site applies unchanged)"
        fi

        # ── 7c. ~/.Rprofile ───────────────────────────────────────────────
        sub "~/.Rprofile (runs after Rprofile.site: it wins every conflict)"
        if user_is -e "$U_RPROF"; then
            if dotfile_access "~/.Rprofile" "$U_RPROF"; then
                rprof_content="$(u_run head -c 1048576 -- "$U_RPROF" 2>/dev/null || true)"
                rprof_scan="$(u_run env -i "PATH=${PROBE_PATH}" "HOME=${U_HOME_REAL}" "LANG=C.UTF-8" "LANGUAGE=en" \
                    "BIOME_HC_FILE=${U_RPROF}" timeout -k 5 "$PROBE_TIMEOUT_S" "$R_BIN" --vanilla --no-echo \
                    < "${WORK_DIR}/rprof_scan.R" 2>&1 || true)"
                rprof_found=false
                case "$(kvof "$rprof_scan" PARSE)" in
                    FAIL)
                        rprof_found=true
                        report FAIL "~/.Rprofile does not parse" \
                            "$(one_line "$(kvof "$rprof_scan" PARSE_ERR)" 180) — R runs it up to the error and prints it at every session start"
                        add_manual "~/.Rprofile syntax error ($(one_line "$(kvof "$rprof_scan" PARSE_ERR)" 90)): fix it with the user, or quarantine it with --reset-profile"
                        ;;
                    OK)
                        covered=" "
                        for rng in $(kvof "$rprof_scan" DEVICE_TOPLEVEL); do
                            a="${rng%-*}"; b="${rng#*-}"
                            if ! is_num "$a" || ! is_num "$b"; then continue; fi
                            stmt="$(printf '%s\n' "$rprof_content" | sed -n "${a},${b}p" | tr '\n' ' ')"
                            for ((i = a; i <= b; i++)); do covered="${covered}${i} "; done
                            if grep -qiE "$FILE_WRITER_RE" <<< "$stmt"; then
                                rprof_found=true
                                report FAIL "~/.Rprofile sets a file-writing graphics device (lines ${a}-${b})" \
                                    "$(one_line "$stmt" 140) — plots go to files, the RStudio Plots pane stays blank (TROUBLESHOOTING §1.7)"
                                for ((i = a; i <= b; i++)); do RPROF_FIX_LINES="${RPROF_FIX_LINES}${RPROF_FIX_LINES:+ }${i}"; done
                            elif ! grep -q 'RStudioGD' <<< "$stmt"; then
                                rprof_found=true
                                report WARN "~/.Rprofile overrides options(device=) (lines ${a}-${b})" "$(one_line "$stmt" 140)"
                                add_manual "~/.Rprofile lines ${a}-${b} set options(device=…): review with the user"
                            fi
                        done
                        while IFS= read -r hit; do
                            if [[ -z "$hit" ]]; then continue; fi
                            hn="${hit%%:*}"
                            if [[ "$covered" == *" ${hn} "* ]]; then continue; fi
                            if grep -qiE "$FILE_WRITER_RE" <<< "${hit#*:}"; then
                                rprof_found=true
                                report FAIL "~/.Rprofile sets a file-writing device inside a block (line ${hn})" \
                                    "$(one_line "${hit#*:}" 140) — nested in if/function/local: not auto-fixable"
                                add_manual "~/.Rprofile line ${hn}: options(device=…) nested in a block — edit by hand with the user"
                            fi
                        done < <(code_lines "$rprof_content" 'options[[:space:]]*[(].*device[[:space:]]*=')
                        ;;
                    *)
                        report WARN "~/.Rprofile could not be analysed" "$(one_line "$rprof_scan")"
                        rprof_found=true
                        ;;
                esac
                thread_hits="$(code_lines "$rprof_content" 'OMP_NUM_THREADS|OPENBLAS_NUM_THREADS|MKL_NUM_THREADS|mc[.]cores' | cut -d: -f1 | tr '\n' ' ')"
                if [[ -n "${thread_hits// /}" ]]; then
                    rprof_found=true
                    report WARN "~/.Rprofile sets thread/core counts (lines ${thread_hits% })" \
                        "the system clamps mc.cores (55_options_guard) and re-applies the cgroup budget (20_cgroup_reader), so it only partly applies — BOTANIST_CHEATSHEET §7"
                fi
                setwd_hits="$(code_lines "$rprof_content" '(^|[^A-Za-z0-9_.])setwd[[:space:]]*[(]' | cut -d: -f1 | tr '\n' ' ')"
                if [[ -n "${setwd_hits// /}" ]]; then
                    rprof_found=true
                    report WARN "~/.Rprofile calls setwd() at startup (lines ${setwd_hits% })" \
                        "every session starts in a different directory — BOTANIST_CHEATSHEET §7"
                fi
                if [[ "$rprof_found" != true ]]; then
                    report PASS "~/.Rprofile parses; no graphics-device, thread or setwd overrides"
                fi
                if [[ -n "$RPROF_FIX_LINES" ]]; then
                    add_fix comment_rprofile "$U_RPROF" "$RPROF_FIX_LINES" no \
                        "comment out the options(device=…) statement(s) at lines ${RPROF_FIX_LINES} of ${U_RPROF} (re-parsed after edit, rolled back if it breaks)"
                fi
            fi
        else
            report PASS "No ~/.Rprofile"
        fi

        # ── 7d. Workspace restore ─────────────────────────────────────────
        sub "Workspace restore (~/.RData + RStudio load_workspace)"
        prefs_value() {
            local f="$1" runner="$2"
            if [[ -z "$JQ_BIN" ]]; then printf 'unknown'; return 0; fi
            if [[ "$runner" == user ]]; then
                if ! user_is -f "$f"; then printf 'absent'; return 0; fi
                u_run "$JQ_BIN" -r "if type == \"object\" then (if has(\"$3\") then (.$3|tostring) else \"absent\" end) else \"invalid\" end" "$f" 2>/dev/null || printf 'invalid'
            else
                if [[ ! -f "$f" ]]; then printf 'absent'; return 0; fi
                "$JQ_BIN" -r "if type == \"object\" then (if has(\"$3\") then (.$3|tostring) else \"absent\" end) else \"invalid\" end" "$f" 2>/dev/null || printf 'invalid'
            fi
        }
        u_lw="$(prefs_value "$U_PREFS" user load_workspace)"
        s_lw="$(prefs_value "$RSTUDIO_SYS_PREFS" system load_workspace)"
        if [[ "$u_lw" == "invalid" ]]; then
            PREFS_INVALID=true
            report WARN "~/.config/rstudio/rstudio-prefs.json is not valid JSON" \
                "RStudio ignores it and runs with defaults (load_workspace=true) — --reset-profile quarantines it"
            add_manual "Corrupted ${U_PREFS}: quarantine it with --reset-profile (or fix the JSON with the user)"
        fi
        eff_lw="true"; lw_src="RStudio default"
        if [[ "$u_lw" == "true" || "$u_lw" == "false" ]]; then eff_lw="$u_lw"; lw_src="user rstudio-prefs.json"
        elif [[ "$s_lw" == "true" || "$s_lw" == "false" ]]; then eff_lw="$s_lw"; lw_src="/etc/rstudio/rstudio-prefs.json"; fi
        if [[ -z "$JQ_BIN" ]]; then lw_src="${lw_src}; jq not installed — prefs not read"; fi
        if user_is -f "$U_RDATA"; then
            rd_size="$(user_stat '%s' "$U_RDATA")"
            if ! is_num "$rd_size"; then rd_size=0; fi
            rd_h="$(human_bytes "$rd_size")"
            if [[ "$eff_lw" == "true" ]]; then
                rd_sev=WARN
                if [[ "$rd_size" -ge "$RDATA_FAIL_BYTES" ]]; then rd_sev=FAIL; fi
                report "$rd_sev" "~/.RData (${rd_h}) is restored at every RStudio login (load_workspace=true: ${lw_src})" \
                    "slow login, browser 'Aw, Snap!'/error code 4 on big workspaces; a saved .biome_env also shadows the fresh profile state"
                if [[ -n "$JQ_BIN" && "$PREFS_INVALID" != true ]]; then
                    add_fix prefs_workspace "$U_PREFS" "" no \
                        "set load_workspace=false, save_workspace=\"never\" in ${U_PREFS} with jq (platform policy; ~/.RData itself is NOT touched)"
                else
                    add_manual "Disable workspace restore for ${U_NAME}: Tools → Global Options → General → untick 'Restore .RData' (jq missing or prefs corrupted)"
                fi
            elif [[ "$rd_size" -ge "$RDATA_FAIL_BYTES" ]]; then
                report WARN "~/.RData (${rd_h}) is not restored by RStudio (load_workspace=false), but plain R started in ~ still loads it" \
                    "suggest the user saves results with saveRDS() instead (User_guide §1)"
            else
                report PASS "~/.RData present (${rd_h}) but not restored by RStudio (load_workspace=false: ${lw_src})"
            fi
        else
            report PASS "No ~/.RData to restore"
        fi

        # ── 7e. RStudio session state ─────────────────────────────────────
        sub "RStudio session state (~/.local/share/rstudio)"
        if user_is -d "$U_RS_SESSIONS"; then
            rs_size="$(u_run timeout 20 du -sb -- "$U_RS_SESSIONS" 2>/dev/null | awk '{print $1}' || true)"
            rs_n="$(u_run find "${U_RS_SESSIONS}/active" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)"
            if is_num "$rs_size" && [[ "$rs_size" -ge "$RSTATE_WARN_BYTES" ]]; then
                report WARN "RStudio session state is $(human_bytes "$rs_size") (${rs_n} session dir(s))" \
                    "RStudio resumes suspended sessions at login — a huge or corrupted one keeps the browser on 'Loading…'"
                add_manual "Quarantine ${U_NAME}'s RStudio state (reversible): sudo bash ${SELF} --user ${U_NAME} --reset-profile --commit"
            elif is_num "$rs_size"; then
                report PASS "RStudio session state: $(human_bytes "$rs_size") in ${rs_n} session dir(s)"
            else
                report WARN "RStudio session state size unknown (du timed out or failed)" "${U_RS_SESSIONS}"
            fi
        else
            report PASS "No RStudio session state yet"
        fi

        # ── 7f. Per-user system dirs ──────────────────────────────────────
        sub "Per-user system dirs (local R library, /Rtmp scratch)"
        if [[ "$LOCAL_LIBS_ON" == true ]]; then
            lroot="$R_LIBS_LOCAL_ROOT_DEFAULT"; lparent="${lroot}/${U_NAME}"; lleaf="${lparent}/${R_VER_MM}"
            heal_desc="mkdir -p ${lleaf}; chmod 0755 + chown ${U_UID}:${U_GID} on ${lparent} and ${lleaf} (same as 50_setup_nodes.sh Step 7c warm-up)"
            if [[ -z "$R_VER_MM" ]]; then
                report WARN "Cannot determine the R version — per-user library not checked"
            elif [[ ! -d "$lroot" ]]; then
                SCOPE="system"
                report FAIL "Local R library root missing: ${lroot}" "FIX: sudo bash scripts/50_setup_nodes.sh (option L)"
                SCOPE="user"
            elif [[ -d "$lleaf" ]]; then
                if user_is -w "$lleaf" && [[ "$(stat -c '%u' "$lparent" 2>/dev/null || true)" == "$U_UID" ]]; then
                    report PASS "Per-user R library writable: ${lleaf}"
                else
                    report FAIL "Per-user R library not usable by ${U_NAME}: ${lleaf}" \
                        "$(stat -c '%U:%G %a' "$lparent" "$lleaf" 2>/dev/null | tr '\n' ' ')— install.packages() falls back to NFS and fragment 04 skips the local path (the v12.9 root:root bug)"
                    add_fix rlib_heal "$lparent" "$lleaf" self "$heal_desc"
                fi
            else
                stale_vers="$(find "$lparent" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null || true)"
                if [[ -n "${stale_vers// /}" ]]; then
                    report FAIL "No per-user R library for R ${R_VER_MM}; only: ${stale_vers% }" \
                        "packages were installed for another R version; library() goes to NFS (docs/operations/UPGRADE_TO_v12.4.md)"
                else
                    report WARN "No per-user R library yet: ${lleaf}" \
                        "fragment 04 creates it at the first session; missing after a login means ${lroot} is not writable"
                fi
                add_fix rlib_heal "$lparent" "$lleaf" self "$heal_desc"
            fi
        else
            report PASS "Per-user local R libraries disabled by config — nothing to check"
        fi
        u_tmp="${RTMP_ROOT}/biome_${U_NAME}"
        if [[ -d "$u_tmp" ]]; then
            ut_owner="$(stat -c '%u' "$u_tmp" 2>/dev/null || true)"
            if [[ "$ut_owner" == "$U_UID" ]]; then
                report PASS "Scratch dir owned by ${U_NAME}: ${u_tmp}"
            else
                report FAIL "Scratch dir ${u_tmp} is owned by uid ${ut_owner}, not ${U_NAME}" \
                    "the dispatcher cannot create stan_compile/rcpp_cache/cluster_logs there (litter from an R run as root?)"
                add_fix rtmp_heal "$u_tmp" "" yes "chown -R ${U_UID}:${U_GID} ${u_tmp}; chmod 0700 ${u_tmp}"
            fi
        else
            report PASS "Scratch dir ${u_tmp} not created yet (made at the first session)"
        fi

        # ── 7g. A/B: system baseline vs the user's own startup files ─────
        sub "Session start: system baseline vs ${U_NAME}'s startup files [RUNTIME]"
        if [[ "$RUNTIME_TIER" != true ]]; then
            report WARN "A/B startup probe SKIPPED" "$RUNTIME_SKIP_REASON"
        elif [[ ! -f "$RPROFILE" ]]; then
            report WARN "A/B startup probe SKIPPED" "no Rprofile.site to load"
        else
            run_r_probe session_base "${WORK_DIR}/session_probe.R"
            BASE_OUT="$R_OUT"; BASE_ERR="$R_ERR"; BASE_STATE="$(probe_outcome "$R_OUT" "$R_RC")"; BASE_RC="$R_RC"
            run_r_probe session_user "${WORK_DIR}/session_probe.R"
            USR_OUT="$R_OUT"; USR_ERR="$R_ERR"; USR_STATE="$(probe_outcome "$R_OUT" "$R_RC")"; USR_RC="$R_RC"
            bk() { kvof "$BASE_OUT" "$1"; }
            uk() { kvof "$USR_OUT" "$1"; }
            if [[ "$BASE_STATE" != "ok" ]]; then
                SCOPE="system"
                report CRIT "Interactive system baseline ${BASE_STATE} (rc=${BASE_RC})" \
                    "the system profile fails in interactive mode (what the RStudio console runs) — stderr: $(one_line "$BASE_ERR" 160)"
                SCOPE="user"
            else
                base_ms="$(bk STARTUP_MS)"
                report PASS "Interactive baseline (system profile only): ${base_ms} ms"
                case "$USR_STATE" in
                    timeout)
                        report CRIT "${U_NAME}'s session start HANGS with their startup files (> ${PROBE_TIMEOUT_S}s; baseline ${base_ms} ms)" \
                            "RStudio stays on 'Loading…' — the cause is in ~/.Renviron / ~/.Rprofile (see above). stderr: $(one_line "$USR_ERR" 140)"
                        add_manual "Session start hangs: quarantine the startup files (reversible): sudo bash ${SELF} --user ${U_NAME} --reset-profile --commit"
                        ;;
                    crashed|incomplete)
                        report CRIT "${U_NAME}'s R session ends before the prompt (rc=${USR_RC})" \
                            "q()/quit() or a fatal error in ~/.Rprofile? stderr: $(one_line "$USR_ERR" 160)"
                        add_manual "Session dies at startup: quarantine the startup files (reversible): sudo bash ${SELF} --user ${U_NAME} --reset-profile --commit"
                        ;;
                    ok)
                        ab_found=false
                        usr_ms="$(uk STARTUP_MS)"
                        if is_num "$usr_ms" && is_num "$base_ms"; then
                            delta=$((usr_ms - base_ms))
                            if [[ "$usr_ms" -gt "$SLOW_START_FAIL_MS" ]]; then
                                ab_found=true
                                report FAIL "${U_NAME}'s session start takes ${usr_ms} ms (+${delta} ms from their startup files)" "RStudio may give up waiting for the session"
                            elif [[ "$usr_ms" -gt "$SLOW_START_WARN_MS" && "$delta" -gt 2000 ]]; then
                                ab_found=true
                                report WARN "${U_NAME}'s session start takes ${usr_ms} ms (+${delta} ms from their startup files)" "heavy library()/network calls in ~/.Rprofile?"
                            else
                                report PASS "${U_NAME}'s session start: ${usr_ms} ms (${delta} ms over baseline)"
                            fi
                        fi
                        base_errs="$(printf '%s\n' "$BASE_ERR" | grep -E '^Error' || true)"
                        usr_errs="$(printf '%s\n' "$USR_ERR" | grep -E '^Error' || true)"
                        if [[ -n "$base_errs" ]]; then
                            usr_errs="$(printf '%s\n' "$usr_errs" | grep -Fvx -f <(printf '%s\n' "$base_errs") || true)"
                        fi
                        if [[ -n "$usr_errs" ]]; then
                            ab_found=true
                            report FAIL "${U_NAME}'s startup files raise errors at every session start" \
                                "$(printf '%s\n' "$usr_errs" | head -n 2)"
                        fi
                        if [[ "$(bk MAIN_API)" != "unset" && "$(uk MAIN_API)" == "unset" ]]; then
                            ab_found=true
                            report CRIT "The system profile MAIN block does not run in ${U_NAME}'s sessions" \
                                "BIOME_WORKER_MODE in ~/.Renviron, or ~/.Rprofile removes .biome_env — no guards, no tools"
                        fi
                        bg="$(bk GUARDS)"; ug="$(uk GUARDS)"
                        if is_num "$bg" && is_num "$ug" && [[ "$ug" -lt "$bg" ]]; then
                            ab_found=true
                            report FAIL "Memory guards lost in ${U_NAME}'s sessions (${bg} → ${ug})" \
                                "BIOME_DISABLE_FRAGMENTS in-session: $(uk BIOME_DISABLE_FRAGMENTS)"
                        fi
                        btd="$(bk TEMPDIR)"; utd="$(uk TEMPDIR)"
                        if [[ -n "$btd" && -n "$utd" && "$(dirname -- "$btd")" != "$(dirname -- "$utd")" ]]; then
                            ab_found=true
                            report FAIL "tempdir() moved by ${U_NAME}'s startup files: ${utd}" "system baseline: ${btd}"
                        fi
                        if [[ "$(bk LIBPATH1)" != "$(uk LIBPATH1)" ]]; then
                            ab_found=true
                            report WARN ".libPaths()[1] changed by ${U_NAME}'s startup files: $(uk LIBPATH1)" "system baseline: $(bk LIBPATH1)"
                        fi
                        thr_diff=""
                        for tv in OMP_NUM_THREADS OPENBLAS_NUM_THREADS MKL_NUM_THREADS MC_CORES; do
                            if [[ "$(bk "$tv")" != "$(uk "$tv")" ]]; then thr_diff="${thr_diff}${tv} $(bk "$tv")→$(uk "$tv"); "; fi
                        done
                        if [[ -n "$thr_diff" ]]; then
                            ab_found=true
                            report WARN "Thread settings changed by ${U_NAME}'s startup files" "${thr_diff% ; }"
                        fi
                        if [[ "$(bk DEVICE)" != "$(uk DEVICE)" ]]; then
                            ab_found=true
                            report WARN "options(device) changed by ${U_NAME}'s startup files: $(bk DEVICE) → $(uk DEVICE)" \
                                "in RStudio anything but RStudioGD bypasses the Plots pane"
                        fi
                        ub="$(uk BOOT_ERRORS)"; uf="$(uk FRAG_ERRORS)"
                        if { is_num "$ub" && [[ "$ub" -gt "$(bk BOOT_ERRORS)" ]]; } || { is_num "$uf" && [[ "$uf" -gt "$(bk FRAG_ERRORS)" ]]; }; then
                            ab_found=true
                            report FAIL "The system profile logs errors only in ${U_NAME}'s sessions" \
                                "$(uk BOOT_ERROR_TEXT) $(uk FRAG_ERROR_TEXT)"
                        fi
                        if [[ "$ab_found" != true ]]; then
                            report PASS "No divergence from the system baseline" "guards, MAIN, tempdir, .libPaths, threads, device, errors"
                        fi
                        ;;
                esac
            fi
        fi
    fi
fi
SCOPE="system"

# =============================================================================
# 8. WORKER SURVIVAL (PSOCK fast-path)  [RUNTIME]
# =============================================================================

section "8. Worker Survival (PSOCK fast-path)"

if [[ "$RUNTIME_TIER" != true ]]; then
    report WARN "Worker survival test SKIPPED" "$RUNTIME_SKIP_REASON"
elif [[ ! -f "$RPROFILE" ]]; then
    report WARN "Worker survival test SKIPPED" "no Rprofile.site to load"
else
    run_r_probe worker "${WORK_DIR}/worker_probe.R"
    w_state="$(probe_outcome "$R_OUT" "$R_RC")"
    if [[ "$w_state" == "ok" && "$(kvof "$R_OUT" WORKER_ALIVE)" == "TRUE" ]]; then
        report PASS "Worker R survives the profile load (fast path; v10 top-level return() bug absent)"
        if [[ "$(kvof "$R_OUT" MAIN_RAN)" == "TRUE" ]]; then
            report WARN "Worker ran the full MAIN block" "BIOME_WORKER_MODE=1 did not select the fast path — every PSOCK worker pays the full profile cost"
        fi
        w_boot="$(kvof "$R_OUT" BOOT_ERRORS)"
        if is_num "$w_boot" && [[ "$w_boot" -gt 0 ]]; then
            report WARN "Worker fast path logged ${w_boot} boot error(s)" "see /tmp/biome_boot_errors_<pid>.log on a real worker"
        fi
    elif [[ "$w_state" == "timeout" ]]; then
        report CRIT "Worker R TIMED OUT during profile load (${PROBE_TIMEOUT_S}s)" \
            "every PSOCK cluster start would hang — check the dispatcher worker fast path (§-1) and 30_psock_factory.R"
    else
        report CRIT "Worker R ABORTED during profile load (rc=${R_RC})" \
            "top-level return() (v10.0 bug) or a fatal error in the fast path — stderr: $(one_line "$R_ERR" 140) — FIX: option 3"
    fi
fi

# =============================================================================
# 9. RUNTIME PROFILE LOAD  [RUNTIME — from the section-4 probe]
# =============================================================================

section "9. Runtime Profile Load"

if runtime_gate "Profile load check"; then
    if [[ "$(sk DISPATCHER_ENTERED)" == "TRUE" ]]; then
        report PASS "Dispatcher entered (biome.profile.loaded set)" "set before MAIN runs — MAIN completion is checked separately"
    else
        report CRIT "Dispatcher did NOT run" "Rprofile.site was not sourced at startup"
    fi
    if [[ "$(sk MAIN_VERSION)" != "unset" && "$(sk MAIN_API)" != "unset" ]]; then
        report PASS "Dispatcher MAIN block completed" ".biome_env VERSION=$(sk MAIN_VERSION) API_VERSION=$(sk MAIN_API)"
    else
        report CRIT "Dispatcher MAIN block did NOT complete" \
            ".biome_env VERSION=$(sk MAIN_VERSION) API_VERSION=$(sk MAIN_API) — guards/tools are absent in every session"
    fi
    main_timers="$(sk MAIN_TIMERS)"
    if is_num "$main_timers" && [[ "$main_timers" -gt 0 ]]; then
        report PASS "MAIN ran to completion (${main_timers} section timers recorded)"
    else
        report WARN "No section timers recorded (timers=${main_timers:-unset})" "MAIN may have aborted partway"
    fi

    frag_errors="$(sk FRAG_ERRORS)"
    if ! is_num "$frag_errors"; then
        report FAIL "Fragment error count unavailable" "probe returned '${frag_errors}' — cannot confirm fragments loaded cleanly"
    elif [[ "$frag_errors" -gt 0 ]]; then
        report FAIL "Fragment load errors: ${frag_errors}" \
            "$(sk FRAG_ERROR_TEXT) — each failing fragment is skipped in every session"
    else
        report PASS "No fragment load errors"
    fi

    boot_errors="$(sk BOOT_ERRORS)"
    if ! is_num "$boot_errors"; then
        report FAIL "Boot error count unavailable" "probe returned '${boot_errors}'"
    elif [[ "$boot_errors" -gt 0 ]]; then
        boot_text="$(sk BOOT_ERROR_TEXT)"
        boot_fix="the dispatcher swallowed early-stage errors (logged to /tmp/biome_boot_errors_<pid>.log)"
        if [[ "$boot_text" == *"sys_log_internal_file"* ]]; then
            boot_fix="sys_log cannot append to ${log_path:-its log file} as ${PROBE_USER}: every session leaves a /tmp/biome_boot_errors_<pid>.log — FIX: sudo chmod 666 ${log_path:-<LOG_FILE>} (see 1f)"
        fi
        report FAIL "Dispatcher boot errors: ${boot_errors}" "$(printf '%s\n' "$boot_text" "$boot_fix")"
    else
        report PASS "No dispatcher boot errors"
    fi

    frag_loader="$(sk FRAG_LOADER)"
    case "$frag_loader" in
        *"bundle fast-path"*) report PASS "Fragment loader: byte-compiled bundle fast-path" "$frag_loader" ;;
        *"legacy path"*)
            if [[ "$BUNDLE_FRESH" == true ]]; then
                report WARN "Fragment loader fell back to per-fragment loading although the bundle is fresh" \
                    "bundle.Rc failed to load (see fragment errors: [bundle_load]) — FIX: option 3 rebuilds it"
            else
                report PASS "Fragment loader: per-fragment (no fresh bundle — see section 3)"
            fi ;;
        unknown|"") ;;
        *) report WARN "Fragment loader: ${frag_loader}" ;;
    esac

    startup_ms="$(sk STARTUP_MS)"
    if is_num "$startup_ms"; then
        if [[ "$startup_ms" -gt 5000 ]]; then
            slow_hint="check NFS latency and the bundle state (section 3)"
            if [[ "$BUNDLE_FRESH" == true ]]; then slow_hint="the bundle is fresh (section 3), so the fragment loader is not the cause"; fi
            if is_num "${base_ms:-}" && [[ $(( base_ms * 2 )) -lt "$startup_ms" ]]; then
                slow_hint="$(printf '%s\n' "${slow_hint}; the interactive baseline (section 7) then started in ${base_ms} ms." \
                    "A slow FIRST start with fast later ones is a cold NFS / page cache: run the check again." \
                    "If it repeats, time the sections: sudo su - ${U_NAME:-<user>} -c 'BIOME_DEBUG=1 Rscript -e 0'")"
            fi
            report WARN "Profile load slow: ${startup_ms}ms (>5s)" "$slow_hint"
        elif [[ "$startup_ms" -gt 2000 ]]; then
            report WARN "Profile load moderate: ${startup_ms}ms (>2s)" "a fresh bundle (section 3) usually brings this under 1s"
        else
            report PASS "Profile load fast: ${startup_ms}ms"
        fi
    fi
fi

# =============================================================================
# 10. FORENSIC TOOLS (HC-13 L0/L1)
# =============================================================================

section "10. Forensic Tools"

if [[ -f "$RPROFILE_MINIMAL" ]]; then
    report PASS "Minimal forensic profile deployed: ${RPROFILE_MINIMAL}"
else
    report WARN "Minimal forensic profile missing: ${RPROFILE_MINIMAL}" "FIX: sudo bash scripts/50_setup_nodes.sh (option H)"
fi
if [[ -x "${BIOME_HEALTH_ROOT}/usr/local/bin/r_minimal" ]] || { [[ -z "$BIOME_HEALTH_ROOT" ]] && command -v r_minimal &>/dev/null; }; then
    report PASS "r_minimal launcher available"
else
    report WARN "r_minimal launcher not found" "HC-13 L0/L1 triage (99_diagnose_user_script.sh L1) unavailable — FIX: option H"
fi

# =============================================================================
# ACTION PLAN (--user) · SUMMARY · --fix --commit
# =============================================================================

if [[ -n "$U_NAME" ]]; then
    section "Action plan for ${U_NAME}"
    if [[ ${#FIX_KIND[@]} -eq 0 && ${#MANUAL[@]} -eq 0 ]]; then
        printf "  nothing to do — no user-level problems found\n"
    else
        for i in "${!FIX_KIND[@]}"; do
            needs=""
            if [[ "${FIX_ROOT[$i]}" == "yes" && "$EUID_NOW" -ne 0 ]]; then needs=" (needs root)"; fi
            printf "  [auto]   %d. %s%s\n" "$((i + 1))" "${FIX_DESC[$i]}" "$needs"
        done
        for m in ${MANUAL[@]+"${MANUAL[@]}"}; do printf "  [manual] %s\n" "$m"; done
        if [[ ${#FIX_KIND[@]} -gt 0 ]]; then
            if [[ "$MODE" == "check" ]]; then
                printf "\n  Preview: sudo bash %s --user %s --fix\n  Apply:   sudo bash %s --user %s --fix --commit\n" "$SELF" "$U_NAME" "$SELF" "$U_NAME"
            elif [[ "$COMMIT" != true ]]; then
                printf "\n  %sDRY-RUN%s — nothing was changed. Apply: sudo bash %s --user %s --fix --commit\n" "$YELLOW" "$NC" "$SELF" "$U_NAME"
            fi
        fi
    fi
fi

bar="════════════════════════════════════════════════════════════"
printf "\n%s\n" "${BOLD}${bar}${NC}"
printf "%s\n" "${BOLD}  SUMMARY: ${CHECKS_RUN} checks | $((CHECKS_RUN - FAILURES - WARNINGS)) PASS | ${FAILURES} FAIL | ${WARNINGS} WARN${NC}"
printf "%s\n" "${BOLD}${bar}${NC}"

if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
    printf "\n%s\n" "${BOLD}Failed checks:${NC}"
    for fc in "${FAILED_CHECKS[@]}"; do printf "  %s•%s %s\n" "$RED" "$NC" "$fc"; done
fi
if [[ "$RUNTIME_TIER" != true ]]; then
    printf "\n%sNOTE:%s runtime tier (4, 5d, 6-runtime, 7g, 8, 9) did not run — %s\n" "$YELLOW" "$NC" "$RUNTIME_SKIP_REASON"
    printf "  Re-run as root with --user <name> to probe the R runtime as that user.\n"
fi

VERDICT_RC=0
printf "\n"
if [[ "$FAILURES" -gt 0 ]]; then
    VERDICT_RC=1
    printf "%s\n" "${RED}  VERDICT: CRITICAL — the profile is broken or degraded (${SYS_FAILS} system, ${USER_FAILS} user-level)${NC}"
elif [[ "$WARNINGS" -gt 0 ]]; then
    VERDICT_RC=2
    printf "%s\n" "${YELLOW}  VERDICT: WARNINGS — functional but suboptimal${NC}"
else
    printf "%s\n" "${GREEN}  VERDICT: ALL CLEAR — profile healthy${NC}"
fi
if [[ "$SYS_FAILS" -gt 0 ]]; then
    printf "  System: apply the FIX lines above (50_setup_nodes.sh option 3 = Rprofile/Renviron/fragments/bundle,\n"
    printf "          2 = BLAS + CORETYPE wrappers, L = local R libs, H = r_minimal). New sessions load a redeployed\n"
    printf "          profile at once; running ones keep the old profile until Session → Restart R.\n"
    printf "          No rstudio-server restart is needed (it interrupts every active session).\n"
fi
if [[ -n "$U_NAME" && $((USER_FAILS + USER_WARNS)) -gt 0 && "$MODE" == "check" ]]; then
    printf "  User %s: see the action plan above.\n" "$U_NAME"
fi

if [[ "$MODE" == "fix" && "$COMMIT" == true ]]; then
    if [[ ${#FIX_KIND[@]} -eq 0 ]]; then
        printf "\n  No automatic fixes to apply for %s.\n" "$U_NAME"
        exit "$VERDICT_RC"
    fi
    require_runuser_for_changes
    confirm_or_exit "Apply ${#FIX_KIND[@]} change(s) to ${U_NAME}'s files?"
    apply_fix_plan
    vrc=0
    run_verification || vrc=$?
    if [[ "$FIX_FAILED" -gt 0 ]]; then
        printf "\n%s%d change(s) could not be applied — see ✗ above.%s\n" "$RED" "$FIX_FAILED" "$NC"
        exit 4
    fi
    exit "$vrc"
fi

exit "$VERDICT_RC"
