#!/usr/bin/env bash
# lib/render_rprofile.sh — render the system R profile (step 8 of 50_setup_nodes.sh).
#
# One renderer for the installer (50_setup_nodes.sh step 8) and the in-place
# updater (update_host.sh --component rprofile), so the two cannot drift.
#
#   rprofile_render_file TEMPLATE OUT_FILE
#       process_template with the step 8 key set, written with printf "%s"
#       (no trailing newline: byte-identical with what step 8 always wrote).
#   rprofile_render_tree MAIN_TEMPLATE OUT_ROOT
#       OUT_ROOT/etc/R/Rprofile.site and OUT_ROOT/etc/R/Rprofile_site.d/NN_*.R
#       from MAIN_TEMPLATE and the Rprofile_site.d/ next to it.
#   rprofile_parse_check FILE          R parse(); prints the error, returns 1 on failure.
#   rprofile_manifest FRAG_DIR         the md5 manifest the dispatcher checks.
#   rprofile_build_bundle FRAG_DIR OUT_DIR
#       byte-compiled OUT_DIR/bundle.Rc + OUT_DIR/manifest.txt; returns 1 on failure
#       (the dispatcher then uses the per-fragment loop).
#
# The key values come from the caller's environment (setup_nodes.vars.conf plus
# the optional site override). LOG_FILE in the R profile is the R system log;
# a caller that uses LOG_FILE for its own log passes the R one as RPROFILE_LOG_FILE.
# Requires lib/common_utils.sh (process_template) to be sourced first.
set -euo pipefail

: "${HU_RSCRIPT_BIN:=Rscript}"

rprofile_render_file() {
    local tpl="$1" out="$2" rendered=""
    process_template "${tpl}" rendered \
        BIOME_HOST="${BIOME_HOST}" \
        RPROFILE_VERSION="${RPROFILE_VERSION}" \
        VM_VCORES="${VM_VCORES}" \
        VM_RAM_GB="${VM_RAM_GB}" \
        BIOME_CONTACT="${BIOME_CONTACT}" \
        MAX_BLAS_THREADS="${MAX_BLAS_THREADS}" \
        BIOME_CONF="${BIOME_CONF}" \
        LOG_FILE="${RPROFILE_LOG_FILE:-${LOG_FILE}}" \
        RAMDISK_GB="${RAMDISK_GB}" \
        RSESSION_CONF_PATH="${RSESSION_CONF_PATH}" \
        TMP_WARN_THRESHOLD_PCT="${TMP_WARN_THRESHOLD_PCT:-80}" \
        ENABLE_HOME_QUOTA_VIEW="${ENABLE_HOME_QUOTA_VIEW:-false}" \
        QUOTA_WARN_PCT="${QUOTA_WARN_PCT:-90}" \
        QUOTA_STALE_MIN="${QUOTA_STALE_MIN:-30}" || return 1
    printf "%s" "${rendered}" > "${out}"
}

rprofile_render_tree() {
    local main_tpl="$1" out_root="$2" frag_src tpl
    frag_src="$(dirname "${main_tpl}")/Rprofile_site.d"
    mkdir -p "${out_root}/etc/R/Rprofile_site.d"
    rprofile_render_file "${main_tpl}" "${out_root}/etc/R/Rprofile.site" || return 1
    if [[ -d "${frag_src}" ]]; then
        for tpl in "${frag_src}"/[0-9][0-9]_*.R.template; do
            [[ -e "${tpl}" ]] || continue
            rprofile_render_file "${tpl}" "${out_root}/etc/R/Rprofile_site.d/$(basename "${tpl}" .template)" || return 1
        done
    fi
    # An unreplaced key means the vars file lacks it: stop before anything is deployed.
    # R comment lines are skipped (the dispatcher header documents "%%PLACEHOLDER%%").
    local left
    if left="$(grep -rnE '%%[A-Z][A-Z0-9_]*%%' "${out_root}/etc/R" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"; then
        printf 'rprofile_render_tree: unreplaced placeholders:\n%s\n' "${left}" >&2
        return 1
    fi
}

rprofile_parse_check() {
    local f="$1" out
    out="$("${HU_RSCRIPT_BIN}" --vanilla -e "
tryCatch({parse(file='${f}');cat('PARSE_OK')},
  error=function(e) cat(sprintf('PARSE_FAIL: %s',e\$message)))" 2>&1)" || true
    if grep -q 'PARSE_OK' <<< "${out}"; then return 0; fi
    printf '%s\n' "${out}" >&2
    return 1
}

rprofile_manifest() {
    (
        cd "$1" || exit 1
        find . -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -printf '%f\n' \
            | LC_ALL=C sort \
            | xargs -r -I{} md5sum -- "{}"
    )
}

rprofile_build_bundle() {
    local frag_dir="$1" out_dir="$2" concat f
    mkdir -p "${out_dir}"
    concat="${out_dir}/bundle.R"
    : > "${concat}"
    while IFS= read -r -d '' f; do
        printf '\n# <<< %s >>>\n' "$(basename "$f")" >> "${concat}"
        cat "$f" >> "${concat}"
    done < <(find "${frag_dir}" -maxdepth 1 -type f -name '[0-9][0-9]_*.R' -print0 | sort -z)
    if ! "${HU_RSCRIPT_BIN}" --vanilla -e "
options(warn=2)
tryCatch({
  suppressPackageStartupMessages(library(compiler))
  cmpfile('${concat}', '${out_dir}/bundle.Rc',
          options = list(optimize = 3L), verbose = FALSE)
  cat('BUNDLE_OK\n')
}, error = function(e) {
  cat(sprintf('BUNDLE_FAIL: %s\n', conditionMessage(e)))
  quit(status = 1)
})
" > "${out_dir}/compile.log" 2>&1 || ! grep -q 'BUNDLE_OK' "${out_dir}/compile.log"; then
        return 1
    fi
    rprofile_manifest "${frag_dir}" > "${out_dir}/manifest.txt"
}
