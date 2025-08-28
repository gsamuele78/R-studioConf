#!/bin/bash

# =====================================================================
# Proxmox VM Performance Optimizer (Interactive, Robust)
# ---------------------------------------------------------------------
# Description:
#   Interactive script for optimizing a KVM VM in Proxmox 8.x.
#   Auto-detects hardware, prompts for sysadmin confirmation, and applies
#   safe Ceph/Proxmox optimizations. Uses new workspace layout.
# ---------------------------------------------------------------------
# Usage:
#   Run from scripts/: ./optimize_vm.sh
# ---------------------------------------------------------------------
# Requirements:
#   - Run on Proxmox host
#   - 'jq' utility for parsing VM config (apt-get install jq)
# =====================================================================

set -euo pipefail

# --- Interactive VM Selection ---
CONFIG_FILE="../config/optimize_vm.conf"
TEMPLATE_DIR="../templates"
GUEST_SCRIPT_TEMPLATE="$TEMPLATE_DIR/guest_optimizer.sh.tpl"

if ! command -v qm &>/dev/null; then
    echo "Error: 'qm' command not found. Please run this script on a Proxmox host." >&2
    exit 1
fi

echo "Available VMs:"
qm list
read -r -p "Enter VMID to optimize: " VMID
if ! qm config "$VMID" &>/dev/null; then
    echo "Error: VM with ID $VMID does not exist." >&2
    exit 1
fi

# --- Auto-detect VM Hardware ---
CORES=$(qm config "$VMID" | grep -E '^cores:' | awk '{print $2}')
RAM=$(qm config "$VMID" | grep -E '^memory:' | awk '{print $2}')
DISK_LINE=$(qm config "$VMID" | grep -E '^(scsi|virtio|ide|sata)[0-9]:')
TARGET_DISK=$(echo "$DISK_LINE" | cut -d':' -f1)
STORAGE_DETAILS=$(echo "$DISK_LINE" | cut -d'=' -f2)
NETWORK_LINE=$(qm config "$VMID" | grep -E '^net[0-9]:')
NETWORK_BRIDGE=$(echo "$NETWORK_LINE" | grep -o 'bridge=[^,]*' | cut -d'=' -f2)

# --- Sysadmin Override ---
echo "Detected VM Hardware:"
echo "  VMID: $VMID"
echo "  vCPU cores: $CORES"
echo "  RAM: $RAM MB"
echo "  Disk: $TARGET_DISK ($STORAGE_DETAILS)"
echo "  Network bridge: $NETWORK_BRIDGE"
read -r -p "Override any value? (y/N): " override
if [[ "$override" =~ ^[Yy]$ ]]; then
    read -r -p "vCPU cores [$CORES]: " input_cores; CORES=${input_cores:-$CORES}
    read -r -p "RAM [$RAM]: " input_ram; RAM=${input_ram:-$RAM}
    read -r -p "Disk [$TARGET_DISK]: " input_disk; TARGET_DISK=${input_disk:-$TARGET_DISK}
    read -r -p "Disk details [$STORAGE_DETAILS]: " input_storage; STORAGE_DETAILS=${input_storage:-$STORAGE_DETAILS}
    read -r -p "Network bridge [$NETWORK_BRIDGE]: " input_bridge; NETWORK_BRIDGE=${input_bridge:-$NETWORK_BRIDGE}
fi

echo "\nReady to apply the following optimizations to VM $VMID:"
echo "  CPU: host, NUMA (if multi-socket)"
echo "  Memory: balloon=0"
echo "  Disk: $TARGET_DISK, aio=native, cache=writethrough, iothreads=1"
echo "  Network: $NETWORK_BRIDGE, queues=$CORES"
read -r -p "Proceed? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted by user. No changes made."
    exit 0
fi

# --- CPU Optimizations ---
echo "INFO: Applying CPU optimizations..."
qm set "$VMID" --cpu host
if [[ $(lscpu | grep "Socket(s)" | awk '{print $2}') -gt 1 ]]; then
    echo "INFO: Multi-socket host detected. Enabling NUMA."
    qm set "$VMID" --numa 1
else
    echo "INFO: Single-socket host. Skipping NUMA."
    qm set "$VMID" --numa 0
fi

# --- Memory Optimizations ---
echo "INFO: Applying memory optimizations..."
qm set "$VMID" --balloon 0

# --- Disk Optimizations ---
echo "INFO: Applying disk optimizations for $TARGET_DISK..."
qm set "$VMID" --"$TARGET_DISK" "$STORAGE_DETAILS,aio=native,cache=writethrough,iothreads=1"

# --- Network Optimizations ---
echo "INFO: Applying network optimizations..."
NET_MODEL=$(echo "$NETWORK_LINE" | cut -d',' -f1)
qm set "$VMID" --net0 "$NET_MODEL,bridge=$NETWORK_BRIDGE,queues=$CORES"

# --- Guest Agent Communication ---
if [[ -f "$GUEST_SCRIPT_TEMPLATE" ]]; then
    GUEST_SCRIPT_DEST="/tmp/guest_optimizer.sh"
    echo "INFO: A template for a guest-side script was found at '$GUEST_SCRIPT_TEMPLATE'."
    echo "INFO: This script should be copied to and executed inside the VM to apply OS-level tunings."
    echo "INFO: Example using QEMU Guest Agent (ensure it's installed and running in the VM):"
    echo "  qm guest cmd $VMID file-write '$GUEST_SCRIPT_TEMPLATE' '$GUEST_SCRIPT_DEST'"
    echo "  qm guest exec $VMID -- chmod +x '$GUEST_SCRIPT_DEST'"
    echo "  qm guest exec $VMID -- sh -c '$GUEST_SCRIPT_DEST'"
else
    echo "WARNING: Guest script template not found at '$GUEST_SCRIPT_TEMPLATE'."
fi

echo "INFO: VM optimization script completed."
echo "INFO: A reboot of the VM is recommended for all settings to take effect."
