#!/bin/bash
# Sourced by 20-rootfs.sh; creates admin and runner users in $ROOTFS.
# admin (1000): SSH-key-only login, doas for maintenance commands.
# runner (1001): unprivileged GitHub Actions runner identity (chroot-side).
set -euo pipefail

R="$CHROOT_ROOT"

add_user() {
    local name="$1" uid="$2" gid="$3" home="$4" shell="$5"
    grep -q "^$name:" "$R/etc/passwd" || \
        echo "$name:x:$uid:$gid::${home}:${shell}" >> "$R/etc/passwd"
    grep -q "^$gid:" "$R/etc/group" || echo "$gid:$name:" >> "$R/etc/group"
    grep -q "^$name:" "$R/etc/shadow" || echo "$name:!::0:::::" >> "$R/etc/shadow"
}

add_user admin 1000 1000 /home/admin /bin/ash
install -d -m 700 -o 1000 -g 1000 "$R/home/admin"

# runner user exists only inside the Debian chroot (created in stage 30);
# here we just reserve nothing on the Alpine side.

mkdir -p "$R/etc/doas.d"
cat > "$R/etc/doas.d/gha.conf" <<'EOF'
permit nopass admin cmd /usr/local/sbin/ab-flash
permit nopass admin cmd /usr/local/sbin/gha-slot-select
EOF
