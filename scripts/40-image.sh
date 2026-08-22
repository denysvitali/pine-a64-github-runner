#!/bin/bash
# Stage 40: assemble the SD-card image: MBR layout, U-Boot, boot.scr, A/B slots, DATA.
set -euo pipefail
source /scripts/lib.sh

need_env SIZE_BOOT SIZE_SLOT SIZE_IMAGE CMDLINE ROOT_OVERLAY_SIZE CHROOT_OVERLAY_SIZE

ROOTFS="$WORK/rootfs"
IMG="$WORK/sdcard.img"
BOOT_MNT="$WORK/mnt-boot"
SLOT_MNT="$WORK/mnt-slot"

rm -f "$IMG"
truncate -s "${SIZE_IMAGE}M" "$IMG"

# --- partition table ---
# MBR on purpose: sunxi BROM loads SPL from sector 16, so u-boot-sunxi-with-spl.bin
# MUST be written at offset 8 KiB; an MBR (LBA0 only) leaves that region free,
# unlike GPT whose entry array would be clobbered. All partitions are primary,
# first one starts at 1 MiB (sfdisk default), leaving room for U-Boot.
log "Partitioning $IMG"
sfdisk "$IMG" <<EOF
label: dos
label-id: 0x$(head -c4 /dev/urandom | xxd -p)
start=2048, size=${SIZE_BOOT}MiB, type=0c, bootable
start=+,    size=${SIZE_SLOT}MiB, type=83
start=+,    size=${SIZE_SLOT}MiB, type=83
start=+,    type=83
EOF

LOOPDEV=$(losetup --find --show --partscan "$IMG")
cleanup() { umount_all "$BOOT_MNT" "$SLOT_MNT"; losetup -d "$LOOPDEV" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

P1="${LOOPDEV}p1"; P2="${LOOPDEV}p2"; P3="${LOOPDEV}p3"; P4="${LOOPDEV}p4"
for p in "$P1" "$P2" "$P3" "$P4"; do [ -b "$p" ] || die "missing $p"; done

mkfs.vfat -n BOOT "$P1" >/dev/null
mkfs.ext4 -q -L slot-a -E lazy_itable_init=0,lazy_journal_init=0 "$P2"
mkfs.ext4 -q -L slot-b -E lazy_itable_init=0,lazy_journal_init=0 "$P3"
mkfs.ext4 -q -L data   -E lazy_itable_init=0,lazy_journal_init=0 "$P4"

# --- populate both rootfs slots ---
for SLOT in a b; do
    log "Populating slot-$SLOT"
    mount "$([ "$SLOT" = a ] && echo "$P2" || echo "$P3")" "$SLOT_MNT"
    rsync -aHAX --numeric-ids --exclude=/srv/chroot-template/var/* "$ROOTFS/" "$SLOT_MNT/"
    # runtime mountpoints used by the gha services
    mkdir -p "$SLOT_MNT/srv/chroot" "$SLOT_MNT/data"
    umount_all "$SLOT_MNT"
done

# --- boot partition ---
log "Populating boot partition"
BOOT_MNT_STAGING="$WORK/boot-staging"
rm -rf "$BOOT_MNT_STAGING"
mkdir -p "$BOOT_MNT_STAGING"

KERNEL_REL=$(ls "$ROOTFS/lib/modules" | head -1)
VMLINUZ="$ROOTFS/boot/vmlinuz-lts"
[ -f "$VMLINUZ" ] || VMLINUZ=$(find "$ROOTFS/lib/modules/$KERNEL_REL" -name 'vmlinuz-lts' | head -1)
[ -f "$VMLINUZ" ] || die "kernel image not found"

if file "$VMLINUZ" | grep -qi gzip; then
    log "Kernel is gzip-compressed; uncompressing for booti"
    gunzip -c "$VMLINUZ" > "$BOOT_MNT_STAGING/Image"
else
    cp "$VMLINUZ" "$BOOT_MNT_STAGING/Image"
fi

DTB_FILE=$(find "$ROOTFS" -name 'sun50i-a64-pine64.dtb' 2>/dev/null | head -1)
[ -n "$DTB_FILE" ] || die "sun50i-a64-pine64.dtb not found in rootfs"
DTB_SRC=$(dirname "$DTB_FILE")
mkdir -p "$BOOT_MNT_STAGING/dtbs/allwinner"
cp "$DTB_SRC"/sun50i-a64-pine64*.dtb "$BOOT_MNT_STAGING/dtbs/allwinner/"

INITRAMFS=$(ls "$ROOTFS"/boot/initramfs-* 2>/dev/null | head -1)
[ -f "$INITRAMFS" ] || die "initramfs not found"
cp "$INITRAMFS" "$BOOT_MNT_STAGING/initramfs"

# boot.cmd -> boot.scr with slot-aware logic
sed -e "s|@CMDLINE@|$CMDLINE|" /input/boot.cmd > "$WORK/boot.cmd.rendered"
mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 \
    -d "$WORK/boot.cmd.rendered" "$WORK/boot.scr" >/dev/null

mount "$P1" "$BOOT_MNT"
for S in a b; do
    cp "$BOOT_MNT_STAGING/Image"     "$BOOT_MNT/Image.$S"
    cp "$BOOT_MNT_STAGING/initramfs" "$BOOT_MNT/initramfs.$S"
    cp -r "$BOOT_MNT_STAGING/dtbs"   "$BOOT_MNT/dtbs.$S"
done
cp "$WORK/boot.scr" "$BOOT_MNT/boot.scr"
umount_all "$BOOT_MNT"

# --- U-Boot at 8KiB: fixed BROM load address for sunxi SPL ---
UBOOT_BIN=$(find "$ROOTFS/usr/share/u-boot" "$ROOTFS/lib" -name 'u-boot-sunxi-with-spl.bin' 2>/dev/null | grep -i pine | head -1)
[ -f "$UBOOT_BIN" ] || UBOOT_BIN=$(find "$ROOTFS" -name 'u-boot-sunxi-with-spl.bin' 2>/dev/null | head -1)
[ -f "$UBOOT_BIN" ] || die "u-boot-sunxi-with-spl.bin not found (need u-boot-sunxi package)"
log "Writing U-Boot ($(du -h "$UBOOT_BIN" | awk '{print $1}')) at offset 8KiB"
dd if="$UBOOT_BIN" of="$IMG" bs=1024 seek=8 conv=notrunc,fsync status=none

sync
losetup -d "$LOOPDEV" && trap - EXIT INT TERM

# --- outputs ---
OUT="/output"
log "Compressing artifacts"
pigz -kf "$IMG"
sha256sum "$IMG.gz" > "$IMG.gz.sha256"

# single-slot update payload for ab-flash: a ready-made ext4 slot image plus a
# boot-assets bundle (unsuffixed names; ab-flash renames them to the target slot).
UPDATE="$WORK/slot-update.img"
truncate -s "${SIZE_SLOT}M" "$UPDATE"
UPLOOP=$(losetup --find --show --partscan "$UPDATE")
mkfs.ext4 -q -L slot-x "$UPLOOP"
mount "$UPLOOP" "$SLOT_MNT"
rsync -aHAX --numeric-ids --exclude=/srv/chroot-template/var/* "$ROOTFS/" "$SLOT_MNT/"
mkdir -p "$SLOT_MNT/srv/chroot" "$SLOT_MNT/data"
umount_all "$SLOT_MNT"
losetup -d "$UPLOOP"
pigz -kf "$UPDATE"
sha256sum "$UPDATE.gz" > "$UPDATE.gz.sha256"

BOOT_ASSETS="$WORK/boot-assets"
rm -rf "$BOOT_ASSETS"
mkdir -p "$BOOT_ASSETS/dtbs"
cp "$BOOT_MNT_STAGING"/Image "$BOOT_ASSETS/"
cp "$BOOT_MNT_STAGING"/initramfs "$BOOT_ASSETS/"
cp -r "$BOOT_MNT_STAGING"/dtbs "$BOOT_ASSETS/"

mv "$IMG.gz" "$IMG.gz.sha256" "$OUT/"

# --- on-device update bundle consumed by ab-flash ---
RUNNER_VERSION=$(cat "$CACHE_PATH/runner_version")
BUNDLE="$WORK/sdcard_update"
rm -rf "$BUNDLE"; mkdir -p "$BUNDLE"
cp "$UPDATE.gz" "$BUNDLE/slot.img.gz"
cp "$UPDATE.gz.sha256" "$BUNDLE/slot.img.gz.sha256"
tar -czf "$BUNDLE/boot-assets.tar.gz" -C "$WORK" boot-assets
sha256sum "$BUNDLE/boot-assets.tar.gz" | awk '{print $1"  boot-assets.tar.gz"}' > "$BUNDLE/boot-assets.tar.gz.sha256"
cat > "$BUNDLE/manifest.txt" <<EOF
project: pine-a64-gh-runner
alpine_branch: $ALPINE_BRANCH
kernel: $KERNEL_REL
actions_runner: v$RUNNER_VERSION
built: $(date -u '+%Y-%m-%d %H:%M:%SZ')
apply: doas ab-flash sdcard_update.tar.gz && reboot
EOF
tar -czf "$OUT/sdcard_update.tar.gz" -C "$WORK" sdcard_update
sha256sum "$OUT/sdcard_update.tar.gz" > "$OUT/sdcard_update.tar.gz.sha256"

cat > "$OUT/versions.txt" <<EOF
project: pine-a64-gh-runner
alpine_branch: $ALPINE_BRANCH
kernel: $KERNEL_REL
actions_runner: v$RUNNER_VERSION
image_size: ${SIZE_IMAGE}M
slots: ${SIZE_SLOT}M x2
built: $(date -u '+%Y-%m-%d %H:%M:%SZ')
EOF

log "Stage 40 complete:"
ls -lh "$OUT"
