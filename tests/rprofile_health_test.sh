#!/usr/bin/env bash
set -uo pipefail
# tests/rprofile_health_test.sh
# Regression gate for scripts/99_check_rprofile_health.sh (v2.0).
#
# The Vagrant sandbox is BROKEN, so this is the validation path: build deployed
# trees under mktemp, point the real script at them via BIOME_HEALTH_ROOT, and
# assert on its verdicts with a real R. Two fixture kinds:
#   * synthetic — a small dispatcher reproducing the observable contract
#     (.biome_env, namespace guards tagged 'biome_guard', tools:biome_calc,
#     /tmp/biome_*_errors_<pid>.log, worker fast path, BIOME_DISABLE_FRAGMENTS),
#     so both healthy and broken paths are reachable deterministically;
#   * real render — the ACTUAL templates rendered with lib/common_utils.sh
#     process_template (same key set as 50_setup_nodes.sh), plus a byte-compiled
#     bundle built the same way. Its only deviation from production: the
#     dispatcher's hardcoded fragment dir is pointed at the fixture.
#
# Writes only under a mktemp dir (and removes its own R temp dirs). Never
# touches /etc, /Rtmp, /var/lib or the real home.
# Run: bash tests/rprofile_health_test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUT="${REPO}/scripts/99_check_rprofile_health.sh"

FAILS=0
ok() { printf '  PASS  %s\n' "$1"; }
no() {
    printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1))
    if [[ "${RPROFILE_HEALTH_TEST_DEBUG:-0}" == "1" ]]; then printf '%s\n' "${OUT:-}" | sed 's/^/      | /'; fi
}
check() { if eval "$1"; then ok "$2"; else no "$2"; fi; }

if ! command -v R >/dev/null 2>&1; then
    echo "SKIP: R not available — cannot exercise the checker"
    exit 0
fi
HAVE_JQ=false
if command -v jq >/dev/null 2>&1; then HAVE_JQ=true; fi

TMPROOT="$(mktemp -d)"
FAKE_PID=""
cleanup() {
    if [[ -n "$FAKE_PID" ]]; then kill "$FAKE_PID" 2>/dev/null || true; fi
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

ME="$(id -un)"
MY_UID="$(id -u)"
MY_HOME="$(getent passwd "$ME" | cut -d: -f6)"
export BIOME_HEALTH_PROBE_TIMEOUT_S="${BIOME_HEALTH_PROBE_TIMEOUT_S:-8}"
R_VER_MM="$(R --version | awk '/^R version/ {split($3, v, "."); print v[1] "." v[2]; exit}')"
CFG_VER="$(grep -m1 -E '^RPROFILE_VERSION=' "${REPO}/config/setup_nodes.vars.conf" | cut -d= -f2 | tr -d '"')"

FRAGS=()
while IFS= read -r t; do
    FRAGS+=("$(basename "$t" .template)")
done < <(find "${REPO}/templates/Rprofile_site.d" -maxdepth 1 -name '[0-9][0-9]_*.R.template' | LC_ALL=C sort)
if [[ ${#FRAGS[@]} -eq 0 ]]; then
    echo "SKIP: no fragment templates found — repo layout changed"
    exit 0
fi

litter_count() { find /tmp -maxdepth 1 \( -name 'biome_boot_errors_*.log' -o -name 'biome_frag_errors_*.log' \) -user "$MY_UID" 2>/dev/null | wc -l; }

# ── write_renviron ROOT — Renviron.site as Step 8 writes it (fixture paths) ──
write_renviron() {
    local root="$1" drop="${FX_DROP_RENV_VAR:-}" kv
    {
        printf 'R_LIBS_SITE=/usr/local/lib/R/site-library/:${R_LIBS_SITE}:/usr/lib/R/library\n'
        if [[ "${FX_LIBS_LOCAL_OFF:-0}" == "1" ]]; then
            printf '# Per-user local R library DISABLED (ENABLE_R_LIBS_LOCAL=false in setup_nodes.vars.conf).\n'
        else
            printf 'R_LIBS_USER=/var/lib/biome-Rlibs/%%u/%%v:${HOME}/R/x86_64-pc-linux-gnu-library/%%v\n'
        fi
        for kv in "TMPDIR=${FX_TMPDIR:-$root/Rtmp}" "TMP=$root/Rtmp" "TEMP=$root/Rtmp" "R_TEMPDIR=$root/Rtmp" \
                  "RETICULATE_PYTHON=/opt/r-geospatial/bin/python" "BSPM_SUDO=true" \
                  "FONTCONFIG_PATH=/etc/fonts" "OPENBLAS_NUM_THREADS=1"; do
            if [[ -n "$drop" && "${kv%%=*}" == "$drop" ]]; then continue; fi
            printf '%s\n' "$kv"
        done
        if [[ "${FX_TMPDIR_APPEND:-0}" == "1" ]]; then printf 'TMPDIR="/nfs/home/Rtmp"\n'; fi
    } > "$root/etc/R/Renviron.site"
}

# ── mk_fixture ROOT — synthetic healthy tree, then FX_* knobs break it ─────
mk_fixture() {
    local root="$1" f
    rm -rf "$root"
    mkdir -p "$root"/etc/R/Rprofile_site.d/.compiled "$root"/etc/profile.d "$root"/etc/rstudio \
             "$root"/usr/local/bin "$root"/var/log/biome-log "$root"/Rtmp \
             "$root"/var/lib/biome-Rlibs/"$ME"/"$R_VER_MM" "$root$MY_HOME"
    local frag_dir="$root/etc/R/Rprofile_site.d"
    for f in "${FRAGS[@]}"; do
        if [[ " ${FX_DROP_FRAGS:-} " == *" ${f} "* ]]; then continue; fi
        printf '# fixture fragment %s\ninvisible(NULL)\n' "$f" > "${frag_dir}/${f}"
    done
    if [[ "${FX_DUP_PREFIX:-0}" == "1" ]]; then printf 'invisible(NULL)\n' > "${frag_dir}/45_extra_guard.R"; fi
    if [[ "${FX_UNLOADABLE:-0}" == "1" ]]; then printf 'invisible(NULL)\n' > "${frag_dir}/helpers.R"; fi
    if [[ "${FX_BAD_SYNTAX:-0}" == "1" ]]; then printf 'this is ( not valid R\n' > "${frag_dir}/99_broken.R"; fi

    local rp="$root/etc/R/Rprofile.site"
    {
        printf '# fixture dispatcher\n#   → substituted at deploy via %%%%PLACEHOLDER%%%% (kept in comments, like the real one)\n'
        printf 'LOG_PATH <- "%s"\n' "$root/var/log/biome-log/r_biome_system.log"
        if [[ "${FX_PLACEHOLDER:-0}" == "1" ]]; then printf 'R_HOST <- "%%%%BIOME_HOST%%%%"\n'; fi
        if [[ "${FX_HANG:-0}" == "1" ]]; then printf 'Sys.sleep(999)\n'; fi
        printf 'options(biome.profile.loaded = TRUE)\n'
        printf 'if (!nzchar(Sys.getenv("BIOME_WORKER_MODE"))) {\n'
        if [[ "${FX_MAIN_FAIL:-0}" != "1" ]]; then
            cat <<RDISP
local({
  VERSION <- "${CFG_VER}"
  be <- new.env(parent = emptyenv())
  be\$VERSION <- VERSION
  be\$API_VERSION <- 11L
  be\$shared_env <- new.env(parent = emptyenv())
  be\$shared_env\$timers <- list(sec1 = 0.01, sec2 = 0.02)
  be\$shared_env\$diag_logs <- list(FragLoader = list(status = "DONE",
      msg = "loaded 14 fragments from bundle fast-path (bundle.Rc)"))
  assign(".biome_env", be, envir = .GlobalEnv)
})
Sys.setenv(OMP_NUM_THREADS = "8", OPENBLAS_NUM_THREADS = "8")
RDISP
        fi
        if [[ "${FX_NO_GUARDS:-0}" != "1" ]]; then
            cat <<'RGUARD'
if (!nzchar(Sys.getenv("BIOME_DISABLE_FRAGMENTS"))) local({
  inst <- function(name, ns) {
    e <- asNamespace(ns); f <- get(name, envir = e)
    attr(f, "biome_guard") <- TRUE
    locked <- bindingIsLocked(name, e)
    if (locked) unlockBinding(name, e)
    assign(name, f, envir = e)
    if (locked) lockBinding(name, e)
  }
  for (x in list(c("solve","base"), c("outer","base"), c("expand.grid","base"), c("dist","stats")))
    try(inst(x[1], x[2]), silent = TRUE)
})
RGUARD
        fi
        cat <<'RTOOLS'
try(attach(list(biome_make_cluster = function(...) NULL, biome_future_plan = function(...) NULL,
                status = function(...) NULL), name = "tools:biome_calc", warn.conflicts = FALSE), silent = TRUE)
RTOOLS
        printf 'local({\n  fake <- function(...) list(BLAS = "/usr/lib/x86_64-linux-gnu/openblas-%s/libblas.so.3")\n  e <- asNamespace("utils")\n  if (bindingIsLocked("sessionInfo", e)) unlockBinding("sessionInfo", e)\n  assign("sessionInfo", fake, envir = e)\n})\n' "${FX_BLAS:-serial}"
        if [[ "${FX_FRAG_ERRORS:-0}" == "1" ]]; then
            printf 'cat("[2026-09-23 10:00:00] [45_memory_guards.R] object foo not found\\n", file = file.path("/tmp", sprintf("biome_frag_errors_%%d.log", Sys.getpid())))\n'
        fi
        if [[ "${FX_BOOT_ERRORS:-0}" == "1" ]]; then
            printf 'cat("[2026-09-23 10:00:00] [STAGE: sys_log_internal_file] Error: cannot open the connection\\n", file = file.path("/tmp", sprintf("biome_boot_errors_%%d.log", Sys.getpid())))\n'
        fi
        printf '}\n'
    } > "$rp"

    printf 'fixture-bundle\n' > "${frag_dir}/.compiled/bundle.Rc"
    ( cd "$frag_dir" && find . -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -printf '%f\n' \
        | LC_ALL=C sort | xargs -r -I{} md5sum -- "{}" ) > "${frag_dir}/.compiled/manifest.txt"
    if [[ "${FX_STALE_BUNDLE:-0}" == "1" ]]; then printf '# edited after the bundle was built\n' >> "${frag_dir}/${FRAGS[0]}"; fi

    write_renviron "$root"
    printf '' > "$root/var/log/biome-log/r_biome_system.log"
    chmod 666 "$root/var/log/biome-log/r_biome_system.log"
    if [[ "${FX_LOG_RO:-0}" == "1" ]]; then chmod 644 "$root/var/log/biome-log/r_biome_system.log"; fi
    if [[ "${FX_LOGIN_SCRIPT:-0}" == "1" ]]; then
        printf '#!/bin/bash\n    renviron_settings=(\n        ["R_LIBS_USER"]="\\"${user_r_libs_dir}\\""\n    )\n' \
            > "$root/etc/profile.d/00_rstudio_user_logins.sh"
    fi
    if [[ "${FX_LOGIN_SCRIPT:-0}" == "hotfixed" ]]; then
        printf '#!/bin/bash\n    renviron_settings=(\n        # [hotfix 2026-09-24] R_LIBS_USER entry removed: /etc/R/Renviron.site owns it (fix_login_script_rlibs_inplace.sh)\n    )\n' \
            > "$root/etc/profile.d/00_rstudio_user_logins.sh"
    fi
    printf 'invisible(NULL)\n' > "$root/etc/R/Rprofile_minimal.R"
    printf '#!/bin/sh\n:\n' > "$root/etc/profile.d/biome-coretype.sh"
    printf '#!/bin/sh\n:\n' > "$root/etc/rstudio/rsession-profile"
    printf '#!/bin/sh\n:\n' > "$root/usr/local/bin/r_minimal"
    chmod +x "$root/usr/local/bin/r_minimal"
    mkdir -p "$root/Rtmp/biome_${ME}"
}

# ── run_check [args...] — run the SUT against $FIX (cwd $RUN_CWD) ─────────
OUT=""; RC=0; RUN_CWD="$TMPROOT"
run_check() {
    if OUT="$(cd "$RUN_CWD" && BIOME_HEALTH_ROOT="$FIX" bash "$SUT" "$@" 2>&1 < /dev/null | sed -r 's/\x1b\[[0-9;]*m//g')"; then
        RC=0
    else
        RC=$?
    fi
}
run_check_rc() { run_check "$@"; }
saw()      { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
saw_sev()  { printf '%s\n' "$OUT" | grep -E "^ *${1} +" | grep -qF -- "$2"; }
count_sev(){ printf '%s\n' "$OUT" | grep -cE "^ *${1} " || true; }
after_verify() { printf '%s\n' "$OUT" | sed -n '/VERIFICATION RUN/,$p'; }
before_verify() { printf '%s\n' "$OUT" | sed '/VERIFICATION RUN/,$d'; }
UH() { printf '%s' "$FIX$MY_HOME"; }
md5() { md5sum "$1" | cut -d' ' -f1; }

# shellcheck disable=SC2034,SC2088  # vars are read inside eval'd check strings; "~/" is label text
run_all() {
# =============================================================================
echo "## 1. healthy synthetic fixture (--user ${ME}) — zero FAIL/CRIT, no litter"
# =============================================================================
FIX="$TMPROOT/healthy"; ( unset "${!FX_@}"; mk_fixture "$FIX" )
L0="$(litter_count)"
run_check_rc --user "$ME"
check '[[ "$(count_sev FAIL)" -eq 0 && "$(count_sev CRIT)" -eq 0 ]]' "no FAIL, no CRIT"
if [[ "$(count_sev FAIL)" -ne 0 || "$(count_sev CRIT)" -ne 0 ]]; then printf '%s\n' "$OUT" | grep -E '^ *(FAIL|CRIT) ' -A2 | sed 's/^/        /'; fi
check '[[ "$RC" -eq 0 || "$RC" -eq 2 ]]' "exit code ${RC} in {0,2}"
check 'saw "No unsubstituted %%PLACEHOLDERS%% in code"' "comment-only %%PLACEHOLDER%% is not a CRIT (real-deploy false positive fixed)"
check 'saw "Thread caps set in-session: OMP_NUM_THREADS=8 OPENBLAS_NUM_THREADS=8"' "thread caps > 1 accepted (fragment 20 budget)"
check '! saw "expected 1"' "no false 'OPENBLAS_NUM_THREADS expected 1' FAIL"
check 'saw "Renviron.site reached the session (TMPDIR="' "Renviron.site proven applied via TMPDIR"
check 'saw "tempdir() is on TMPDIR"' "tempdir() placement verified"
for g in solve dist outer expand_grid; do check "saw 'Guard: ${g}() installed'" "guard ${g} detected"; done
check 'saw "Dispatcher MAIN block completed"' "MAIN completion"
check 'saw "No fragment load errors"' "fragment error count"
check 'saw "No dispatcher boot errors"' "boot error log read"
check 'saw "Fragment loader: byte-compiled bundle fast-path"' "loader path reported"
check 'saw "Interactive baseline (system profile only)"' "interactive baseline probe ran"
check 'saw "No divergence from the system baseline"' "A/B probe: no divergence"
check 'saw "sys_log target writable by users"' "sys_log target checked"
check 'saw "nothing to do — no user-level problems found"' "empty action plan"
check '[[ "$(litter_count)" -eq "$L0" ]]' "probes left no /tmp/biome_*_errors_<pid>.log"

echo "## 1b. probes are hermetic: operator env and cwd .Renviron cannot leak in"
BIOME_DISABLE_FRAGMENTS=45 run_check --user "$ME"
check 'saw "Guard: solve() installed"' "exported BIOME_DISABLE_FRAGMENTS does not reach the system probe"
mkdir -p "$TMPROOT/cwd_env"; printf 'BIOME_DISABLE_FRAGMENTS=45\n' > "$TMPROOT/cwd_env/.Renviron"
RUN_CWD="$TMPROOT/cwd_env" run_check --user "$ME"
check 'saw "Guard: solve() installed" && saw "No divergence from the system baseline"' "a .Renviron in the operator cwd does not leak in"

echo "## 1c. BLAS verdicts"
FIX="$TMPROOT/pthread"; ( unset "${!FX_@}"; FX_BLAS=pthread mk_fixture "$FIX" )
run_check_rc --user "$ME"
check 'saw_sev CRIT "Runtime BLAS: pthread"' "pthread BLAS → CRIT"
check '[[ "$RC" -eq 1 ]]' "exit 1 on pthread BLAS"

# =============================================================================
echo "## 2. system runtime regressions"
# =============================================================================
FIX="$TMPROOT/mainfail"; ( unset "${!FX_@}"; FX_MAIN_FAIL=1 FX_NO_GUARDS=1 mk_fixture "$FIX" )
run_check_rc
check 'saw_sev CRIT "Dispatcher MAIN block did NOT complete"' "MAIN abort → CRIT (biome.profile.loaded alone is not success)"
check '[[ "$RC" -eq 1 ]]' "exit 1 on MAIN abort"

FIX="$TMPROOT/hang"; ( unset "${!FX_@}"; FX_HANG=1 mk_fixture "$FIX" )
BIOME_HEALTH_PROBE_TIMEOUT_S=3 run_check_rc
check 'saw_sev CRIT "System profile probe TIMED OUT"' "hanging profile → CRIT timeout"
check '! saw "No fragment load errors"' "no false PASS after a failed probe"
check '! saw "operand expected"' "no raw bash arithmetic error"
check '[[ "$RC" -eq 1 ]]' "exit 1 on hang"

FIX="$TMPROOT/fragerr"; ( unset "${!FX_@}"; FX_FRAG_ERRORS=1 FX_BOOT_ERRORS=1 mk_fixture "$FIX" )
L0="$(litter_count)"
run_check
check 'saw_sev FAIL "Fragment load errors: 1"' "fragment error log → FAIL"
check 'saw_sev FAIL "Dispatcher boot errors: 1" && saw "chmod 666"' "boot error log → FAIL with sys_log hint"
check '[[ "$(litter_count)" -eq "$L0" ]]' "probe deleted the error logs it reported"

# =============================================================================
echo "## 3. static deployment defects"
# =============================================================================
FIX="$TMPROOT/ph"; ( unset "${!FX_@}"; FX_PLACEHOLDER=1 mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev CRIT "Unsubstituted placeholders in dispatcher code: %%BIOME_HOST%%"' "placeholder in CODE → CRIT"
check '! saw "%%PLACEHOLDER%%"' "the comment placeholder is still ignored"

FIX="$TMPROOT/missing"; ( unset "${!FX_@}"; FX_DROP_FRAGS="45_memory_guards.R 05_thread_guard.R" mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev FAIL "Missing fragments: 2"' "missing fragments → FAIL"

FIX="$TMPROOT/dup"; ( unset "${!FX_@}"; FX_DUP_PREFIX=1 FX_UNLOADABLE=1 mk_fixture "$FIX" )
run_check --static-only
check 'saw "Duplicate fragment prefixes: 45"' "duplicate prefix → WARN"
check 'saw "files the dispatcher will NEVER load"' "unloadable helpers.R flagged"

FIX="$TMPROOT/syntax"; ( unset "${!FX_@}"; FX_BAD_SYNTAX=1 mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev CRIT "Fragment syntax errors: 1"' "fragment syntax error → CRIT"

FIX="$TMPROOT/stale"; ( unset "${!FX_@}"; FX_STALE_BUNDLE=1 mk_fixture "$FIX" )
run_check_rc --static-only
check 'saw_sev WARN "Bundle is STALE"' "stale bundle → WARN (dispatcher falls back, still correct)"
check '[[ "$RC" -eq 2 ]]' "stale bundle alone is not CRITICAL (exit 2)"

FIX="$TMPROOT/tmp"; ( unset "${!FX_@}"; FX_TMPDIR=/tmp mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev FAIL "TMPDIR=/tmp"' "TMPDIR=/tmp → FAIL"

FIX="$TMPROOT/append"; ( unset "${!FX_@}"; FX_TMPDIR_APPEND=1 mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev FAIL "TMPDIR=/nfs/home/Rtmp"' "last TMPDIR definition wins (appended NFS value caught)"
check 'saw "defines temp vars more than once: TMPDIR×2" && saw "20_configure_rstudio.sh"' "duplicate definition + second writer named"

FIX="$TMPROOT/dropvar"; ( unset "${!FX_@}"; FX_DROP_RENV_VAR=BSPM_SUDO mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev FAIL "Missing Renviron.site vars: 1"' "missing Renviron var → FAIL"

FIX="$TMPROOT/logro"; ( unset "${!FX_@}"; FX_LOG_RO=1 mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev FAIL "sys_log target not writable by users"' "non-world-writable sys_log target → FAIL"

FIX="$TMPROOT/login"; ( unset "${!FX_@}"; FX_LOGIN_SCRIPT=1 mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev WARN "Login script rewrites R_LIBS_USER" && saw "PROPOSED FIX" && saw "fix_login_script_rlibs_inplace.sh --commit"' \
      "login-script writer conflict → WARN + hotfix as proposed fix"

FIX="$TMPROOT/login_nfs"; ( unset "${!FX_@}"; FX_LOGIN_SCRIPT=1 FX_LIBS_LOCAL_OFF=1 mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev PASS "Per-user local R libs disabled by config" && saw_sev PASS "Login script writes R_LIBS_USER — no effect while local R libs are disabled"' \
      "NFS-only: login script writing R_LIBS_USER → PASS (no effect)"
check 'saw "Before setting ENABLE_R_LIBS_LOCAL=true: sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit"' \
      "NFS-only: enable-order hint names the hotfix"

FIX="$TMPROOT/login_hotfixed"; ( unset "${!FX_@}"; FX_LOGIN_SCRIPT=hotfixed mk_fixture "$FIX" )
run_check --static-only
check 'saw_sev PASS "Login script does not write R_LIBS_USER (fix_login_script_rlibs_inplace.sh applied)"' \
      "hotfixed login script recognised"

# =============================================================================
echo "## 4. per-user static findings (--static-only --user ${ME})"
# =============================================================================
mk_user_mess() {
    local uh; uh="$(UH)"
    printf '# my env\nBIOME_DISABLE_FRAGMENTS=45\nTMPDIR=/tmp\nOPENBLAS_CORETYPE=HASWELL\nOMP_NUM_THREADS=16\nR_LIBS_USER=/home/x/R/x86_64-pc-linux-gnu-library/4.4\nRETICULATE_PYTHON=/nonexistent/python\nKEEP_ME=1\nBIOME_WORKER_MODE=1\n' > "$uh/.Renviron"
    printf 'options(width = 120)\noptions(device = ragg::agg_png)\nif (interactive()) {\n  options(device = "png")\n}\nSys.setenv(OMP_NUM_THREADS = 8)\nsetwd("~")\n' > "$uh/.Rprofile"
    truncate -s 2G "$uh/.RData"
    rm -rf "$FIX/var/lib/biome-Rlibs/${ME}/${R_VER_MM}"; mkdir -p "$FIX/var/lib/biome-Rlibs/${ME}/3.9"
    mkdir -p "$uh/.local/share/rstudio/sessions/active/session-1"; printf 'x\n' > "$uh/.local/share/rstudio/sessions/active/session-1/state"
}
FIX="$TMPROOT/mess"; ( unset "${!FX_@}"; mk_fixture "$FIX" ); mk_user_mess
run_check --static-only --user "$ME"
check 'saw_sev CRIT "~/.Renviron sets BIOME_WORKER_MODE"' ".Renviron BIOME_WORKER_MODE → CRIT"
check 'saw_sev FAIL "~/.Renviron persists operator kill-switches: L2 BIOME_DISABLE_FRAGMENTS=45"' ".Renviron kill-switch → FAIL"
check 'saw_sev FAIL "~/.Renviron moves R temp off"' ".Renviron TMPDIR → FAIL"
check 'saw_sev FAIL "~/.Renviron pins OPENBLAS_CORETYPE"' ".Renviron CORETYPE → FAIL"
check 'saw_sev WARN "~/.Renviron sets static thread counts"' ".Renviron threads → WARN"
check 'saw_sev WARN "~/.Renviron overrides R_LIBS_*"' ".Renviron R_LIBS_* → WARN (reported only)"
check 'saw "[manual] R_LIBS_*" && saw "50_setup_nodes.sh (option 4"' "R_LIBS_* routed to 50_setup_nodes.sh option 4 (decision 1)"
check 'saw_sev WARN "~/.Renviron points at a missing Python interpreter"' ".Renviron dead RETICULATE_PYTHON → WARN"
check 'saw_sev FAIL "~/.Rprofile sets a file-writing graphics device (lines 2-2)"' "top-level options(device=ragg) → FAIL"
check 'saw_sev FAIL "~/.Rprofile sets a file-writing device inside a block (line 4)"' "nested device → FAIL (manual)"
check 'saw_sev WARN "~/.Rprofile sets thread/core counts"' ".Rprofile threads → WARN"
check 'saw_sev WARN "~/.Rprofile calls setwd() at startup"' ".Rprofile setwd → WARN"
check 'saw_sev FAIL "~/.RData (2.0 GiB) is restored at every RStudio login"' "2 GiB .RData + load_workspace default → FAIL"
check 'saw_sev FAIL "No per-user R library for R ${R_VER_MM}; only: 3.9"' "stale-only per-user lib → FAIL"
check 'saw "RStudio session state:"' "RStudio state size reported"
check 'saw "[auto]   " && saw "comment out lines " && saw "set load_workspace=false"' "action plan lists automatic repairs"
check 'printf "%s\n" "$OUT" | grep "comment out lines" | grep -q "lines 9 2 3 4 5 7 of"' "auto comment-out covers lines 9 2 3 4 5 7 — never R_LIBS_USER (line 6)"

FIX="$TMPROOT/rlibs_default"; ( unset "${!FX_@}"; FX_LIBS_LOCAL_OFF=1 FX_LOGIN_SCRIPT=1 mk_fixture "$FIX" )
printf 'R_LIBS_USER="${HOME}/R/x86_64-pc-linux-gnu-library/%%v"\nXDG_DATA_HOME=/x\n' > "$(UH)/.Renviron"
run_check --static-only --user "$ME"
check 'saw_sev PASS "~/.Renviron sets R_LIBS_USER to R'"'"'s own default"' "NFS-only + R_LIBS_USER = R default → PASS"
check '! saw "[manual] R_LIBS_*" && ! saw_sev WARN "overrides R_LIBS_*"' "NFS-only + R default → no warning, no manual action"

FIX="$TMPROOT/rlibs_other"; ( unset "${!FX_@}"; FX_LIBS_LOCAL_OFF=1 mk_fixture "$FIX" )
printf 'R_LIBS_USER=/scratch/mylibs\n' > "$(UH)/.Renviron"
run_check --static-only --user "$ME"
check 'saw_sev WARN "~/.Renviron overrides R_LIBS_*: L1 R_LIBS_USER=/scratch/mylibs" && saw "instead of its default"' \
      "NFS-only + non-default R_LIBS_USER → WARN"
check '! saw "fragment 04 still prepends"' "NFS-only: no fragment-04 claim"

FIX="$TMPROOT/rlibs_login"; ( unset "${!FX_@}"; FX_LOGIN_SCRIPT=1 mk_fixture "$FIX" )
printf 'R_LIBS_USER="%s/R/x86_64-pc-linux-gnu-library/%s"\n' "$MY_HOME" "$R_VER_MM" > "$(UH)/.Renviron"
run_check --static-only --user "$ME"
check 'saw_sev WARN "~/.Renviron overrides R_LIBS_*" && saw "first stop the login script re-adding it: sudo bash scripts/fix_login_script_rlibs_inplace.sh --commit"' \
      "local libs on + login script writer → manual action starts with the hotfix"

FIX="$TMPROOT/parsefail"; ( unset "${!FX_@}"; mk_fixture "$FIX" )
printf 'x <- function( {\n' > "$(UH)/.Rprofile"
run_check --static-only --user "$ME"
check 'saw_sev FAIL "~/.Rprofile does not parse"' ".Rprofile syntax error → FAIL"
check 'saw "[manual] ~/.Rprofile syntax error"' "syntax error is manual-only"

if [[ "$HAVE_JQ" == true ]]; then
    FIX="$TMPROOT/prefs"; ( unset "${!FX_@}"; mk_fixture "$FIX" )
    mkdir -p "$(UH)/.config/rstudio"; printf '{"load_workspace": false}\n' > "$(UH)/.config/rstudio/rstudio-prefs.json"
    printf 'small\n' > "$(UH)/.RData"
    run_check --static-only --user "$ME"
    check 'saw "~/.RData present" && saw "not restored by RStudio"' "load_workspace=false honoured"
    printf '{broken' > "$(UH)/.config/rstudio/rstudio-prefs.json"
    run_check --static-only --user "$ME"
    check 'saw_sev WARN "rstudio-prefs.json is not valid JSON"' "corrupted prefs → WARN"
fi

# =============================================================================
echo "## 5. per-user runtime A/B (system baseline vs the user's own startup files)"
# =============================================================================
FIX="$TMPROOT/ab"
( unset "${!FX_@}"; mk_fixture "$FIX" ); printf 'Sys.sleep(999)\n' > "$(UH)/.Rprofile"
BIOME_HEALTH_PROBE_TIMEOUT_S=4 run_check --user "$ME"
check 'saw_sev CRIT "session start HANGS with their startup files"' "hanging ~/.Rprofile → CRIT (baseline OK)"
check 'saw "Interactive baseline (system profile only)"' "baseline still reported"

( unset "${!FX_@}"; mk_fixture "$FIX" ); printf 'stop("boom-from-rprofile")\n' > "$(UH)/.Rprofile"
run_check --user "$ME"
check 'saw_sev FAIL "startup files raise errors at every session start" && saw "boom-from-rprofile"' "startup error surfaced with its text"

( unset "${!FX_@}"; mk_fixture "$FIX" ); printf 'BIOME_DISABLE_FRAGMENTS=45\n' > "$(UH)/.Renviron"
run_check --user "$ME"
check 'saw_sev FAIL "Memory guards lost in"' "user kill-switch → guards lost (A/B)"
check 'saw "Guard: solve() installed"' "system section still healthy (user file not blamed on fragment 45)"

( unset "${!FX_@}"; mk_fixture "$FIX" ); mkdir -p "$TMPROOT/elsewhere"; printf 'TMPDIR=%s\n' "$TMPROOT/elsewhere" > "$(UH)/.Renviron"
run_check --user "$ME"
check 'saw_sev FAIL "tempdir() moved by"' "user TMPDIR → tempdir moved (A/B)"

( unset "${!FX_@}"; mk_fixture "$FIX" ); printf 'q("no")\n' > "$(UH)/.Rprofile"
run_check --user "$ME"
check 'saw_sev CRIT "R session ends before the prompt"' "q() in ~/.Rprofile → CRIT"

( unset "${!FX_@}"; mk_fixture "$FIX" ); printf 'BIOME_WORKER_MODE=1\n' > "$(UH)/.Renviron"
run_check --user "$ME"
check 'saw_sev CRIT "MAIN block does not run in"' "user BIOME_WORKER_MODE → MAIN lost (A/B)"

# =============================================================================
echo "## 6. --fix: dry-run, refusal, commit, verification, idempotency, rollback"
# =============================================================================
FIX="$TMPROOT/fix"; ( unset "${!FX_@}"; mk_fixture "$FIX" ); mk_user_mess
renv0="$(md5 "$(UH)/.Renviron")"; rprof0="$(md5 "$(UH)/.Rprofile")"
run_check_rc --fix;                          check '[[ "$RC" -eq 3 ]]' "--fix without --user → exit 3"
run_check_rc --user "$ME" --commit;          check '[[ "$RC" -eq 3 ]]' "--commit without a change mode → exit 3"
run_check_rc --user "$ME" --fix --reset-profile; check '[[ "$RC" -eq 3 ]]' "--fix + --reset-profile → exit 3"

run_check --static-only --user "$ME" --fix
check 'saw "DRY-RUN — nothing was changed"' "--fix is a dry-run"
check '[[ "$(md5 "$(UH)/.Renviron")" == "$renv0" && "$(md5 "$(UH)/.Rprofile")" == "$rprof0" ]]' "dry-run left the files untouched"

run_check_rc --static-only --user "$ME" --fix --commit
check '[[ "$RC" -eq 3 ]] && saw "REFUSED"' "--commit without a TTY and without -y → refused (exit 3)"
check '[[ "$(md5 "$(UH)/.Renviron")" == "$renv0" ]]' "refusal changed nothing"

if [[ "$HAVE_JQ" == true ]]; then
    run_check_rc --static-only --user "$ME" --fix --commit -y
    check '[[ "$RC" -ne 4 ]]' "all automatic repairs applied (exit ${RC}, not 4)"
    check 'saw "VERIFICATION RUN"' "checks re-run after the changes"
    uh="$(UH)"
    check 'grep -q "^# \[biome-cleanup .*\] disabled (was: BIOME_DISABLE_FRAGMENTS=45)" "$uh/.Renviron"' ".Renviron kill-switch commented out with the shared marker"
    check 'grep -q "^R_LIBS_USER=" "$uh/.Renviron" && grep -q "^KEEP_ME=1" "$uh/.Renviron"' "R_LIBS_USER and unrelated lines left untouched"
    renv_bak="$(ls "$uh"/.Renviron.bak.* 2>/dev/null | head -1)"
    check '[[ -n "$renv_bak" && "$(md5 "$renv_bak")" == "$renv0" ]]' ".Renviron backup equals the original"
    check 'grep -q "^# \[biome-cleanup .*\] disabled (was: options(device = ragg::agg_png))" "$uh/.Rprofile"' ".Rprofile device statement commented out"
    check 'grep -q "^options(width = 120)" "$uh/.Rprofile"' "other .Rprofile statements intact"
    check 'R --vanilla --no-echo -e "invisible(parse(\"$uh/.Rprofile\"))" >/dev/null 2>&1' ".Rprofile still parses"
    check 'jq -e ".load_workspace == false and .save_workspace == \"never\"" "$uh/.config/rstudio/rstudio-prefs.json" >/dev/null' "prefs set via jq (workspace restore off)"
    check '[[ -d "$FIX/var/lib/biome-Rlibs/${ME}/${R_VER_MM}" ]]' "per-user R library created (Step 7c semantics)"
    check '[[ -f "$uh/.RData" ]]' "~/.RData itself untouched"
    v="$(after_verify)"
    check '! grep -q "persists operator kill-switches" <<< "$v" && ! grep -q "sets a file-writing graphics device (lines" <<< "$v"' "verification: fixed findings are gone"
    check '! grep -q "is restored at every RStudio login" <<< "$v" && ! grep -q "No per-user R library for R" <<< "$v"' "verification: workspace + lib findings gone"
    check 'grep -q "overrides R_LIBS_\*" <<< "$v"' "verification: R_LIBS_* still reported (owned elsewhere)"
    nbak="$(ls "$uh"/.*.bak.* 2>/dev/null | wc -l)"
    run_check_rc --static-only --user "$ME" --fix --commit -y
    check 'saw "No automatic fixes to apply" && [[ "$(ls "$uh"/.*.bak.* 2>/dev/null | wc -l)" -eq "$nbak" ]]' "idempotent: second commit changes nothing"
fi

FIX="$TMPROOT/rollback"; ( unset "${!FX_@}"; mk_fixture "$FIX" )
printf 'options(device =\n  ragg::agg_png); f <- function() {\n  1\n}\n' > "$(UH)/.Rprofile"
rb0="$(md5 "$(UH)/.Rprofile")"
run_check_rc --static-only --user "$ME" --fix --commit -y
check 'saw "REVERTED (backup restored)" && [[ "$RC" -eq 4 ]]' "edit that would break parsing is rolled back (exit 4)"
check '[[ "$(md5 "$(UH)/.Rprofile")" == "$rb0" ]]' ".Rprofile restored byte-for-byte"

# =============================================================================
echo "## 7. --reset-profile / --undo-reset"
# =============================================================================
FIX="$TMPROOT/reset"; ( unset "${!FX_@}"; mk_fixture "$FIX" )
uh="$(UH)"
printf 'options(device = ragg::agg_png)\n' > "$uh/.Rprofile"; printf 'TMPDIR=/tmp\n' > "$uh/.Renviron"; printf 'ws\n' > "$uh/.RData"
mkdir -p "$uh/.local/share/rstudio/sessions/active/s1" "$uh/.config/rstudio"
printf 'state\n' > "$uh/.local/share/rstudio/sessions/active/s1/f"
printf '{"editor_theme": "x"}\n' > "$uh/.config/rstudio/rstudio-prefs.json"
p0="$(md5 "$uh/.Rprofile")"; e0="$(md5 "$uh/.Renviron")"

run_check --user "$ME" --reset-profile
check 'saw "DRY-RUN — nothing was moved" && [[ -f "$uh/.Rprofile" ]]' "--reset-profile is a dry-run"

cp /bin/sleep "$TMPROOT/rsession"; "$TMPROOT/rsession" 60 & FAKE_PID=$!
sleep 0.3
run_check_rc --user "$ME" --reset-profile --commit -y
check '[[ "$RC" -eq 4 ]] && saw "BLOCKED" && [[ -f "$uh/.Rprofile" ]]' "refuses while an rsession runs (exit 4), nothing moved"
kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=""

run_check --static-only --user "$ME" --reset-profile --commit -y
stamp="$(ls "$uh/.biome-profile-quarantine" 2>/dev/null | head -1)"
check '[[ -n "$stamp" && ! -e "$uh/.Rprofile" && ! -e "$uh/.Renviron" && ! -e "$uh/.RData" && ! -e "$uh/.local/share/rstudio" ]]' "startup state moved out of the home"
check '[[ "$(grep -c "^moved" "$uh/.biome-profile-quarantine/$stamp/MANIFEST.txt")" -eq 4 ]]' "MANIFEST lists the 4 moved items"
check '[[ -f "$uh/.config/rstudio/rstudio-prefs.json" ]]' "valid RStudio prefs kept"
check '[[ "$(md5 "$uh/.biome-profile-quarantine/$stamp/.Rprofile")" == "$p0" ]]' "quarantined copy is byte-identical"
check 'saw "VERIFICATION RUN" && saw "No ~/.Rprofile"' "verification run shows a clean profile"

run_check --user "$ME" --undo-reset list
check 'saw "$stamp"' "--undo-reset list shows the stamp"
printf 'new\n' > "$uh/.Rprofile"
run_check_rc --static-only --user "$ME" --undo-reset "$stamp" --commit -y
check '[[ "$RC" -eq 4 ]] && saw "BLOCKED"' "undo refuses to overwrite a recreated file (exit 4)"
rm -f "$uh/.Rprofile"
run_check_rc --static-only --user "$ME" --undo-reset "$stamp" --commit -y
check '[[ "$(md5 "$uh/.Rprofile")" == "$p0" && "$(md5 "$uh/.Renviron")" == "$e0" && -d "$uh/.local/share/rstudio/sessions/active/s1" ]]' "undo restores every item byte-for-byte"
run_check_rc --static-only --user "$ME" --undo-reset "$stamp" --commit -y
check '[[ "$RC" -eq 4 ]] && saw "already restored"' "second undo refused"
run_check_rc --user "$ME" --undo-reset not-a-stamp; check '[[ "$RC" -eq 3 ]]' "malformed stamp → exit 3"

# =============================================================================
echo "## 8. privilege / invocation contract"
# =============================================================================
FIX="$TMPROOT/healthy"
run_check --static-only
check 'saw "runtime tier: OFF"' "--static-only disables the runtime tier"
for s in "Runtime probes SKIPPED" "Runtime BLAS check SKIPPED" "Worker survival test SKIPPED" "Profile load check SKIPPED"; do
    check "saw '$s'" "static-only skips: $s"
done
if [[ "$MY_UID" -eq 0 ]]; then
    run_check
    check 'saw "running as root without --user"' "root without --user refuses the runtime tier"
else
    run_check_rc --user root; check '[[ "$RC" -eq 3 ]] && saw "is not you"' "non-root --user <other> → exit 3 (no identity mixing)"
fi
run_check_rc --user;               check '[[ "$RC" -eq 3 ]]' "--user with no value → exit 3"
run_check_rc --user --static-only; check '[[ "$RC" -eq 3 ]]' "--user swallowing a flag → exit 3"
run_check_rc --nope;               check '[[ "$RC" -eq 3 ]]' "unknown option → exit 3"
run_check_rc --user no_such_user_xyz; check '[[ "$RC" -eq 3 ]]' "unknown username → exit 3"
run_check_rc --help;               check '[[ "$RC" -eq 0 ]]' "--help → exit 0"

# =============================================================================
echo "## 9. static guards against the fixed idioms regressing"
# =============================================================================
check 'grep -q "\"\$R_BIN\" --version" "$SUT" && ! grep -qE "R_VER_MM=.*Rscript -e" "$SUT"' "R version from 'R --version' (no profile load as root)"
check 'grep -q "env -i -C" "$SUT" && grep -q "R_ENVIRON_USER=" "$SUT"' "probes are env -i + R_ENVIRON_USER= hermetic"
check 'grep -q "is_num \"\$frag_errors\"" "$SUT"' "frag_errors numeric-guarded"
check '! grep -qE "head -1 \| cut -d= -f2- \| tr -d" "$SUT"' "first-definition TMPDIR idiom is gone"
check '! grep -nE "sed .*json|json.*sed " "$SUT" | grep -v "^.*#"' "no sed on JSON (HC-12)"

# =============================================================================
echo "## 10. REAL templates rendered with process_template (+ real bundle)"
# =============================================================================
FIX="$TMPROOT/real"
mkdir -p "$FIX"/etc/R/Rprofile_site.d/.compiled "$FIX"/var/log/biome-log "$FIX"/Rtmp "$FIX$MY_HOME" \
         "$FIX"/var/lib/biome-Rlibs/"$ME"/"$R_VER_MM" "$FIX"/etc/biome-calc
render_ok=true
if ! ( export LOG_FILE="$TMPROOT/cu.log"
       # shellcheck source=../lib/common_utils.sh disable=SC1091
       source "${REPO}/lib/common_utils.sh" >/dev/null 2>&1
       render() {
           local out
           process_template "$1" out BIOME_HOST=test-node RPROFILE_VERSION="$CFG_VER" VM_VCORES=4 VM_RAM_GB=8 \
               BIOME_CONTACT=ops@example.org MAX_BLAS_THREADS=4 BIOME_CONF="$FIX/etc/biome-calc" \
               LOG_FILE="$FIX/var/log/biome-log/r_biome_system.log" RAMDISK_GB=0 \
               RSESSION_CONF_PATH="$FIX/etc/rstudio/rsession.conf" TMP_WARN_THRESHOLD_PCT=80 || return 1
           printf '%s' "$out" > "$2"
       }
       render "${REPO}/templates/Rprofile_site.R.template" "$FIX/etc/R/Rprofile.site" || exit 1
       for t in "${REPO}"/templates/Rprofile_site.d/[0-9][0-9]_*.R.template; do
           render "$t" "$FIX/etc/R/Rprofile_site.d/$(basename "$t" .template)" || exit 1
       done ); then
    render_ok=false
fi
if [[ "$render_ok" == true ]]; then
    sed -i "s#\.biome_frag_dir <- \"/etc/R/Rprofile_site.d\"#.biome_frag_dir <- \"$FIX/etc/R/Rprofile_site.d\"#" "$FIX/etc/R/Rprofile.site"
    ( cd "$FIX/etc/R/Rprofile_site.d" && : > "$TMPROOT/bundle.R"
      for f in $(find . -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -printf '%f\n' | LC_ALL=C sort); do
          printf '\n# <<< %s >>>\n' "$f" >> "$TMPROOT/bundle.R"; cat "$f" >> "$TMPROOT/bundle.R"
      done
      find . -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -printf '%f\n' | LC_ALL=C sort | xargs -r -I{} md5sum -- "{}" > .compiled/manifest.txt )
    R --vanilla --no-echo -e "compiler::cmpfile('$TMPROOT/bundle.R', '$FIX/etc/R/Rprofile_site.d/.compiled/bundle.Rc', options = list(optimize = 3L), verbose = FALSE)" >/dev/null 2>&1
    ( FX_TMPDIR="$FIX/Rtmp"; write_renviron "$FIX" )
    : > "$FIX/var/log/biome-log/r_biome_system.log"; chmod 666 "$FIX/var/log/biome-log/r_biome_system.log"

    run_check --static-only
    check '[[ "$(count_sev CRIT)" -eq 0 ]]' "real render: no CRIT (was: false 'Unsubstituted placeholders' CRIT)"
    if [[ "$(count_sev CRIT)" -ne 0 ]]; then printf '%s\n' "$OUT" | grep -E '^ *CRIT ' -A1 | sed 's/^/        /'; fi
    check 'saw "No unsubstituted %%PLACEHOLDERS%% in code" && saw "R syntax valid (parse OK)"' "real render: placeholders + syntax"
    check 'saw "Version match: deployed=${CFG_VER}"' "real render: version matches config"
    check 'saw "All ${#FRAGS[@]} expected fragments present" && saw "All ${#FRAGS[@]} fragments parse successfully"' "real render: fragment chain intact"
    check 'saw "Bundle manifest matches on-disk fragments (FRESH)"' "real render: bundle fresh"

    run_check --user "$ME"
    for g in solve dist outer expand_grid; do check "saw 'Guard: ${g}() installed'" "real profile: guard ${g} detected"; done
    check 'saw "Dispatcher MAIN block completed" && saw "No fragment load errors" && saw "No dispatcher boot errors"' "real profile: loads clean"
    check 'saw "Fragment loader: byte-compiled bundle fast-path"' "real profile: bundle fast-path taken"
    check 'saw "Thread caps set in-session" && ! saw "expected 1"' "real profile: fragment 20 thread budget accepted (was a false FAIL)"
    check 'saw "Worker R survives the profile load"' "real profile: worker fast path survives"
    check 'saw "Renviron.site reached the session" && saw "tempdir() is on TMPDIR"' "real profile: Renviron applied, tempdir on TMPDIR"
    check 'saw "No divergence from the system baseline"' "real profile: A/B clean for an empty home"
else
    no "real render: process_template rendering failed"
fi
}
run_all

echo
if [[ "$FAILS" -eq 0 ]]; then
    echo "ALL RPROFILE-HEALTH TESTS PASSED"
else
    echo "${FAILS} TEST(S) FAILED"
fi
exit "$FAILS"
