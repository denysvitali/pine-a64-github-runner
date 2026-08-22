#!/bin/bash
# Stage 20: build the immutable Alpine host rootfs.
set -euo pipefail
source /scripts/lib.sh

need_env DEFAULT_HOSTNAME ROOT_OVERLAY_SIZE CHROOT_OVERLAY_SIZE SIZE_TMPFS

ROOTFS="$WORK/rootfs"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

REPO="$ALPINE_MIRROR/$ALPINE_BRANCH/main"
COMMUNITY="$ALPINE_MIRROR/$ALPINE_BRANCH/community"

log "Unpacking minirootfs into $ROOTFS"
tar -xzf "$CACHE_PATH/minirootfs.tar.gz" -C "$ROOTFS"

mkdir -p "$ROOTFS/etc/apk"
cat > "$ROOTFS/etc/apk/repositories" <<EOF
$REPO
$COMMUNITY
EOF

log "Installing packages (apk --root)"
apk add --no-cache --initdb --root "$ROOTFS" --arch "$ARCH" \
    --keys-dir /etc/apk/keys \
    $(sed 's/#.*//' /input/packages | xargs)

# Native-arch shortcut: when building on arm64 the maintainer scripts already ran.
# On foreign arch they are skipped by apk; everything we rely on is file-based below.

# --- base configuration ---
echo "$DEFAULT_HOSTNAME" > "$ROOTFS/etc/hostname"

mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    hostname gha-pine64
EOF

# DNS + time sanity for TLS (token minting)
rm -f "$ROOTFS/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# --- mkinitfs: immutable-root capable initramfs ---
log "Configuring mkinitfs features"
MKI_DIR="$ROOTFS/usr/share/mkinitfs/features.d"
[ -d "$MKI_DIR" ] || MKI_DIR="$ROOTFS/etc/mkinitfs/features.d"
[ -d "$MKI_DIR" ] || die "mkinitfs features.d not found in rootfs"
# custom feature ensuring overlay.ko lands in the initramfs.
# NOTE: entries are globs relative to /lib/modules/$KVER/ (mkinitfs feature_files)
printf 'kernel/fs/overlayfs\n' > "$MKI_DIR/immutable.modules"
cat > "$ROOTFS/etc/mkinitfs/mkinitfs.conf" <<EOF
features="base ext4 kms mmc immutable"
disable_kms_modules=no
EOF

# linux-lts' install hook already produced an initramfs with default features;
# regenerate with ours and assert the modules we depend on are present.
log "Regenerating initramfs with immutable features"
KVER=$(ls "$ROOTFS/lib/modules" | head -1)
{
    echo "--- mkinitfs.conf:";   cat "$ROOTFS/etc/mkinitfs/mkinitfs.conf"
    echo "--- immutable.modules:"; cat "$MKI_DIR/immutable.modules"
    echo "--- features.d contents:"; ls "$ROOTFS/etc/mkinitfs/features.d/"
    echo "--- overlayfs module present in tree:"
    ls "$ROOTFS/lib/modules/$KVER/kernel/fs/overlayfs/" 2>&1
} >&2

if ! chroot "$ROOTFS" /sbin/mkinitfs -c /etc/mkinitfs/mkinitfs.conf "$KVER"; then
    die "mkinitfs exited nonzero"
fi

# mkinitfs names output by flavor (e.g. boot/initramfs-lts), not by full KVER
INITRAMFS=$(ls "$ROOTFS"/boot/initramfs-* 2>/dev/null | head -1)
[ -f "$INITRAMFS" ] || die "mkinitfs produced no initramfs under $ROOTFS/boot/"
log "initramfs size: $(du -h "$INITRAMFS" | awk '{print $1}')"

LIST="$WORK/initramfs.list"
gzip -dc "$INITRAMFS" 2>&1 | cpio -t > "$LIST" 2>"$WORK/cpio.err" || true
log "initramfs entries: $(wc -l < "$LIST")"
if [ -s "$WORK/cpio.err" ]; then warn "cpio stderr: $(head -3 "$WORK/cpio.err")"; fi
echo "--- relevant modules in initramfs:" >&2
grep -E 'overlay|ext4|mmc|sunxi' "$LIST" | head -20 >&2

for MOD in overlayfs/overlay fs/ext4/ext4 "mmc.*mmc_block" "sunxi[-_]mmc"; do
    if ! grep -Eq "$MOD" "$LIST"; then
        die "module '$MOD' missing from initramfs (board would not boot)"
    fi
done

# --- fstab: root is mounted by initramfs; data is persistent; boot is manual-only ---
cat > "$ROOTFS/etc/fstab" <<EOF
/dev/mmcblk0p4  /data   ext4    rw,noatime,commit=120,errors=remount-ro     0 2
tmpfs           /tmp    tmpfs   rw,nosuid,nodev,size=$SIZE_TMPFS,mode=1777   0 0
tmpfs           /run    tmpfs   rw,nosuid,nodev,size=64m                     0 0
EOF

# --- security: lock root, no password auth anywhere ---
sed -i 's/^root:[^:]*:/root:!:/g' "$ROOTFS/etc/shadow"
chmod 640 "$ROOTFS/etc/shadow"

# admin user (uid 1000) with SSH keys only; doas for ab-flash/maintenance
export CHROOT_ROOT="$ROOTFS"
source /scripts/add-users.sh

# --- overlay tree from input/ ---
if [ -d /input/rootfs ]; then
    log "Applying input/rootfs overlay tree"
    cp -a /input/rootfs/. "$ROOTFS/"
fi

# authorized_keys fetched in CI (github.com/<owner>.keys)
if [ -s /input/config/authorized_keys ]; then
    install -d -m 700 -o 1000 -g 1000 "$ROOTFS/home/admin/.ssh"
    install -m 600 -o 1000 -g 1000 /input/config/authorized_keys "$ROOTFS/home/admin/.ssh/authorized_keys"
else
    warn "No input/config/authorized_keys provided; SSH login will be impossible!"
fi

# --- OpenRC runlevel wiring ---
log "Enabling OpenRC services"
rc_add() {
    mkdir -p "$ROOTFS/etc/runlevels/$2"
    ln -sf "/etc/init.d/$1" "$ROOTFS/etc/runlevels/$2/$1"
}
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add seedrng boot
rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add networking boot
rc_add zram-init boot
rc_add chronyd default
rc_add nftables boot
rc_add sshd default
rc_add gha-data boot
rc_add gha-runner default

# --- version stamp ---
RUNNER_VERSION=$(cat "$CACHE_PATH/runner_version")
KERNEL_REL=$(ls "$ROOTFS/lib/modules" | head -1)
cat > "$ROOTFS/etc/gha-build-info" <<EOF
project=pine-a64-gh-runner
alpine_branch=$ALPINE_BRANCH
kernel=$KERNEL_REL
runner_version=$RUNNER_VERSION
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log "Stage 20 complete ($(du -sh "$ROOTFS" | awk '{print $1}'))"
