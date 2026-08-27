#!/bin/sh
# One isolated runner cycle. Supervised by OpenRC (supervise-daemon): every exit
# triggers teardown and a clean overlay, while the registered runner identity is
# retained on /data so no PAT or repeated registration is required.
#
# Layout:
#   /srv/chroot-template      RO Debian rootfs baked in the immutable slot
#   /srv/chroot               overlay(template, tmpfs upper) rebuilt every cycle
#   /srv/chroot/opt/actions-runner  overlay(template subdir, tmpfs upper) for creds
#   /data                     persistent ext4, bound into chroot at /data
#
# Required /data/conf/env (root-only readable):
#   GITHUB_URL=https://github.com/OWNER/REPO
#   RUNNER_LABELS=pine64,aarch64,self-hosted

CONF=/data/conf/env
[ -r "$CONF" ] || { echo "FATAL: $CONF missing/unreadable"; sleep 30; exit 1; }
. "$CONF"

: "${RUNNER_LABELS:=self-hosted,aarch64}"
: "${CHROOT_OVERLAY_SIZE:-512M}"

[ -n "${GITHUB_URL}" ] || { echo "FATAL: GITHUB_URL unset"; sleep 30; exit 1; }

case "$GITHUB_URL" in
    https://github.com/*) ;;
    *) echo "FATAL: unsupported GITHUB_URL (github.com only)"; sleep 30; exit 1 ;;
esac

TEARDOWN=/usr/local/sbin/gha-chroot-teardown
"$TEARDOWN" >/dev/null 2>&1 || true

echo "[cycle] preparing chroot overlay (upper=${CHROOT_OVERLAY_SIZE})"
install -d /run/gha/root-upper /run/gha/root-work /run/ghar-upper /run/ghar-work

mount -t tmpfs -o "size=${CHROOT_OVERLAY_SIZE},mode=0755" chroot-upper /run/gha/root-upper
mkdir -p /run/gha/root-upper/root /run/gha/root-upper/work

mount -t overlay \
    -o "lowerdir=/srv/chroot-template,upperdir=/run/gha/root-upper/root,workdir=/run/gha/root-upper/work" \
    chroot /srv/chroot || { echo "FATAL: chroot overlay failed"; "$TEARDOWN" || true; exit 1; }

mount -t proc proc /srv/chroot/proc
mount -o bind /sys /srv/chroot/sys
mount -o bind /dev /srv/chroot/dev
mount --bind /data /srv/chroot/data
mount --bind /etc/resolv.conf /srv/chroot/etc/resolv.conf 2>/dev/null || \
    cp /etc/resolv.conf /srv/chroot/etc/resolv.conf

# writable view of the runner tree: credentials/config land on tmpfs, never on disk
mount -t overlay \
    -o "lowerdir=/srv/chroot-template/opt/actions-runner,upperdir=/run/ghar-upper,workdir=/run/ghar-work" \
    runner-tree /srv/chroot/opt/actions-runner

PERSIST_CONFIG=/data/runner/config
RUNNER_ROOT=/srv/chroot/opt/actions-runner
CONFIG_FILES='.runner .credentials .credentials_rsaparams .runner_migrated .credentials_migrated'

mkdir -p /data/runner/home /data/runner/_work "$PERSIST_CONFIG"
chown 1001:1001 /data/runner/home /data/runner/_work "$PERSIST_CONFIG"
chmod 700 "$PERSIST_CONFIG"
find /data/runner/_work -mindepth 1 -delete 2>/dev/null || true

RUNNER_NAME=${RUNNER_NAME:-$(hostname)}
if [ -z "${RUNNER_NAME_SET:-}" ]; then
    MAC=$(cat /sys/class/net/eth0/address 2>/dev/null | tail -c 6 | tr -d ':')
    [ -n "$MAC" ] && RUNNER_NAME="${RUNNER_NAME}-${MAC}"
fi

RUNNER_ENV="export HOME=/data/runner/home"

persist_runner_config() {
    for file in $CONFIG_FILES; do
        if [ -s "$RUNNER_ROOT/$file" ]; then
            install -m 600 -o 1001 -g 1001 "$RUNNER_ROOT/$file" "$PERSIST_CONFIG/$file"
        fi
    done
}

if [ -s "$PERSIST_CONFIG/.runner" ] && [ -s "$PERSIST_CONFIG/.credentials" ]; then
    echo "[cycle] restoring registered runner identity"
    for file in $CONFIG_FILES; do
        if [ -s "$PERSIST_CONFIG/$file" ]; then
            install -m 600 -o 1001 -g 1001 "$PERSIST_CONFIG/$file" "$RUNNER_ROOT/$file"
        fi
    done
else
    TOKEN_FILE=/data/conf/registration-token
    [ -s "$TOKEN_FILE" ] || {
        echo "FATAL: runner is not registered; run 'doas /usr/local/sbin/gha-setup' with a fresh registration token"
        "$TEARDOWN" || true
        exit 1
    }
    TOKEN=$(cat "$TOKEN_FILE")
    echo "[cycle] registering runner '${RUNNER_NAME}'"
    setpriv --reuid=1001 --regid=1001 --clear-groups \
        chroot /srv/chroot /bin/bash -c "
        $RUNNER_ENV
        cd /opt/actions-runner && \
        ./config.sh --url '${GITHUB_URL}' \
            --token '${TOKEN}' \
            --name '${RUNNER_NAME}' \
            --labels '${RUNNER_LABELS}' \
            --disableupdate --unattended --work /data/runner/_work
    " || { echo "FATAL: config.sh failed (the registration token may have expired)"; "$TEARDOWN" || true; exit 1; }
    unset TOKEN
    persist_runner_config
    rm -f "$TOKEN_FILE"
fi

echo "[cycle] starting runner listener for one job"
setpriv --reuid=1001 --regid=1001 --clear-groups \
    chroot /srv/chroot /bin/bash -c "
    $RUNNER_ENV
    cd /opt/actions-runner && exec ./run.sh --once
"
RC=$?
persist_runner_config
exit "$RC"
