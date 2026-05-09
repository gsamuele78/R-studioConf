#!/bin/bash
# scripts/r_minimal.sh — BIOME-CALC minimal-profile launcher (HC-13 L0/L1 tool)
# ==============================================================================
# Deployed to /usr/local/bin/r_minimal by scripts/50_setup_nodes.sh.
# Launches R (or Rscript via $0 detection) with R_PROFILE_USER pointing at
# the bare-bones forensic profile in /etc/R/Rprofile_minimal.R, leaving the
# normal /etc/R/Rprofile.site untouched on disk.
#
# Usage:
#   r_minimal                              # interactive R, minimal profile
#   r_minimal -e 'biome_diag()'            # one-shot R command
#   r_minimal_rscript user.R [args...]     # batch Rscript, minimal profile
#
# Per HC-13: this tool exists so a sysadmin can prove a hang reproduces under
# pure R — disambiguating a system/profile bug from a user-script bug WITHOUT
# editing user code.
# ==============================================================================
set -euo pipefail

PROFILE="/etc/R/Rprofile_minimal.R"

if [[ ! -f "$PROFILE" ]]; then
    echo "ERROR: $PROFILE missing — run scripts/50_setup_nodes.sh to deploy" >&2
    exit 1
fi

# Decide R vs Rscript by basename of $0 (so a single script + symlink works).
self="$(basename -- "${0:-r_minimal}")"
case "$self" in
    *rscript*|*Rscript*) BIN="Rscript" ;;
    *)                   BIN="R"       ;;
esac

# Strip any inherited Rprofile.site that might leak into the env. We override
# R_PROFILE_USER (per-user profile) — site profile is loaded separately by R,
# but with --no-site-file we suppress it for true isolation.
exec env \
    R_PROFILE_USER="$PROFILE" \
    BIOME_MINIMAL=1 \
    "$BIN" --no-site-file "$@"
