#!/bin/bash

# ==============================================================================
# Proxmox VM Performance Optimizer
#
# Description:
# This script applies performance optimizations to a specific KVM virtual machine
# in a Proxmox 8.x environment. It configures CPU, memory, disk, and network
# settings for high-performance workloads like R-Studio Server on Ceph storage.
#
# The script is designed to be idempotent (re-runnable).
#
# Usage:
# 1. Fill out the variables in 'conf/optimize_vm.conf'.
# 2. Run the script from the project root: ./optimize_vm.sh
#
# Requirements:
# - Run on the Proxmox host.
# - 'jq' utility for parsing VM configuration (apt-get install jq).
# - A corresponding configuration file.
# ==============================================================================

# --- Strict Mode ---
set -euo pipefail

# --- Load Configuration ---
CONFIG_FILE="conf/optimize_vm.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Configuration file not found at '$CONFIG_FILE'" >&2
  exit 1
fi
# shellcheck source=conf/optimize_vm.conf
source "$CONFIG_FILE"

echo "INFO: Starting VM optimization for VMID ${VMID}..."

# --- Validation ---
if ! command -v qm &> /dev/null; then
    echo "Error: 'qm' command not found. Please run this script on a Proxmox host." >&2
    exit 1
fi

if ! qm config "${VMID}" &> /dev/null; then
    echo "Error: VM with ID ${VMID} does not exist." >&2
    exit 1
fi

# --- CPU Optimizations ---
echo "INFO: Applying CPU optimizations..."
# Set CPU type to 'host' to pass through all host CPU flags and features.
# This is generally superior to a specific model like x86-64-v4 as it ensures
# maximum compatibility and performance.
qm set "${VMID}" --cpu host

# Enable NUMA if the host has multiple physical CPU sockets.
# This helps the guest OS make NUMA-aware scheduling decisions.
# Assumes the VM's core/socket topology is already correctly configured.
if [[ $(lscpu | grep "Socket(s)" | awk '{print $2}') -gt 1 ]]; then
    echo "INFO: Multi-socket host detected. Enabling NUMA."
    qm set "${VMID}" --numa 1
else
    echo "INFO: Single-socket host. Skipping NUMA."
    qm set "${VMID}" --numa 0
fi

# --- Memory Optimizations ---
echo "INFO: Applying memory optimizations..."
# Disable memory ballooning for stable performance. With 256GB of RAM,
# we don't want the host reclaiming memory from this high-performance VM.
qm set "${VMID}" --balloon 0

# --- Disk Optimizations ---
echo "INFO: Applying disk optimizations for ${TARGET_DISK}..."
# Get current disk configuration to preserve disk size and format.
DISK_CONFIG=$(qm config "${VMID}" | grep "^${TARGET_DISK}:")
STORAGE_DETAILS=$(echo "$DISK_CONFIG" | cut -d'=' -f2)

# Set cache to 'writethrough' - a safe and performant option for Ceph,
# as it ensures data is written to the cluster before acknowledging the write.
# 'writeback' is faster but carries a risk of data loss on host failure if not
# carefully managed.
# aio=native is the modern equivalent for 'io_uring' or 'threads' for async I/O.
# iothreads=1 enables a dedicated I/O processing thread.
qm set "${VMID}" --"${TARGET_DISK}" "${STORAGE_DETAILS},aio=native,cache=writethrough,iothreads=1"

# --- Network Optimizations ---
echo "INFO: Applying network optimizations..."
# Get current network configuration to preserve MAC address and model.
# This assumes the primary network interface is 'net0'.
NET_CONFIG=$(qm config "${VMID}" --current | jq -r '.net0')
NET_MODEL=$(echo "$NET_CONFIG" | cut -d',' -f1)

# Enable multi-queue for the VirtIO network interface.
# The number of queues should ideally match the number of vCPUs to allow
# parallel processing of network packets, significantly improving throughput.
qm set "${VMID}" --net0 "${NET_MODEL},bridge=${NETWORK_BRIDGE},queues=${CORES}"

# --- Guest Agent Communication ---
echo "INFO: Preparing guest-side optimization script..."
if [[ -f "$GUEST_SCRIPT_TEMPLATE" ]]; then
    GUEST_SCRIPT_DEST="/tmp/guest_optimizer.sh"
    echo "INFO: A template for a guest-side script was found at '$GUEST_SCRIPT_TEMPLATE'."
    echo "INFO: This script should be copied to and executed inside the VM to apply OS-level tunings."
    echo "INFO: Example using QEMU Guest Agent (ensure it's installed and running in the VM):"
    echo
    echo "  # 1. Copy the script to the VM:"
    echo "  qm guest cmd ${VMID} file-write '${GUEST_SCRIPT_TEMPLATE}' '${GUEST_SCRIPT_DEST}'"
    echo
    echo "  # 2. Make it executable and run it:"
    echo "  qm guest exec ${VMID} -- chmod +x '${GUEST_SCRIPT_DEST}'"
    echo "  qm guest exec ${VMID} -- sh -c '${GUEST_SCRIPT_DEST}'"
    echo
else
    echo "WARNING: Guest script template not found at '$GUEST_SCRIPT_TEMPLATE'."
fi

echo "INFO: VM optimization script completed."
echo "INFO: A reboot of the VM is recommended for all settings to take effect."
