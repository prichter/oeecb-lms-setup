#!/usr/bin/env bash
#
# restore-docker-data-disk.sh
#
# Mounts a PRESERVED data disk (from a previous install) at /mnt/docker
# and re-establishes the same bind-mount layout as setup-docker-data-disk.sh:
#   /mnt/docker/srv-docker         -> /srv/docker
#   /mnt/docker/var-lib-docker     -> /var/lib/docker
#   /mnt/docker/var-lib-containerd -> /var/lib/containerd
#
# This is the RESTORE / DR counterpart to setup-docker-data-disk.sh.
# Use this when the disk already contains data (e.g. testing recovery
# from server corruption where the data disk itself survived / was
# backed up separately) and must NOT be repartitioned or formatted.
#
# NON-DESTRUCTIVE: this script never calls parted, mkfs, or wipefs.
# It only mounts what's already there.
#
# DISK SELECTION: rather than a hardcoded /dev/sdX, this script finds the
# data disk by filesystem LABEL (set by the original setup script). Device
# names like sda/sdb are assigned by enumeration order and can differ
# between VM rebuilds or disk reattachments, so they're not reliable.
#
# RUN THIS BEFORE installing Docker via Ansible — dockerd should find
# /var/lib/docker already populated via the bind mount before it starts.

set -euo pipefail

# --- Config ------------------------------------------------------------
REAL_MOUNT="/mnt/docker"
EXPECTED_FSTYPE="ext4"
EXPECTED_LABEL="docker-data"   # label set by the original setup script

declare -A BIND_MAP=(
  ["srv-docker"]="/srv/docker"
  ["var-lib-docker"]="/var/lib/docker"
  ["var-lib-containerd"]="/var/lib/containerd"
)

# --- Pre-flight checks ---------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Run this as root (sudo)." >&2
  exit 1
fi

for cmd in blkid findmnt udevadm lsblk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required tool: $cmd" >&2; exit 1; }
done

# --- Locate the data disk dynamically ---------------------------------------
# Allow an explicit override: PART=/dev/sdXN sudo -E bash restore-docker-data-disk.sh
if [[ -n "${PART:-}" ]]; then
  echo "==> Using explicitly provided partition: ${PART}"
else
  echo "==> Scanning partitions for label '${EXPECTED_LABEL}'"
  PART=""
  while read -r name; do
    dev="/dev/${name}"
    label=$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)
    if [[ "$label" == "$EXPECTED_LABEL" ]]; then
      PART="$dev"
      break
    fi
  done < <(lsblk -rno NAME,TYPE | awk '$2=="part"{print $1}')
fi

if [[ -z "$PART" ]]; then
  echo "No partition labeled '${EXPECTED_LABEL}' was found." >&2
  echo >&2
  echo "Unmounted ext4 partitions on this system, for manual selection:" >&2
  while read -r name; do
    dev="/dev/${name}"
    type=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
    if [[ "$type" == "$EXPECTED_FSTYPE" ]] && ! mount | grep -q "^${dev} "; then
      lbl=$(blkid -s LABEL -o value "$dev" 2>/dev/null || echo "<none>")
      size=$(lsblk -no SIZE "$dev")
      echo "  ${dev}  size=${size}  label=${lbl}" >&2
    fi
  done < <(lsblk -rno NAME,TYPE | awk '$2=="part"{print $1}')
  echo >&2
  echo "Re-run with: PART=/dev/sdXN sudo -E bash restore-docker-data-disk.sh" >&2
  echo "to force a specific partition, or check the disk was actually attached." >&2
  exit 1
fi

if [[ ! -b "$PART" ]]; then
  echo "${PART} is not a block device." >&2
  exit 1
fi

DISK="/dev/$(lsblk -rno PKNAME "$PART")"

if mount | grep -q "^${PART} "; then
  echo "${PART} is already mounted:" >&2
  mount | grep "^${PART} "
  exit 1
fi

# --- Identify the disk before touching anything ---------------------------
DETECTED_FSTYPE=$(blkid -s TYPE -o value "$PART" || true)
DETECTED_LABEL=$(blkid -s LABEL -o value "$PART" || true)
UUID=$(blkid -s UUID -o value "$PART" || true)

if [[ -z "$UUID" ]]; then
  echo "Could not read a UUID from ${PART} — it may be unformatted/blank." >&2
  echo "Refusing to proceed on an unrecognised filesystem." >&2
  exit 1
fi

echo "==> Found data disk ${DISK} (partition ${PART})"
echo "    Filesystem : ${DETECTED_FSTYPE:-unknown}"
echo "    Label      : ${DETECTED_LABEL:-<none>}"
echo "    UUID       : ${UUID}"
echo

if [[ "$DETECTED_FSTYPE" != "$EXPECTED_FSTYPE" ]]; then
  echo "WARNING: expected filesystem '${EXPECTED_FSTYPE}' but found '${DETECTED_FSTYPE:-unknown}'." >&2
fi

lsblk "$DISK"
echo
echo "This will mount ${PART} (existing data, NOT reformatted) at ${REAL_MOUNT}"
echo "and bind-mount its subdirectories over /srv/docker, /var/lib/docker,"
echo "and /var/lib/containerd."
read -rp "Type the disk name (${DISK#/dev/}) to confirm: " CONFIRM
if [[ "$CONFIRM" != "${DISK#/dev/}" ]]; then
  echo "Confirmation did not match. Aborting."
  exit 1
fi

# --- Mount the preserved disk ----------------------------------------------
mkdir -p "$REAL_MOUNT"

if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=${UUID}  ${REAL_MOUNT}  ${DETECTED_FSTYPE:-$EXPECTED_FSTYPE}  defaults,nofail  0  2" >> /etc/fstab
fi

mount "$REAL_MOUNT"

# --- Verify the expected data is actually present ---------------------------
echo
echo "==> Checking for preserved subdirectories under ${REAL_MOUNT}"
MISSING=0
for subdir in "${!BIND_MAP[@]}"; do
  if [[ ! -d "${REAL_MOUNT}/${subdir}" ]]; then
    echo "MISSING: ${REAL_MOUNT}/${subdir} (expected from previous install)" >&2
    MISSING=1
  else
    SIZE=$(du -sh "${REAL_MOUNT}/${subdir}" 2>/dev/null | cut -f1)
    echo "    ${subdir}: present (${SIZE:-unknown size})"
  fi
done

if [[ "$MISSING" -eq 1 ]]; then
  echo
  echo "One or more expected subdirectories were not found." >&2
  echo "This disk may not be the one you think it is, or data was lost." >&2
  read -rp "Continue anyway and create the missing subdirs empty? [y/N] " FORCE
  if [[ "$FORCE" != "y" && "$FORCE" != "Y" ]]; then
    echo "Aborting without making bind-mount changes to /etc/fstab."
    exit 1
  fi
fi

# --- Create bind-mount targets + fstab entries ------------------------------
for subdir in "${!BIND_MAP[@]}"; do
  target="${BIND_MAP[$subdir]}"
  mkdir -p "${REAL_MOUNT}/${subdir}"
  mkdir -p "$target"

  if ! grep -qF "${REAL_MOUNT}/${subdir} " /etc/fstab; then
    echo "${REAL_MOUNT}/${subdir}  ${target}  none  bind,nofail  0  0" >> /etc/fstab
  fi
done

echo "==> Mounting all fstab entries"
mount -a

# --- Verify -----------------------------------------------------------------
echo
echo "==> Verification"
findmnt "$REAL_MOUNT"
for target in "${BIND_MAP[@]}"; do
  findmnt "$target"
done

echo
echo "Done. ${REAL_MOUNT} is mounted from preserved disk ${PART} (UUID=${UUID})."
echo "No partitioning or formatting was performed."
lsblk "$DISK"
