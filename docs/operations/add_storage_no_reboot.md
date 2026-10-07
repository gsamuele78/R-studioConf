<!-- docs/operations/add_storage_no_reboot.md -->
---
title: "Add /Rtmp Storage Without Reboot"
audience: operator
status: current
tier: T1
source_path: docs/operations/add_storage_no_reboot.md
last_verified: 2026-10-06
---

# Add `/Rtmp` Storage Without Reboot

Use this procedure for a newly attached Proxmox SCSI/VirtIO disk on an Ubuntu 24.04 T1 host. `/Rtmp` is local ext4 scratch for R, terra, NIMBLE and compilers. It must not be tmpfs, NFS, or mounted `noexec`.

## 1. Identify the new device

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS
for scan in /sys/class/scsi_host/host*/scan; do printf '%s\n' '- - -' | sudo tee "$scan" >/dev/null; done
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS
```

Set the device only after comparing size and existing mounts:

```bash
DEV=/dev/sdX
lsblk "$DEV"
sudo wipefs --no-act "$DEV"
```

> Selecting the wrong device destroys data. Stop unless `DEV` is the newly attached, unused disk.

## 2. Partition and format

```bash
sudo parted "$DEV" --script mklabel gpt
sudo parted "$DEV" --script mkpart primary ext4 0% 100%
sudo partprobe "$DEV"
PART=${DEV}1
sudo mkfs.ext4 -m 0 -L RtmpVol "$PART"
```

For NVMe or virtio names ending in a digit, set `PART` explicitly (for example `/dev/nvme1n1p1`).

## 3. Mount now

```bash
sudo install -d -m 1777 /Rtmp
sudo mount -t ext4 -o rw,nosuid,nodev,noatime "$PART" /Rtmp
sudo chmod 1777 /Rtmp
findmnt -no SOURCE,FSTYPE,OPTIONS /Rtmp
df -hT /Rtmp
```

Required observations: filesystem `ext4`; `rw,nosuid,nodev,noatime`; no `noexec`; mode `1777`.

## 4. Persist by UUID

```bash
UUID=$(sudo blkid -s UUID -o value "$PART")
printf 'UUID=%s /Rtmp ext4 rw,nosuid,nodev,noatime 0 2\n' "$UUID" | sudo tee -a /etc/fstab
sudo findmnt --verify --verbose
```

Do not unmount an active `/Rtmp`. Validate the entry without disrupting sessions:

```bash
sudo mount -a
findmnt -no SOURCE,FSTYPE,OPTIONS /Rtmp
sudo -u nobody bash -c 'f=$(mktemp /Rtmp/rtmp-check.XXXXXX); printf ok >"$f"; rm -f "$f"'
```

## 5. R verification

New R sessions read `TMPDIR=/Rtmp` from `/etc/R/Renviron.site`.

```bash
sudo bash scripts/99_check_rprofile_health.sh --static-only
R --no-save -e 'cat(tempdir(), "\n")'
```

Do not restart `rstudio-server` merely to mount the disk. Existing sessions retain their existing `tempdir()`; schedule a controlled restart only if they must be terminated and recreated.

## Expansion of an existing `/Rtmp` disk

After enlarging the virtual disk in Proxmox, rescan, grow partition 1, then grow ext4 online:

```bash
DEV=/dev/sdX
for scan in /sys/class/scsi_host/host*/scan; do printf '%s\n' '- - -' | sudo tee "$scan" >/dev/null; done
sudo growpart "$DEV" 1
sudo resize2fs "${DEV}1"
df -hT /Rtmp
```

**Unverified:** the repository does not define the Proxmox device name or storage backend. Confirm `DEV` and whether partition 1 is the deployed layout before running destructive commands.
