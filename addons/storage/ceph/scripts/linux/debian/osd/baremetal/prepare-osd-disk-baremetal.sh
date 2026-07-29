#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# prepare-osd-disk-baremetal.sh  -  Debian (12/13) variant
#
# Prepares a RAW, unformatted, unpartitioned physical disk on a BARE-METAL OSD host so that
# cephadm / ceph-volume can consume the whole device for a Bluestore OSD.
#
# A physical disk cannot be "created" from software, so the target device MUST be an existing,
# empty disk that is passed EXPLICITLY as an argument (safety: this script wipes the device).
# The script validates the device, refuses to touch the OS/root disk or any disk that is in use,
# then removes every partition table / filesystem signature so the device becomes raw.
#
# Arguments:
#   $1 - Target block device to prepare, e.g. /dev/sdb (REQUIRED, whole disk - not a partition)
#
# WARNING: All data on the target device is destroyed.

set -uo pipefail

DEVICE="${1:-}"

log_info() {
    echo "[CephOsdDisk] $1"
}

log_error() {
    echo "[CephOsdDisk] ERROR: $1" >&2
}

log_info "Preparing a raw OSD disk on this bare-metal host"

if [ -z "$DEVICE" ]; then
    log_error "Missing required target device argument. Pass the whole disk to prepare, e.g. /dev/sdb."
    log_error "Usage: prepare-osd-disk-baremetal.sh <device>"
    exit 1
fi

# ---------------------------------------------------------------------------
# Validation - refuse anything that is not a safe, empty, whole disk.
# ---------------------------------------------------------------------------

if [ ! -b "$DEVICE" ]; then
    log_error "'$DEVICE' is not a block device."
    exit 1
fi

# Must be a whole disk, not a partition (TYPE=disk, not part/lvm/etc.).
DEV_TYPE="$(lsblk -dn -o TYPE "$DEVICE" 2>/dev/null | head -n1 | tr -d '[:space:]')"
if [ "$DEV_TYPE" != "disk" ]; then
    log_error "'$DEVICE' is of type '$DEV_TYPE'; a whole disk (TYPE=disk) is required, not a partition."
    exit 1
fi

# Determine the OS/root disk and never touch it.
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null)"
ROOT_DISK=""
if [ -n "$ROOT_SRC" ]; then
    ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 | tr -d '[:space:]')"
fi
DEV_BASENAME="$(basename "$DEVICE")"
if [ -n "$ROOT_DISK" ] && [ "$ROOT_DISK" = "$DEVICE" ]; then
    log_error "'$DEVICE' is the OS/root disk. Refusing to wipe it."
    exit 1
fi

# Refuse if any partition of the disk is currently mounted.
MOUNTED="$(lsblk -nr -o MOUNTPOINT "$DEVICE" 2>/dev/null | grep -v '^$' || true)"
if [ -n "$MOUNTED" ]; then
    log_error "'$DEVICE' (or a partition of it) is currently mounted at: $(echo "$MOUNTED" | tr '\n' ' ')"
    log_error "Unmount it first, or choose a different, unused disk."
    exit 1
fi

# Refuse if the disk is claimed by LVM / mdraid / a mapper (has holders).
HOLDERS="$(ls "/sys/block/$DEV_BASENAME/holders" 2>/dev/null || true)"
if [ -n "$HOLDERS" ]; then
    log_error "'$DEVICE' is in use by another subsystem (LVM/mdraid/device-mapper holders: $HOLDERS)."
    exit 1
fi

# Refuse if the disk (or a partition of it) is an active swap device (OS swap).
SWAP_HIT="$(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep -E "^${DEVICE}([0-9]+|p[0-9]+)?$" || true)"
if [ -n "$SWAP_HIT" ]; then
    log_error "'$DEVICE' (or a partition of it) is an active swap device: $(echo "$SWAP_HIT" | tr '\n' ' ')"
    log_error "This is part of the operating system. Refusing to wipe it."
    exit 1
fi

# Warn (but continue) if the disk still carries a partition table or filesystem - it will be wiped.
EXISTING_SIG="$(lsblk -nr -o FSTYPE,PARTTYPENAME "$DEVICE" 2>/dev/null | grep -v '^[[:space:]]*$' || true)"
if [ -n "$EXISTING_SIG" ]; then
    log_info "'$DEVICE' currently has partitions/filesystem signatures - they will be erased."
fi

log_info "Selected disk '$DEVICE' (size: $(lsblk -dn -o SIZE "$DEVICE" 2>/dev/null | tr -d '[:space:]'), model: $(lsblk -dn -o MODEL "$DEVICE" 2>/dev/null | sed 's/[[:space:]]\+$//'))"

# ---------------------------------------------------------------------------
# Wipe the device to a raw, unformatted, unpartitioned state.
# ---------------------------------------------------------------------------

log_info "Wiping filesystem / partition-table signatures from '$DEVICE'..."
sudo wipefs -a "$DEVICE" >/dev/null 2>&1 || true

# Zap both GPT copies and the MBR if sgdisk is available; otherwise zero the head/tail manually.
if command -v sgdisk >/dev/null 2>&1; then
    sudo sgdisk --zap-all "$DEVICE" >/dev/null 2>&1 || true
else
    DEV_SECTORS="$(blockdev --getsz "$DEVICE" 2>/dev/null || echo 0)"
    sudo dd if=/dev/zero of="$DEVICE" bs=1M count=16 conv=fsync >/dev/null 2>&1 || true
    if [ "$DEV_SECTORS" -gt 0 ] 2>/dev/null; then
        # Zero the last ~16 MiB to remove a secondary GPT header (32768 sectors of 512 bytes).
        SEEK_SECTORS=$(( DEV_SECTORS - 32768 ))
        if [ "$SEEK_SECTORS" -gt 0 ]; then
            sudo dd if=/dev/zero of="$DEVICE" bs=512 seek="$SEEK_SECTORS" count=32768 conv=fsync >/dev/null 2>&1 || true
        fi
    fi
fi

# Best-effort discard (SSDs/thin) - ignored on devices that do not support it.
sudo blkdiscard -f "$DEVICE" >/dev/null 2>&1 || true

# Re-read the partition table so the kernel/udev see the now-empty device.
sudo partprobe "$DEVICE" >/dev/null 2>&1 || true
sudo udevadm settle >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Verify the device is now raw (no filesystem, no partitions).
# ---------------------------------------------------------------------------

REMAINING_FS="$(sudo blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)"
REMAINING_PARTS="$(lsblk -nr -o NAME "$DEVICE" 2>/dev/null | grep -v "^$DEV_BASENAME$" || true)"
if [ -n "$REMAINING_FS" ] || [ -n "$REMAINING_PARTS" ]; then
    log_error "'$DEVICE' still reports a filesystem/partitions after wiping (fs='$REMAINING_FS', parts='$(echo "$REMAINING_PARTS" | tr '\n' ' ')')."
    exit 1
fi

log_info "Disk '$DEVICE' is now raw, unformatted and unpartitioned - ready to be consumed as a Ceph OSD."
echo "K2S_CEPH_OSD_DISK=${DEVICE}"
echo "K2S_CEPH_OSD_DISK_READY=1"
exit 0
