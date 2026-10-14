#!/usr/bin/env bash
set -uo pipefail
# tests/fleet_status_test.sh
# scripts/fleet_status.sh (fleet view) + hu_installer_stamp (installer release stamp).
# ssh is a stub that runs the remote command locally inside a per-host fake root;
# `sudo -n` is replaced by `env`. Never touches /etc or a real host.
# Run: bash tests/fleet_status_test.sh  (on a committed, clean checkout for the SAME CODE case)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUT="${REPO}/scripts/fleet_status.sh"

FAILS=0
ok() { printf '  PASS  %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$1"; then ok "$2"; else no "$2"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hosts"

# ssh stub: ssh -o .. -o .. HOST CMD  → run CMD with HU_ROOT=$T/hosts/HOST.
cat > "$T/bin/ssh" <<STUB
#!/usr/bin/env bash
while [[ "\$1" == -o ]]; do shift 2; done
host="\$1"; cmd="\$2"
[[ -d "$T/hosts/\$host" ]] || { echo "ssh: connect to host \$host port 22: Connection refused" >&2; exit 255; }
export HU_ROOT="$T/hosts/\$host" HU_NO_SYSLOG=1 HU_SKIP_ROOT_CHECK=1 LOG_FILE="$T/cu.log"
cmd="\${cmd//\/etc\/biome-calc/\$HU_ROOT/etc/biome-calc}"
exec bash -c "\$cmd"
STUB
chmod +x "$T/bin/ssh"

# A host deployed by the installer from this checkout: rendered rprofile + bundle + stamp.
deploy_host() {
    local h="$1"
    mkdir -p "$T/hosts/$h"
    (
        export LOG_FILE="$T/cu.log" HU_ROOT="$T/hosts/$h" HU_NO_SYSLOG=1
        # shellcheck source=../lib/common_utils.sh disable=SC1091
        source "${REPO}/lib/common_utils.sh" >/dev/null 2>&1
        # shellcheck source=../lib/render_rprofile.sh disable=SC1091
        source "${REPO}/lib/render_rprofile.sh"
        # shellcheck source=../lib/host_update.sh disable=SC1091
        source "${REPO}/lib/host_update.sh"
        # shellcheck disable=SC1091
        source "${REPO}/config/setup_nodes.vars.conf"
        # shellcheck disable=SC1091
        [[ -f "${REPO}/config/site/setup_nodes.site.vars.conf" ]] && source "${REPO}/config/site/setup_nodes.site.vars.conf"
        [[ -z "${BIOME_HOST}" ]] && BIOME_HOST="$(hostname)"
        rprofile_render_tree "${REPO}/templates/Rprofile_site.R.template" "$HU_ROOT"
        mkdir -p "$HU_ROOT/etc/R/Rprofile_site.d/.compiled"
        rprofile_manifest "$HU_ROOT/etc/R/Rprofile_site.d" > "$HU_ROOT/etc/R/Rprofile_site.d/.compiled/manifest.txt"
        echo bundle > "$HU_ROOT/etc/R/Rprofile_site.d/.compiled/bundle.Rc"
        hu_installer_stamp "${REPO}" rprofile "50_setup_nodes.sh:Rprofile_site.R.template" 2>/dev/null
    )
}
deploy_host calc01
deploy_host calc02
printf '# fleet\ncalc01\ncalc02 %s\n' "${REPO}" > "$T/hosts.txt"

# shellcheck disable=SC2034  # OUT/RC read inside eval'd check strings
run() { OUT="$(FLEET_SSH_BIN="$T/bin/ssh" FLEET_SUDO="env" FLEET_REPO_PATH="${REPO}" \
               bash "$SUT" "$T/hosts.txt" --component rprofile 2>&1)"; RC=$?; }
has() { grep -qF -- "$1" <<< "$OUT"; }

echo "== 1. Installer stamp"
check 'jq -e ".components.rprofile.via == \"50_setup_nodes.sh:Rprofile_site.R.template\" and .components.rprofile.journal == \"\"" "$T/hosts/calc01/etc/biome-calc/release.json" >/dev/null' \
      "release.json written by the installer, with via and no journal"

echo "== 2. Two hosts deployed from the same checkout"
run
if [[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no -- . ':(exclude)config' 2>/dev/null)" ]]; then
    check '[[ $RC -eq 0 ]] && has "SAME CODE"' "same commit, plan 0 on both: SAME CODE, exit 0 (got $RC)"
else
    check '[[ $RC -eq 10 ]] && has "dirty checkout"' "dirty working tree is reported, never SAME CODE (got $RC)"
fi
check 'has "via 50_setup_nodes.sh"' "last recorded deploy shown per host"

echo "== 3. A hand-edited fragment on one host"
printf '# hotfix by hand\n' >> "$T/hosts/calc02/etc/R/Rprofile_site.d/60_safe_setwd.R"
run
check '[[ $RC -eq 10 ]] && has "DIFFERENT"' "drift on one host: DIFFERENT, exit 10 (got $RC)"
check 'grep -E "^calc02 .* 1 \(rprofile:1\)" <<< "$OUT" >/dev/null' "calc02 shows 1 change (the fragment; bundle manifest still matches the release)"
check 'grep -E "^calc01 .* 0 \(rprofile:0\)" <<< "$OUT" >/dev/null' "calc01 still 0"

echo "== 4. An unreachable host and a host without update_host.sh"
printf 'calc03\ncalc01 /nonexistent/R-studioConf\n' >> "$T/hosts.txt"
run
check '[[ $RC -eq 1 ]] && has "NOT VERIFIED"' "unchecked hosts: NOT VERIFIED, exit 1 (got $RC)"
check 'has "UNREACHABLE"' "unreachable host named"
check 'has "no update_host.sh at /nonexistent/R-studioConf"' "missing tool on the host named"

echo
if (( FAILS )); then echo "fleet_status_test: ${FAILS} FAILED"; exit 1; fi
echo "fleet_status_test: all checks passed"
