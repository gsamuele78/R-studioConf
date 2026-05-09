#!/usr/bin/env bash
# scripts/tools/check_installed_R_Package.sh
# Thin wrapper around check_installed_R_Package.R (HC-03 compliant).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec Rscript "${SCRIPT_DIR}/check_installed_R_Package.R" "$@"
