#!/bin/sh
# maintenance_entrypoint.sh
# Alpine/Debian lightweight entrypoint to run the BIOME cron jobs

set -e

# Sourced environment variables are kept in the container environment.
# Crond needs them exported explicitly or dumped to /etc/environment
env > /etc/environment

echo "Initializing RStudio Maintenance Sidecar..."

# Ensure log directories exist and have open permissions for scripts to write to
mkdir -p /var/log/r_orphan_cleanup
mkdir -p /var/log/biome_archiver

# Install missing dependencies if Alpine
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash curl jq gettext
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y --no-install-recommends jq gettext-base
fi

# We use busybox crond (Alpine) or system cron (Debian)
echo "Starting crond in foreground..."
if command -v apk >/dev/null 2>&1; then
    exec crond -f -l 2
else
    # Debian/Ubuntu fallback
    exec cron -f
fi
