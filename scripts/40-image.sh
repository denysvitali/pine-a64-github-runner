#!/bin/bash
# Stage 40: assemble the SD-card image: MBR layout, U-Boot, boot.scr, A/B slots, DATA.
set -euo pipefail
source /scripts/lib.sh

need_env SIZE_BOOT SIZE_SLOT SIZE_IMAGE CMDLINE ROOT_OVERLAY_SIZE CHROOT_OVERLAY_SIZE

# Board profile: picks both the U-Boot binary and the kernel DTB so they stay
# coherent. linux-sunxi Pine64 guidance: the pine64_plus target covers every
# Pine64 board — non-plus variants are detected at runtime by U-Boot itself.
case "${BOARD:-plain}" in
    plain) UBOOT_BOARD=pine64_plus; FDTFILE=sun50i-a64-pine64.dtb ;;
    plus)  UBOOT_BOARD=pine64_plus; FDTFILE=sun50i-a64-pine64-plus.dtb ;;
    lts)   UBOOT_BOARD=pine64-lts;  FDTFILE=sun50i-a64-pine64-lts.dtb ;;
    *)     die "BOARD must be plain|plus|lts (got '$BOARD')" ;;
esac
log "Board profile '${BOARD:-plain}': u-boot '$UBOOT_BOARD', kernel DT '$FDTFILE'"

ROOTFS="$WORK/rootfs"
IMG="$WORK/sdcard.img"
BOOT_MNT="$WORK/mnt-boot"
SLOT_MNT="$WORK/mnt-slot"
mkdir -p "$BOOT_MNT" "$SLOT_MNT"

# --- boot assets staged up front so BOOT can be sized from real artifacts
# (the immutable+kms initramfs is ~80MB; x2 slots overflows any guess) ---
log "Staging boot assets"
BOOT_MNT_STAGING="$WORK/boot-staging"
rm -rf "$BOOT_MNT_STAGING"
mkdir -p "$BOOT_MNT_STAGING"

KERNEL_REL=$(ls "$ROOTFS/lib/modules" | first_line)
VMLINUZ="$ROOTFS/boot/vmlinuz-lts"
[ -f "$VMLINUZ" ] || VMLINUZ=$(find "$ROOTFS/lib/modules/$KERNEL_REL" -name 'vmlinuz-lts' | first_line)
[ -f "$VMLINUZ" ] || die "kernel image not found"

# booti needs a RAW arm64 Image ("ARM\x64" magic at byte 56). Alpine ships
# vmlinuz-lts as an EFI zboot PE wrapper around a gzip'd Image, so detect by
# content: raw Image passes through, anything else gets its gzip payload carved.
image_magic() {
    [ "$(dd if="$1" bs=1 skip=56 count=4 status=none | od -An -tx1 | tr -d ' \n')" = "41524d64" ]
}

if image_magic "$VMLINUZ"; then
    log "Kernel is a raw arm64 Image"
    cp "$VMLINUZ" "$BOOT_MNT_STAGING/Image"
else
    # Payload offset first from the zboot header ('zimg' + u32 LE), else a full
    # hex scan for the gzip stream. BusyBox grep lacks -b, hence od/xxd/awk.
    ZIMG_HEX=$(dd if="$VMLINUZ" bs=512 count=1 status=none | od -An -tx1 | tr -d ' \n')
    ZIMG_OFF=$(awk 'BEGIN { i = index(ARGV[1], "7a696d67"); print (i > 0 && (i-1) % 2 == 0) ? (i-1)/2 : -1 }' "$ZIMG_HEX")
    GZ_OFF=-1
    if [ "$ZIMG_OFF" -ge 0 ]; then
        HEX=$(dd if="$VMLINUZ" bs=1 skip=$((ZIMG_OFF + 4)) count=4 status=none | od -An -tx1 | tr -d ' \n')
        CAND=$(( 16#${HEX:6:2}${HEX:4:2}${HEX:2:2}${HEX:0:2} ))
        if [ "$(dd if="$VMLINUZ" bs=1 skip=$CAND count=3 status=none | od -An -tx1 | tr -d ' \n')" = "1f8b08" ]; then
            GZ_OFF=$CAND
        fi
    fi
    if [ "$GZ_OFF" -lt 0 ]; then
        GZ_OFF=$(xxd -p "$VMLINUZ" | tr -d '\n' \
            | awk '{ i = index($0, "1f8b08") - 1; if (i >= 0 && i % 2 == 0) print i / 2 }' | head -n1)
        [ -n "$GZ_OFF" ] || die "vmlinuz has no raw-Image magic, zboot header, or gzip payload; cannot stage for booti"
    fi

    log "Kernel is gzip-wrapped (payload at offset ${GZ_OFF}); unwrapping for booti"
    BLK=4096
    set +e
    { dd if="$VMLINUZ" bs=$BLK skip=$((GZ_OFF / BLK)) status=none \
        | dd bs=1 skip=$((GZ_OFF % BLK)) status=none; } | gunzip -c > "$BOOT_MNT_STAGING/Image"
    RC=$?
    set -e
    # rc=2 is gzip's "trailing garbage ignored" — expected after a wrapped member
    [ "$RC" -le 2 ] || die "gunzip failed on wrapped kernel (rc=$RC)"
fi

image_magic "$BOOT_MNT_STAGING/Image" || die "staged Image lacks the arm64 Image magic; refusing to hand it to booti"
log "Staged raw arm64 Image ($(du -h "$BOOT_MNT_STAGING/Image" | awk '{print $1}'))"

DTB_FILE=$(find "$ROOTFS" -name 'sun50i-a64-pine64.dtb' 2>/dev/null | first_line)
[ -n "$DTB_FILE" ] || die "sun50i-a64-pine64.dtb not found in rootfs"
DTB_SRC=$(dirname "$DTB_FILE")
mkdir -p "$BOOT_MNT_STAGING/dtbs/allwinner"
cp "$DTB_SRC"/sun50i-a64-pine64*.dtb "$BOOT_MNT_STAGING/dtbs/allwinner/"

INITRAMFS=$(ls "$ROOTFS"/boot/initramfs-* 2>/dev/null | first_line)
[ -f "$INITRAMFS" ] || die "initramfs not found"
cp "$INITRAMFS" "$BOOT_MNT_STAGING/initramfs"

# boot.cmd -> boot.scr; placeholders come from env + the BOARD profile
sed -e "s|@CMDLINE@|$CMDLINE|g" \
    -e "s|@ROOT_OVERLAY_SIZE@|$ROOT_OVERLAY_SIZE|g" \
    -e "s|@FDTFILE@|$FDTFILE|g" /input/boot.cmd > "$WORK/boot.cmd.rendered"
if grep -q '@' "$WORK/boot.cmd.rendered"; then
    die "unsubstituted placeholder left in boot.cmd"
fi
mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 \
    -d "$WORK/boot.cmd.rendered" "$WORK/boot.scr" >/dev/null

# geometry sanity: BOOT must hold Image+initramfs+dtbs twice (A/B) with FAT
# slack; DATA needs breathing room
BOOT_STAGED_KB=$(du -sk "$BOOT_MNT_STAGING" | awk '{print $1}')
MIN_BOOT=$(( BOOT_STAGED_KB * 2 * 125 / 100 / 1024 + 16 ))
if [ "$SIZE_BOOT" -lt "$MIN_BOOT" ]; then
    warn "SIZE_BOOT=${SIZE_BOOT}M cannot fit A/B boot assets (${MIN_BOOT}M needed); bumping"
    export SIZE_BOOT=$MIN_BOOT
fi
MIN_IMAGE=$(( SIZE_BOOT + SIZE_SLOT * 2 + 512 ))
if [ "${SIZE_IMAGE:-0}" -lt "$MIN_IMAGE" ]; then
    warn "SIZE_IMAGE=${SIZE_IMAGE}M cannot fit BOOT+2 slots+DATA; bumping to ${MIN_IMAGE}M"
    export SIZE_IMAGE=$MIN_IMAGE
fi

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

LOOPDEV=""
cleanup() {
    umount_all "$BOOT_MNT" "$SLOT_MNT"
    unmap_partition
    [ -z "$LOOPDEV" ] || losetup -d "$LOOPDEV" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# per-partition loop mapping (immune to loop.max_part=0)
map_partition "$IMG" 1; P1="$PART_DEV"
mkfs.vfat -n BOOT "$P1" >/dev/null
unmap_partition

for SLOT in a b; do
    log "Populating slot-$SLOT"
    map_partition "$IMG" $([ "$SLOT" = a ] && echo 2 || echo 3)
    mkfs.ext4 -q -L "slot-$SLOT" -E lazy_itable_init=0,lazy_journal_init=0 "$PART_DEV"
    mount "$PART_DEV" "$SLOT_MNT"
    rsync -aHAX --numeric-ids --exclude=/srv/chroot-template/var/* "$ROOTFS/" "$SLOT_MNT/"
    # runtime mountpoints used by the gha services
    mkdir -p "$SLOT_MNT/srv/chroot" "$SLOT_MNT/data"
    umount_all "$SLOT_MNT"
    unmap_partition
done

log "Creating empty DATA partition"
map_partition "$IMG" 4
mkfs.ext4 -q -L data -E lazy_itable_init=0,lazy_journal_init=0 "$PART_DEV"
unmap_partition

# --- boot partition (assets staged and size-guarded above) ---
log "Populating boot partition"

map_partition "$IMG" 1
mount "$PART_DEV" "$BOOT_MNT"
for S in a b; do
    cp "$BOOT_MNT_STAGING/Image"     "$BOOT_MNT/Image.$S"
    cp "$BOOT_MNT_STAGING/initramfs" "$BOOT_MNT/initramfs.$S"
    cp -r "$BOOT_MNT_STAGING/dtbs"   "$BOOT_MNT/dtbs.$S"
done
cp "$WORK/boot.scr" "$BOOT_MNT/boot.scr"
umount_all "$BOOT_MNT"
unmap_partition

# --- U-Boot at 8KiB: fixed BROM load address for sunxi SPL ---
# Alpine ships one dir per board under /usr/share/u-boot/ and a wrong-family
# binary boots far enough to die in SPL DRAM init ("DRAM: 0 MiB"), so the dir
# comes from the BOARD profile (above), never from a find/grep lottery, and is
# asserted to target this SoC before it lands on the image.
UBOOT_BIN="$ROOTFS/usr/share/u-boot/$UBOOT_BOARD/u-boot-sunxi-with-spl.bin"
[ -f "$UBOOT_BIN" ] || die "no u-boot for '$UBOOT_BOARD' (have: $(ls "$ROOTFS/usr/share/u-boot" | tr '\n' ' '))"
grep -aq 'sun50i-a64' "$UBOOT_BIN" || die "u-boot binary for '$UBOOT_BOARD' does not target sun50i-a64"
log "Writing U-Boot ($(du -h "$UBOOT_BIN" | awk '{print $1}')) at offset 8KiB"
dd if="$UBOOT_BIN" of="$IMG" bs=1024 seek=8 conv=notrunc,fsync status=none

sync
trap - EXIT INT TERM

# --- outputs ---
OUT="/output"
log "Compressing artifacts"
# zstd --long dedups the near-identical A/B slots across their 2GiB distance;
# gzip's 32KB window cannot, and the result exceeds GitHub's 2GiB release cap
zstd -T0 --long=31 -qf "$IMG" -o "$IMG.zst"
# checksum files carry bare filenames so they verify from any cwd
(cd "$WORK" && sha256sum sdcard.img.zst) > "$IMG.zst.sha256"

# single-slot update payload for ab-flash: a ready-made ext4 slot image plus a
# boot-assets bundle (unsuffixed names; ab-flash renames them to the target slot).
UPDATE="$WORK/slot-update.img"
truncate -s "${SIZE_SLOT}M" "$UPDATE"
UPLOOP=$(losetup --find --show "$UPDATE")
mkfs.ext4 -q -L slot-x "$UPLOOP"
mount "$UPLOOP" "$SLOT_MNT"
rsync -aHAX --numeric-ids --exclude=/srv/chroot-template/var/* "$ROOTFS/" "$SLOT_MNT/"
mkdir -p "$SLOT_MNT/srv/chroot" "$SLOT_MNT/data"
umount_all "$SLOT_MNT"
losetup -d "$UPLOOP"
pigz -kf "$UPDATE"
(cd "$WORK" && sha256sum slot-update.img.gz) > "$UPDATE.gz.sha256"

BOOT_ASSETS="$WORK/boot-assets"
rm -rf "$BOOT_ASSETS"
mkdir -p "$BOOT_ASSETS/dtbs"
cp "$BOOT_MNT_STAGING"/Image "$BOOT_ASSETS/"
cp "$BOOT_MNT_STAGING"/initramfs "$BOOT_ASSETS/"
cp -r "$BOOT_MNT_STAGING"/dtbs "$BOOT_ASSETS/"

mv "$IMG.zst" "$IMG.zst.sha256" "$OUT/"

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
(cd "$OUT" && sha256sum sdcard_update.tar.gz) > "$OUT/sdcard_update.tar.gz.sha256"

cat > "$OUT/versions.txt" <<EOF
project: pine-a64-gh-runner
board_profile: ${BOARD:-plain} (u-boot $UBOOT_BOARD, dtb $FDTFILE)
alpine_branch: $ALPINE_BRANCH
kernel: $KERNEL_REL
actions_runner: v$RUNNER_VERSION
image_size: ${SIZE_IMAGE}M
slots: ${SIZE_SLOT}M x2
built: $(date -u '+%Y-%m-%d %H:%M:%SZ')
EOF

log "Stage 40 complete:"
ls -lh "$OUT"
