#!/usr/bin/env bash
#===============================================================================
# JOJO BACKUPER — Rescue helper for bricked VPS after bad restore
# Run from provider RESCUE / recovery ISO (not the broken OS root alone).
# @B_KHANEMAN
#===============================================================================
set -euo pipefail

echo "=== JOJO BACKUPER rescue ==="
echo "1) Mount the VPS disk (example: /dev/sda1 or /dev/vda1)"
echo "2) Or set ROOTMNT=/mnt/broken and mount yourself first"
echo

ROOTMNT="${ROOTMNT:-/mnt/broken}"
mkdir -p "$ROOTMNT"

if ! findmnt "$ROOTMNT" >/dev/null 2>&1; then
    echo "Available disks:"
    lsblk -f || true
    echo
    read -r -p "Device to mount as root (e.g. /dev/sda1): " DEV
    [[ -n "${DEV:-}" ]] || { echo "No device"; exit 1; }
    mount "$DEV" "$ROOTMNT"
fi

echo "Mounted at $ROOTMNT"
echo "blkid:"
blkid || true

# Fix fstab if present from old server
if [[ -f "$ROOTMNT/etc/fstab" ]]; then
    cp -a "$ROOTMNT/etc/fstab" "$ROOTMNT/etc/fstab.bad-from-restore.$(date +%s)" || true
fi

# Prefer any preserved fstab
if [[ -f "$ROOTMNT/etc/fstab.smm-pre" ]]; then
    cp -a "$ROOTMNT/etc/fstab.smm-pre" "$ROOTMNT/etc/fstab"
    echo "Restored fstab.smm-pre"
elif [[ -f /etc/fstab ]] && findmnt / >/dev/null; then
    # In some rescue modes root is the rescue OS — skip
    true
fi

# Disable heavy auto-start that pegs CPU
mkdir -p "$ROOTMNT/etc/systemd/system"
for u in docker.service containerd.service nginx.service apache2.service mysql.service mariadb.service postgresql.service; do
    ln -sf /dev/null "$ROOTMNT/etc/systemd/system/$u" 2>/dev/null || true
done
echo "Masked docker/db/web for next boot (CPU safety)"

# Prefer netplan bak if any
if [[ -d "$ROOTMNT/etc/netplan.smm-bak" ]]; then
    mkdir -p "$ROOTMNT/etc/netplan"
    cp -a "$ROOTMNT/etc/netplan.smm-bak/." "$ROOTMNT/etc/netplan/" 2>/dev/null || true
    echo "Restored netplan from smm-bak"
fi

# Reinstall kernel into mounted system (Ubuntu)
if command -v chroot >/dev/null; then
    mount --bind /dev "$ROOTMNT/dev" 2>/dev/null || true
    mount --bind /proc "$ROOTMNT/proc" 2>/dev/null || true
    mount --bind /sys "$ROOTMNT/sys" 2>/dev/null || true
    echo "Attempting: apt-get install --reinstall linux-image-generic + update-grub"
    chroot "$ROOTMNT" bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y --reinstall linux-image-generic linux-headers-generic 2>/dev/null || \
        apt-get install -y --reinstall linux-image-amd64 2>/dev/null || true
        update-grub 2>/dev/null || true
        systemctl disable docker containerd 2>/dev/null || true
    ' || true
fi

echo
echo "Done. Next:"
echo "  - Exit rescue mode / reboot into normal OS from panel"
echo "  - SSH in, then: systemctl unmask docker; systemctl start docker"
echo "  - Start panel manually: cd /opt/pasarguard && docker compose up -d"
echo "  - If still no boot: reinstall OS from panel, then restore ONLY /opt + /var/lib/pasarguard"
