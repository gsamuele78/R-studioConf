# Dynamically Add and Configure `/Rtmp` Storage (Proxmox/Ubuntu)

This guide details the procedure for deploying a newly attached SCSI virtual disk from Proxmox to an Ubuntu 24.04 VM as the dedicated high-performance `/Rtmp` volume, **without rebooting the VM**.

This is optimized for RStudio Server workloads (including heavy NIMBLE MCMC compilation and large spatial matrix computations).

---

## 1. Detect the New Disk (No Reboot)

When you attach a new virtual disk via the Proxmox UI (e.g., using VirtIO SCSI), Ubuntu typically picks it up automatically. If it doesn't, you can force the SCSI bus to rescan.

Check currently visible disks:
```bash
lsblk
```
*(Look for a new, unpartitioned disk, typically `/dev/sdb` or `/dev/sdc`. Note the exact device name. We will refer to it as `/dev/sdX` below.)*

If the disk is **not** visible, trigger a rescan:
```bash
for host in /sys/class/scsi_host/host*/scan; do echo "- - -" | sudo tee $host; done

# Verify it appeared
lsblk
```

---

## 2. Partition the Disk

We will create a single GPT partition spanning the entire disk. 

> [!WARNING]
> **Caution:** Replace `/dev/sdX` with your actual device name (e.g., `/dev/sdb`). Selecting the wrong drive will destroy existing data.

Run the `parted` commands to format the disk:
```bash
# Create a GPT partition table
sudo parted /dev/sdX --script mklabel gpt

# Create a single primary partition using 100% of the drive
sudo parted /dev/sdX --script mkpart primary ext4 0% 100%
```

Verify the partition was created (you should now see `/dev/sdX1`):
```bash
lsblk /dev/sdX
```

---

## 3. Format with ext4 (Optimized for Temp)

For `/Rtmp`, we want maximum space availability. Since this is non-system, temporary storage, we will set the root-reserved block percentage to `0` (`-m 0`) to free up space.

```bash
sudo mkfs.ext4 -m 0 -L RtmpVol /dev/sdX1
```

---

## 4. Prepare Mount Point and Temporary Mount

RStudio needs to compile C++ code (like NIMBLE models) inside its temporary directories. Therefore, we **must not** use the `noexec` flag. However, we should use `nodev`, `nosuid`, and `noatime` (to avoid write amplification on read operations).

```bash
# Create the target directory
sudo mkdir -p /Rtmp

# Mount the drive with performance/security flags
sudo mount -t ext4 -o rw,nosuid,nodev,noatime /dev/sdX1 /Rtmp

# IMPORTANT: Set permissions to function as a public tmp directory
# The sticky bit (1) ensures users can only delete their own files
sudo chmod 1777 /Rtmp
```

---

## 5. Persist the Mount (`/etc/fstab`)

To ensure the disk mounts automatically on future VM reboots, we need to add it to the `/etc/fstab` file using its unique UUID.

Find the UUID of your new partition:
```bash
sudo blkid /dev/sdX1
```
*Look for `UUID="xxxxxxx-xxxx-xxxx..."`*

Backup the current `fstab`:
```bash
sudo cp /etc/fstab /etc/fstab.backup
```

Append the new mount record to `/etc/fstab`. Open `/etc/fstab` in an editor (`sudo nano /etc/fstab`) or append it directly:

```bash
echo "UUID=YOUR-COPIED-UUID-HERE /Rtmp ext4 defaults,rw,nosuid,nodev,noatime 0 2" | sudo tee -a /etc/fstab
```

Verify the `fstab` entry works by unmounting and mounting all filesystems (this confirms there are no syntax errors before a reboot!):
```bash
sudo umount /Rtmp
sudo mount -a
```

Verify it mounted correctly:
```bash
df -h | grep /Rtmp
```

## 6. Restart RStudio Server Services (Optional)

If existing sessions were previously pointing to system `/tmp` and need to be routed to `/Rtmp` immediately:

```bash
sudo systemctl restart rstudio-server
```
*(Ensure users have saved their work before doing this!)*
