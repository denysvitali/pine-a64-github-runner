#!/bin/bash
# Sourced by 20-rootfs.sh; creates admin and runner users in $ROOTFS.
# admin (1000): temporary first-boot password, then SSH-key-only login.
# runner (1001): unprivileged GitHub Actions runner identity (chroot-side).
set -euo pipefail

R="$CHROOT_ROOT"

add_user() {
    local name="$1" uid="$2" gid="$3" home="$4" shell="$5"
    grep -q "^$name:" "$R/etc/passwd" || \
        echo "$name:x:$uid:$gid::${home}:${shell}" >> "$R/etc/passwd"
    grep -q "^[^:]*:[^:]*:$gid:" "$R/etc/group" || echo "$name:x:$gid:" >> "$R/etc/group"
    grep -q "^$name:" "$R/etc/shadow" || echo "$name:!::0:::::" >> "$R/etc/shadow"
}

add_user admin 1000 1000 /home/admin /bin/ash
install -d -m 700 -o 1000 -g 1000 "$R/home/admin"

# Documented bootstrap credential: admin / pine64-setup.  The onboarding flow
# replaces this hash and disables SSH password authentication before completing.
# This is intentionally a fixed hash because the password is public, temporary,
# and only exists to make a freshly flashed device reachable on the local LAN.
ADMIN_BOOTSTRAP_HASH='$6$ghaPineA64Setup$n/UnU5.f8da6riPYe9aiPFM1or18CsMXVG3pT1ZCRYLMFhlVlvln4q35fIbEEXb4WlmElxHTL4kyTiJSTd.HF.'
sed -i "s|^admin:[^:]*:|admin:${ADMIN_BOOTSTRAP_HASH}:|" "$R/etc/shadow"

# runner user exists only inside the Debian chroot (created in stage 30);
# here we just reserve nothing on the Alpine side.

mkdir -p "$R/etc/doas.d"
cat > "$R/etc/doas.d/gha.conf" <<'EOF'
# General recovery access requires the admin user's current password.
permit admin as root
# Last matching rule wins: routine appliance operations stay passwordless.
permit nopass admin cmd /usr/local/sbin/ab-flash
permit nopass admin cmd /usr/local/sbin/gha-slot-select
permit nopass admin cmd /usr/local/sbin/gha-setup
permit nopass admin cmd /sbin/reboot
permit nopass admin cmd /sbin/poweroff
EOF
