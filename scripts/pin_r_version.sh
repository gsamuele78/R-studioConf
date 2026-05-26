#!/usr/bin/env bash
# scripts/pin_r_version.sh
#
# This script allows a sysadmin to pin the system R version using apt preferences.
# It provides a stable default but allows for custom version selection.
#
# Paradigm: Pessimistic System Engineering — assume failure, fail fast.
# Ethos: Honest > optimistic. Pessimistic defaults.

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
    R_PACKAGES="r-base r-base-core r-base-dev r-recommended r-cran-*"
    DEFAULT_R_VERSION="4.6.0"
fi

# --- Helper Functions ---

get_available_r_versions() {
    if command -v apt-get &>/dev/null; then
        # Use || true to prevent pipefail from crashing script if grep finds nothing
        apt-cache madison r-base | grep -oP '(?<=version ).*(?=-)' | sort -V | uniq || true
    else
        log "WARN" "apt-get not found. Cannot list available R versions."
        echo ""
    fi
}

do_pin_version() {
    local version="$1"
    if [[ -z "$version" ]]; then
        log "ERROR" "R version cannot be empty."
        return 1
    fi

    local pin_string="${version}*"
    log "INFO" "Selected R version to pin: '${version}' (will be pinned as '${pin_string}')."

    # Idempotency check: Don't re-pin if already pinned to the exact requested version
    if [[ -f "$APT_PREFERENCES_FILE" ]]; then
        if grep -q "Pin: version $pin_string" "$APT_PREFERENCES_FILE"; then
            log "INFO" "R packages are already pinned to version $pin_string. No action needed."
            return 0
        fi
    fi

    read -rp "$(echo -e "${YELLOW}WARNING: This will pin R packages to '${pin_string}'. Continue? (type 'yes'): ${NC}")" confirm
    if [[ "$confirm" != "yes" ]]; then
        log "INFO" "Operation cancelled."
        return 0
    fi

    log "INFO" "Creating APT preferences file at '${APT_PREFERENCES_FILE}'..."
    local tmp_file
    tmp_file=$(mktemp)
    cat <<EOF > "$tmp_file"
# Pinning R packages to a specific version for stability
# Managed by scripts/pin_r_version.sh
Package: $R_PACKAGES
Pin: version $pin_string
Pin-Priority: 1001
EOF

    # Atomic write and permissions check (HC-10)
    run_command "Install APT preferences" "mv \"$tmp_file\" \"$APT_PREFERENCES_FILE\" && chmod 644 \"$APT_PREFERENCES_FILE\"" || {
        log "ERROR" "Failed to install APT preferences file or set permissions."
        rm -f "$tmp_file"
        exit 1
    }

    log "INFO" "SUCCESS: APT preferences file created."
    log "INFO" "Running 'sudo apt-get update' to refresh package lists..."
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
        
        log "INFO" "SUCCESS: Unpinned R versions."
        run_command "Update apt" "apt-get update"
    else
        log "INFO" "No pinning file found at '${APT_PREFERENCES_FILE}'."
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
                log "INFO" "Available R versions found:"
                get_available_r_versions | sed 's/^/  /'
                ;;
            2)
                do_pin_version "${DEFAULT_R_VERSION}"
                ;;
            3)
                log "INFO" "Available R versions found:"
                get_available_r_versions | sed 's/^/  /'
                echo ""
                read -rp "Enter the custom R version to pin (e.g., 4.6.0-1.2404.0): " custom_version
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