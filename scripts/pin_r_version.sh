#!/usr/bin/env bash
# scripts/pin_r_version.sh
#
# This script allows a sysadmin to pin the system R version using apt preferences.
# It provides a stable default but allows for custom version selection.
#
# Paradigm: Pessimistic System Engineering — assume failure, fail fast.
# Ethos: Honest > optimistic. Pessimistic defaults.

set -euo pipefail

# --- Configuration ---
readonly APT_PREFERENCES_FILE="/etc/apt/preferences.d/r-base"
readonly R_PACKAGES="r-base r-base-core r-base-dev r-recommended r-cran-*"
readonly DEFAULT_R_VERSION="4.6.0" # Example stable version, adjust as needed based on system state

# --- Helper Functions ---

# Function to display messages with color
log() {
    local color="$1"
    local message="$2"
    case "$color" in
        "info") echo -e "\\033[34mINFO: $message\\033[0m" ;;
        "success") echo -e "\\033[32mSUCCESS: $message\\033[0m" ;;
        "warning") echo -e "\\033[33mWARNING: $message\\033[0m" ;;
        "error") echo -e "\\033[31mERROR: $message\\033[0m" >&2 ;;
        *) echo "$message" ;;
    esac
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to get available R versions (basic check)
get_available_r_versions() {
    if command_exists apt-get; then
        log "info" "Checking available R versions via apt..."
        # Attempt to get versions, filter for common R base packages
        apt-cache madison r-base | grep -oP '(?<=version ).*(?=-)' | sort -V | uniq
    else
        log "warning" "apt-get not found. Cannot list available R versions. Please provide the exact version manually."
        echo "" # Return empty if apt-get is not available
    fi
}

# --- Main Script Logic ---

log "info" "Starting R version pinning script."

# Check for root privileges
if [[ "$(id -u)" -ne 0 ]]; then
    log "error" "This script must be run as root or with sudo."
    exit 1
fi

# Check for essential commands
if ! command_exists tee || ! command_exists apt-get || ! command_exists apt-cache || ! command_exists grep || ! command_exists sort || ! command_exists uniq; then
    log "error" "Required commands (tee, apt-get, apt-cache, grep, sort, uniq) not found. Please ensure they are installed."
    exit 1
fi

# Get available versions to help sysadmin
log "info" "Attempting to list available R versions..."
AVAILABLE_VERSIONS=$(get_available_r_versions)

if [[ -n "$AVAILABLE_VERSIONS" ]]; then
    log "info" "Available R versions found:"
    echo "$AVAILABLE_VERSIONS" | sed 's/^/  /'
    log "info" "You can select one of the above, or enter a custom version string (e.g., '4.6.0-1.2404.0')."
else
    log "warning" "Could not automatically determine available R versions. Please provide the exact version string manually."
fi

# Prompt for R version
read -rp "Enter the R version to pin (e.g., '$DEFAULT_R_VERSION' or a specific version from above): " R_VERSION_TO_PIN

if [[ -z "$R_VERSION_TO_PIN" ]]; then
    log "error" "R version cannot be empty. Exiting."
    exit 1
fi

# Construct the pin version string for apt preferences
# We use a wildcard '*' to match patch versions if the user provides a major.minor.patch
# Example: if user enters '4.6.0', we'll pin '4.6.0*'
PIN_VERSION_STRING="${R_VERSION_TO_PIN}*"
log "info" "Selected R version to pin: '$R_VERSION_TO_PIN' (will be pinned as '$PIN_VERSION_STRING')."

# Create the APT preferences file
log "info" "Creating APT preferences file at '$APT_PREFERENCES_FILE'..."
cat <<EOF | sudo tee "$APT_PREFERENCES_FILE" > /dev/null
# Pinning R packages to a specific version for stability
# Managed by scripts/pin_r_version.sh
Package: $R_PACKAGES
Pin: version $PIN_VERSION_STRING
Pin-Priority: 1001
EOF

log "success" "APT preferences file created successfully."

# Update apt cache and verify
log "info" "Running 'sudo apt update' to refresh package lists..."
sudo apt update

log "info" "Verifying R version pinning with 'apt-cache policy r-base'..."
sudo apt-cache policy r-base

log "success" "R version pinning script completed."
log "info" "To unpin R versions, remove the file: sudo rm $APT_PREFERENCES_FILE"
log "info" "Then run: sudo apt update && sudo apt install --only-upgrade r-base r-base-core r-base-dev r-recommended"
log "info" "To hold packages instead of pinning (less granular): sudo apt-mark hold $R_PACKAGES"
log "info" "To unhold: sudo apt-mark unhold $R_PACKAGES"