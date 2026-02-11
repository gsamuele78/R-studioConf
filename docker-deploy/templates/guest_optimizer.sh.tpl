#!/bin/bash

# ==============================================================================
# Guest OS Performance Optimizer for R-Studio Server & Nginx
#
# Description:
# This script applies kernel and application-level tunings inside the VM
# to maximize performance for a high-resource R-Studio Server reverse-proxied
# by Nginx.
#
# It should be run with root privileges on a Debian/Ubuntu-based system.
# The script is idempotent and safe to re-run.
# ==============================================================================

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: This script must be run as root." >&2
  exit 1
fi

echo "--- Applying Guest OS Performance Tunings ---"

# --- I/O Scheduler Tuning ---
# For virtual disks, the 'none' scheduler is ideal as it passes I/O requests
# directly to the hypervisor, which handles the actual scheduling on the
# physical storage (Ceph), reducing overhead.
echo "INFO: Configuring I/O scheduler..."
UDEV_RULE_FILE="/etc/udev/rules.d/60-io-scheduler.rules"
echo "ACTION==\"add|change\", KERNEL==\"vd*\", ATTR{queue/scheduler}=\"none\"" > "$UDEV_RULE_FILE"
echo "INFO: Created udev rule for persistent I/O scheduler at '$UDEV_RULE_FILE'."
# Apply immediately without waiting for a reboot
for disk in /sys/block/vd*/queue/scheduler; do
    if [[ -f "$disk" ]]; then
        echo "none" > "$disk"
    fi
done

# --- Kernel, Memory, and Network Tuning (sysctl) ---
# We create a single configuration file to hold all kernel-level tunings.
# This makes them persistent and easy to manage.
echo "INFO: Applying kernel, memory, and network tunings via sysctl..."
SYSCTL_CONF_FILE="/etc/sysctl.d/99-performance-tuning.conf"

# Use a heredoc to write all settings at once.
cat > "$SYSCTL_CONF_FILE" << EOF
# --- Performance Tunings for High-Memory/High-Traffic Server ---

# -- Memory Management --
# Lower swappiness to 10. For a VM with 256GB RAM, we want to use RAM, not swap.
vm.swappiness = 10
# Lower vfs_cache_pressure to keep filesystem metadata (inodes, dentries) in RAM longer.
# This speeds up file access, beneficial for R reading datasets.
vm.vfs_cache_pressure = 50

# -- Network Stack Tuning for High Concurrency --
# Increase max connections in kernel queue. Prevents connection drops under load.
net.core.somaxconn = 16384
# Increase backlog for incoming packets per CPU. Handles traffic bursts.
net.core.netdev_max_backlog = 2048
# Increase TCP SYN queue. Helps mitigate SYN floods and handles many new connections.
net.ipv4.tcp_max_syn_backlog = 2048
# Allow reuse of sockets in TIME-WAIT state. Essential for web servers with
# many short-lived connections.
net.ipv4.tcp_tw_reuse = 1
# Increase the TCP receive buffer size (min, default, max).
net.ipv4.tcp_rmem = 4096 87380 67108864
# Increase the TCP send buffer size (min, default, max).
net.ipv4.tcp_wmem = 4096 65536 67108864

# -- Filesystem Tuning --
# Increase the maximum number of open file descriptors system-wide.
fs.file-max = 2097152
# Increase the inotify watch limit for tools that monitor file changes (like RStudio/Shiny).
fs.inotify.max_user_watches = 524288
EOF

# Apply the sysctl settings immediately
sysctl --system
echo "INFO: Kernel settings applied and made persistent in '$SYSCTL_CONF_FILE'."

# --- File Descriptor Limits ---
# Increase the per-user open file limit, which is separate from the system-wide limit.
# This is crucial for R-Studio and Nginx, as each user session and connection uses file descriptors.
echo "INFO: Increasing user file descriptor limits..."
LIMITS_CONF_FILE="/etc/security/limits.d/99-performance-tuning.conf"
{
  echo "* soft nofile 1048576"
  echo "* hard nofile 1048576"
} > "$LIMITS_CONF_FILE"
echo "INFO: User file descriptor limits set in '$LIMITS_CONF_FILE'."

# --- Nginx Tuning (if installed) ---
if command -v nginx &> /dev/null && [[ -f "/etc/nginx/nginx.conf" ]]; then
    echo "INFO: Nginx detected. Applying performance tunings..."
    NGINX_CONF_FILE="/etc/nginx/nginx.conf"

    # Helper function to set a config value in nginx.conf
    # Arguments: $1 = key, $2 = value
    set_nginx_config() {
        local key="$1"
        local value="$2"
        # If the key exists (commented or not), replace the line.
        if grep -qE "^\s*#?\s*${key}" "${NGINX_CONF_FILE}"; then
            sed -i -E "s/^\s*#?\s*${key}.*/\t${key} ${value};/" "${NGINX_CONF_FILE}"
        # Otherwise, add it after the 'events {' or 'http {' block for context.
        elif [[ "$key" == "worker_connections" ]]; then
             sed -i "/^\s*events\s*{/a \ \t${key} ${value};" "${NGINX_CONF_FILE}"
        else # Add general settings after the 'pid' line.
            sed -i "/^\s*pid/a ${key} ${value};" "${NGINX_CONF_FILE}"
        fi
    }

    # Set worker_processes to 'auto' to match the number of CPU cores (16).
    set_nginx_config "worker_processes" "auto"

    # In the 'events' block...
    # Increase worker_connections. Each worker can handle this many connections.
    set_nginx_config "worker_connections" "8192"
    # Use the most efficient connection processing method on Linux.
    set_nginx_config "use" "epoll"
    # Allow a worker to accept multiple connections at once.
    set_nginx_config "multi_accept" "on"

    echo "INFO: Nginx configuration updated in '$NGINX_CONF_FILE'."
    echo "ACTION: Please review the changes and test the Nginx configuration with 'nginx -t'."
    echo "ACTION: If the test is successful, reload Nginx with 'systemctl reload nginx'."

else
    echo "INFO: Nginx not found, skipping Nginx tuning."
fi

echo ""
echo "--- Guest OS Tuning Complete ---"
echo "A system reboot is recommended to ensure all settings, including udev rules and user limits, are fully applied."
