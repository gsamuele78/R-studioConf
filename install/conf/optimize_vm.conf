# Configuration for Proxmox VM Performance Optimization Script

# The numeric ID of the VM you want to optimize.
VMID="100" # Example: 100

# The number of vCPU cores assigned to the VM.
# This is used for setting the number of network queues.
CORES="16"

# The name of the storage pool where the VM disk resides.
# Used to re-apply disk settings correctly.
# Example: 'local-zfs' or 'ceph-storage'
STORAGE_POOL="ceph-storage"

# The name of the virtual disk you are targeting for optimization.
# Usually 'scsi0' or 'virtio0'. Check your VM hardware tab.
TARGET_DISK="scsi0"

# The bridge your VM is connected to.
# Usually 'vmbr0'. Check your VM hardware tab.
NETWORK_BRIDGE="vmbr0"

# (Optional) Path to the guest optimization script template.
GUEST_SCRIPT_TEMPLATE="templates/guest_optimizer.sh.tpl"
