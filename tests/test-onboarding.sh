#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APPLY="$ROOT/input/rootfs/usr/local/sbin/gha-apply-auth-state"
SETUP="$ROOT/input/rootfs/usr/local/sbin/gha-setup"
RUNNER_CYCLE="$ROOT/input/rootfs/usr/local/sbin/gha-runner-cycle.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

for script in "$APPLY" "$SETUP" "$RUNNER_CYCLE"; do
    sh -n "$script"
done
bash -n "$ROOT/scripts/add-users.sh" "$ROOT/scripts/20-rootfs.sh"
grep -q 'need localmount seedrng' "$ROOT/input/rootfs/etc/init.d/gha-data"
grep -q 'admin shell must be /bin/ash' "$ROOT/scripts/20-rootfs.sh"
grep -q 'onboarding login wrapper must not exist' "$ROOT/scripts/20-rootfs.sh"

reject_pattern() {
    pattern=$1
    file=$2
    if grep -q -- "$pattern" "$file"; then
        echo "unexpected '$pattern' in $file" >&2
        exit 1
    fi
}

# Recovery is always available, setup never accepts a PAT, and the one-time
# listener retains registration credentials while still exiting after one job.
test ! -e "$ROOT/input/rootfs/usr/local/sbin/gha-onboard-shell"
grep -q 'doas /usr/local/sbin/gha-setup' "$ROOT/input/rootfs/etc/motd"
grep -q 'doas -s' "$ROOT/input/rootfs/etc/motd"
grep -q 'Runner registration token' "$SETUP"
reject_pattern 'GITHUB_TOKEN' "$SETUP"
reject_pattern 'github_pat_' "$SETUP"
reject_pattern 'chmod --reference' "$APPLY"
reject_pattern 'chown --reference' "$APPLY"
grep -q -- './run.sh --once' "$RUNNER_CYCLE"
grep -q 'PERSIST_CONFIG=/data/runner/config' "$RUNNER_CYCLE"
reject_pattern 'GITHUB_TOKEN' "$RUNNER_CYCLE"

mkdir -p "$TMP/conf" "$TMP/home" "$TMP/sshd" "$TMP/host-keys"
cat > "$TMP/shadow" <<'EOF'
root:!:20000:0:99999:7:::
admin:$6$bootstrap$old:20000:0:99999:7:::
EOF

# The image contains only the documented temporary hash and the setup wrapper.
mkdir -p "$TMP/mock-root/etc" "$TMP/mock-root/home"
printf '%s\n' 'root:x:0:0:root:/root:/bin/ash' > "$TMP/mock-root/etc/passwd"
printf '%s\n' 'root:x:0:' > "$TMP/mock-root/etc/group"
printf '%s\n' 'root:!::0:::::' > "$TMP/mock-root/etc/shadow"
CHROOT_ROOT="$TMP/mock-root" bash -c 'source "$1"' _ "$ROOT/scripts/add-users.sh"
grep -qx 'admin:x:1000:1000::/home/admin:/bin/ash' "$TMP/mock-root/etc/passwd"
grep -qx 'admin:x:1000:' "$TMP/mock-root/etc/group"
grep -Fqx 'admin:$6$ghaPineA64Setup$n/UnU5.f8da6riPYe9aiPFM1or18CsMXVG3pT1ZCRYLMFhlVlvln4q35fIbEEXb4WlmElxHTL4kyTiJSTd.HF.::0:::::' "$TMP/mock-root/etc/shadow"
grep -qx 'permit admin as root' "$TMP/mock-root/etc/doas.d/gha.conf"
grep -qx 'permit nopass admin cmd /usr/local/sbin/gha-setup' "$TMP/mock-root/etc/doas.d/gha.conf"
grep -qx 'permit nopass admin cmd /usr/local/sbin/ab-flash' "$TMP/mock-root/etc/doas.d/gha.conf"
grep -qx 'permit nopass admin cmd /sbin/reboot' "$TMP/mock-root/etc/doas.d/gha.conf"
reject_pattern '^deny' "$TMP/mock-root/etc/doas.d/gha.conf"

run_apply() {
    GHA_CONF_DIR="$TMP/conf" \
    GHA_ADMIN_HOME="$TMP/home" \
    GHA_SHADOW_FILE="$TMP/shadow" \
    GHA_SSHD_AUTH_CONFIG="$TMP/sshd/10-gha-auth.conf" \
    GHA_HOST_KEY_DIR="$TMP/host-keys" \
    GHA_ADMIN_UID="$(id -u)" \
    GHA_ADMIN_GID="$(id -g)" \
    GHA_SHADOW_UID="$(id -u)" \
    "$APPLY"
}

# An unfinished device generates its identity locally and permits either the
# temporary password or a public key that was optionally baked into the image.
run_apply
test -s "$TMP/host-keys/ssh_host_ed25519_key"
grep -qx "HostKey $TMP/host-keys/ssh_host_ed25519_key" "$TMP/sshd/10-gha-auth.conf"
grep -qx 'PasswordAuthentication yes' "$TMP/sshd/10-gha-auth.conf"
grep -qx 'AuthenticationMethods any' "$TMP/sshd/10-gha-auth.conf"

# Completion reconstructs the persisted hash/key and enforces public-key auth.
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnly onboarding@test' > "$TMP/conf/authorized_keys"
printf '%s\n' '$6$replacement$newhash' > "$TMP/conf/admin-password.hash"
printf '%s\n' 'GITHUB_URL=https://github.com/example/repo' > "$TMP/conf/env"
: > "$TMP/conf/onboarding-complete"
run_apply
grep -qx 'PasswordAuthentication no' "$TMP/sshd/10-gha-auth.conf"
grep -qx 'AuthenticationMethods publickey' "$TMP/sshd/10-gha-auth.conf"
grep -qx 'admin:$6$replacement$newhash:20000:0:99999:7:::' "$TMP/shadow"
test "$(stat -c '%a' "$TMP/shadow")" = 640
cmp "$TMP/conf/authorized_keys" "$TMP/home/.ssh/authorized_keys"

# A marker without its credential payload must fail closed.
rm "$TMP/conf/admin-password.hash"
if run_apply 2>/dev/null; then
    echo 'expected incomplete persisted state to be rejected' >&2
    exit 1
fi
grep -qx 'PasswordAuthentication no' "$TMP/sshd/10-gha-auth.conf"

echo 'onboarding state tests passed'
