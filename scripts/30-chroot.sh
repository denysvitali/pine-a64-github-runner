#!/bin/bash
# Stage 30: build the glibc Debian chroot (template) with the actions-runner inside.
# Lives read-only in each slot; runtime overlays a tmpfs upperdir for ephemeral writes.
set -euo pipefail
source /scripts/lib.sh

need_env CHROOT_DISTRO

ROOTFS="$WORK/rootfs"
CH="$ROOTFS/srv/chroot-template"
RUNNER_VERSION=$(cat "$CACHE_PATH/runner_version")
TARBALL="$CACHE_PATH/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"

rm -rf "$CH"
mkdir -p "$CH"

HOST_ARCH=$(uname -m)
DEB_ARCH=arm64
FOREIGN_ARGS=()
if [ "$HOST_ARCH" != "aarch64" ]; then
    warn "Building on $HOST_ARCH: foreign debootstrap (needs qemu-user-static + binfmt on host)"
    FOREIGN_ARGS=(--foreign --arch "$DEB_ARCH")
fi

log "debootstrap $CHROOT_DISTRO ($DEB_ARCH) -> $CH"
debootstrap "${FOREIGN_ARGS[@]}" \
    --variant=minbase \
    --include=ca-certificates \
    "$CHROOT_DISTRO" "$CH" "https://deb.debian.org/debian"

if [ ${#FOREIGN_ARGS[@]} -gt 0 ]; then
    log "Second stage under qemu"
    mount --bind /dev "$CH/dev" 2>/dev/null || true
    chroot "$CH" /debootstrap/debootstrap --second-stage
    umount "$CH/dev" 2>/dev/null || true
fi

# apt sources + policy: no recommends, no docs
mkdir -p "$CH/etc/apt/apt.conf.d"
cat > "$CH/etc/apt/apt.conf.d/99gha" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
EOF
cat > "$CH/etc/apt/sources.list" <<EOF
deb https://deb.debian.org/debian $CHROOT_DISTRO main
EOF

mount --bind /proc "$CH/proc"
trap 'umount "$CH/proc" 2>/dev/null || true' EXIT INT TERM
cp /etc/resolv.conf "$CH/etc/resolv.conf"

log "Installing chroot packages"
chroot "$CH" apt-get update -qq
chroot "$CH" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    $(sed 's/#.*//' /input/chroot-packages | xargs)

# passwd/group entries for the unprivileged runner identity
grep -q '^runner:' "$CH/etc/passwd" || \
    echo 'runner:x:1001:1001::/data/runner/home:/bin/bash' >> "$CH/etc/passwd"
grep -q '^1001:' "$CH/etc/group" || echo '1001:runner:' >> "$CH/etc/group"

# actions-runner into /opt/actions-runner (config artifacts land on tmpfs upper at runtime)
log "Installing actions-runner v$RUNNER_VERSION into chroot"
mkdir -p "$CH/opt"
tar -xzf "$TARBALL" -C "$CH/opt"
# official tarballs already extract to 'actions-runner/'; tolerate legacy layouts
if [ ! -d "$CH/opt/actions-runner" ]; then
    EXTRACTED=$(find "$CH/opt" -maxdepth 1 -type d -name 'actions-runner-*' | first_line)
    [ -n "$EXTRACTED" ] || die "unexpected runner tarball layout: $(ls "$CH/opt")"
    mv "$EXTRACTED" "$CH/opt/actions-runner"
fi
chmod +x "$CH/opt/actions-runner/config.sh" "$CH/opt/actions-runner/run.sh" "$CH/opt/actions-runner/env.sh"

echo "$RUNNER_VERSION" > "$CH/opt/actions-runner/.runner-version"

# trim fat so slots stay small
chroot "$CH" apt-get clean
rm -rf "$CH"/var/lib/apt/lists/* "$CH"/usr/share/doc/* "$CH"/usr/share/man/* "$CH"/var/cache/debconf/*
rm -f "$CH/etc/resolv.conf"

log "Stage 30 complete ($(du -sh "$CH" | awk '{print $1}'))"
