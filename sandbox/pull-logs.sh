#!/bin/bash
# sandbox/pull-logs.sh
# Pulls provisioning logs from the Vagrant Guest to the Host.
set -euo pipefail

HOST=${1:-rstudio-host}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST_DIR="$SCRIPT_DIR/logs/$HOST"
mkdir -p "$DST_DIR"

if ! vagrant status "$HOST" 2>/dev/null | grep -q "running"; then
    echo "Host $HOST is not running."
    exit 0
fi

echo "Pulling logs from $HOST..."
vagrant ssh-config "$HOST" > "$SCRIPT_DIR/ssh_config.tmp"
rsync -avz -e "ssh -F $SCRIPT_DIR/ssh_config.tmp" "$HOST:/workspace/R-studioConf/sandbox/logs/$HOST/" "$DST_DIR/"
rm -f "$SCRIPT_DIR/ssh_config.tmp"
echo "Done."
