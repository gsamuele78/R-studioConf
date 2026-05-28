#!/usr/bin/env bash
# scripts/pin_r_version.sh
#
# This script allows a sysadmin to pin the system R version using apt preferences.
# It provides a stable default but allows for custom version selection.
#
# Paradigm: Pessimistic System Engineering — assume failure, fail fast.
# Ethos: Honest > optimistic. Pessimistic defaults.
#
# What this script pins (apt level — Layer 1 anti-drift):
#   r-base, r-base-core, r-base-dev, r-recommended  → pinned to exact R release (e.g. 4.6.0*)
#   r-cran-*                                         → preferred from repo but NOT version-locked
#                                                      (CRAN packages use their own version space)
#
# What this script does NOT cover (Layer 2):
#   Per-project R package library versions → use renv

set -euo pipefail

# --- Path Resolution and Common Utilities ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMON_UTILS="${WORKSPACE_ROOT}/lib/common_utils.sh"
if [[ ! -f "${COMMON_UTILS}" ]]; then
    echo "ERROR: Missing ${COMMON_UTILS}" >&2
    exit 1
fi
# shellcheck source=../lib/common_utils.sh
source "${COMMON_UTILS}"

# --- Configuration ---
VARS_CONF="${WORKSPACE_ROOT}/config/pin_r_version.vars.conf"
if [[ -f "${VARS_CONF}" ]]; then
    # shellcheck source=../config/pin_r_version.vars.conf
    source "${VARS_CONF}"
else
    log "WARN" "Config not found at ${VARS_CONF}. Using hardcoded defaults."
    APT_PREFERENCES_FILE="/etc/apt/preferences.d/r-base"
    # Core R packages only — these share the R version space (e.g. 4.6.0-4.2404.0)
    R_CORE_PACKAGES="r-base r-base-core r-base-dev r-recommended"
    DEFAULT_R_VERSION="4.6.0"
fi

# R_CORE_PACKAGES may come from vars.conf (legacy R_PACKAGES key) or be set above.
# Normalise: if only R_PACKAGES is defined (old conf), map it to R_CORE_PACKAGES.
if [[ -z "${R_CORE_PACKAGES:-}" ]] && [[ -n "${R_PACKAGES:-}" ]]; then
    # Strip r-cran-* from the legacy variable — it cannot be version-pinned to an R release.
    R_CORE_PACKAGES=$(echo "${R_PACKAGES}" | tr ' ' '\n' | grep -v 'r-cran' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    log "WARN" "Migrated legacy R_PACKAGES → R_CORE_PACKAGES (r-cran-* excluded from version pin)."
fi

# --- Helper Functions ---

get_available_r_versions() {
    if command -v apt-cache &>/dev/null; then
        # apt-cache madison output format: "  r-base | 4.6.0-4.2404.0 | https://..."
        # Field 2 (pipe-delimited) is the full version string, e.g. "4.6.0-4.2404.0".
        # Strip the distro suffix to get clean R semver tokens: 4.6.0, 4.5.3, etc.
        apt-cache madison r-base \
            | awk -F'|' '{print $2}' \
            | sed 's/[[:space:]]//g' \
            | grep -oP '^\d+\.\d+\.\d+' \
            | sort -Vu \
            || true
    else
        log "WARN" "apt-cache not found. Cannot list available R versions."
        echo ""
    fi
}

# Validate that a given version string exists in the current apt cache.
# Returns 0 if found, 1 if not.
version_is_available() {
    local version="$1"
    get_available_r_versions | grep -qx "${version}"
}

do_pin_version() {
    local version="$1"
    if [[ -z "$version" ]]; then
        log "ERROR" "R version cannot be empty."
        return 1
    fi

    # Validate format: must be major.minor.patch only
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR" "Invalid version format '${version}'. Expected major.minor.patch (e.g. 4.6.0)."
        return 1
    fi

    # Validate availability in apt cache
    if ! version_is_available "${version}"; then
        log "ERROR" "Version '${version}' not found in apt cache. Run 'apt-get update' and try again."
        log "INFO"  "Available versions:"
        get_available_r_versions | sed 's/^/  /'
        return 1
    fi

    local pin_string="${version}*"
    log "INFO" "Selected R version to pin: '${version}' (APT pin glob: '${pin_string}')."

    # Idempotency check: Don't re-pin if already pinned to the exact requested version
    if [[ -f "$APT_PREFERENCES_FILE" ]]; then
        if grep -q "Pin: version $pin_string" "$APT_PREFERENCES_FILE"; then
            log "INFO" "R packages are already pinned to version $pin_string. No action needed."
            return 0
        fi
    fi

    read -rp "$(echo -e "${YELLOW}WARNING: This will pin R core packages to '${pin_string}'. Continue? (type 'yes'): ${NC}")" confirm
    if [[ "$confirm" != "yes" ]]; then
        log "INFO" "Operation cancelled."
        return 0
    fi

    log "INFO" "Writing APT preferences file at '${APT_PREFERENCES_FILE}'..."
    local tmp_file
    tmp_file=$(mktemp)

    # ── FIX #1 + #2: Correct APT preferences format ─────────────────────────
    # • Each Package: line must be a single name or a valid glob pattern.
    # • r-base/r-base-core/r-base-dev/r-recommended all share the R version
    #   space so they can be pinned to "${version}*" safely.
    # • r-cran-* packages use upstream versioning (e.g. ggplot2 3.5.1) and
    #   CANNOT be version-pinned to an R release string — they get a separate
    #   stanza that expresses repository preference only (priority 500 = default).
    # ─────────────────────────────────────────────────────────────────────────
    cat <<EOF > "$tmp_file"
# APT preferences: pin R core interpreter packages to a specific release.
# Managed by scripts/pin_r_version.sh — do not edit manually.
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Core R interpreter — pinned hard to ${pin_string}
# Pin-Priority 1001 = force this version even over newer available packages.
Package: ${R_CORE_PACKAGES// /
Package: }
Pin: version ${pin_string}
Pin-Priority: 1001

# CRAN package binaries — prefer CRAN repo but do NOT constrain version.
# These packages have their own upstream version numbering (e.g. ggplot2 3.5.1)
# and cannot be matched to an R version glob.
Package: r-cran-*
Pin: release o=CRAN
Pin-Priority: 500
EOF

    # ── FIX #4: Atomic write + correct permissions in one step ───────────────
    # install(1) is atomic and sets owner/mode in a single syscall,
    # avoiding the race and the bogus "rm -f moved-file" cleanup logic.
    # ─────────────────────────────────────────────────────────────────────────
    if ! install -o root -g root -m 644 "$tmp_file" "$APT_PREFERENCES_FILE"; then
        log "ERROR" "Failed to install APT preferences file."
        rm -f "$tmp_file"
        exit 1
    fi
    rm -f "$tmp_file"

    log "INFO" "SUCCESS: APT preferences file created."
    # FIX #7: script already enforces check_root — no sudo needed here
    log "INFO" "Running 'apt-get update' to refresh package lists..."
    run_command "Update apt" "apt-get update"

    log "INFO" "Verifying R version pinning with 'apt-cache policy r-base'..."
    run_command "Verify policy" "apt-cache policy r-base"

    log "INFO" "SUCCESS: R version pinning completed."
}

do_unpin_version() {
    if [[ -f "$APT_PREFERENCES_FILE" ]]; then
        read -rp "$(echo -e "${YELLOW}WARNING: This will remove '${APT_PREFERENCES_FILE}' and unpin R versions. Continue? (type 'yes'): ${NC}")" confirm
        if [[ "$confirm" != "yes" ]]; then
            log "INFO" "Operation cancelled."
            return 0
        fi

        log "INFO" "Removing '${APT_PREFERENCES_FILE}'..."
        run_command "Remove APT preferences" "rm -f ${APT_PREFERENCES_FILE}" || {
            log "ERROR" "Failed to remove APT preferences file."
            exit 1
        }

        # ── FIX #6: run apt-get update BEFORE reporting success ──────────────
        # The unpin is not effective until apt refreshes its policy cache.
        # Reporting success before the update is misleading if the update fails.
        # ─────────────────────────────────────────────────────────────────────
        run_command "Update apt" "apt-get update"
        log "INFO" "SUCCESS: Unpinned R versions."
    else
        log "INFO" "No pinning file found at '${APT_PREFERENCES_FILE}'. Nothing to do."
    fi
}

# --- Main Script Logic ---

check_root

# Interactive menu loop
main_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${GREEN} R Version Pinning Manager${NC}"
        echo -e "${CYAN}============================================================${NC}"
        echo "1. Show available R versions from apt"
        echo "2. Pin to default R version (${DEFAULT_R_VERSION})"
        echo "3. Pin to a custom R version"
        echo "4. Unpin R version"
        echo "5. Check current R pinning status"
        echo "E. Exit"
        echo -e "${CYAN}============================================================${NC}"

        read -rp "Enter choice: " choice

        case "$choice" in
            1)
                log "INFO" "Available R versions in apt cache:"
                get_available_r_versions | sed 's/^/  /'
                ;;
            2)
                # ── FIX #5: verify default is in apt cache before pinning ────
                if ! version_is_available "${DEFAULT_R_VERSION}"; then
                    log "WARN" "Default version ${DEFAULT_R_VERSION} not found in apt cache."
                    log "WARN" "Run 'apt-get update' first, or select option 3 to pin a custom version."
                else
                    do_pin_version "${DEFAULT_R_VERSION}"
                fi
                ;;
            3)
                log "INFO" "Available R versions in apt cache:"
                get_available_r_versions | sed 's/^/  /'
                echo ""
                # ── FIX #8: prompt shows correct format (semver only) ────────
                read -rp "Enter R version to pin — major.minor.patch only (e.g. 4.6.0): " custom_version
                do_pin_version "$custom_version"
                ;;
            4)
                do_unpin_version
                ;;
            5)
                run_command "Check policy" "apt-cache policy r-base"
                ;;
            [Ee])
                log "INFO" "Exiting R Version Pinning Manager."
                break
                ;;
            *)
                log "ERROR" "Invalid choice. Please enter a number 1-5 or E."
                ;;
        esac
    done
}

main_menu