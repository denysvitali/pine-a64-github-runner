#!/bin/sh
# One ephemeral runner cycle. Supervised by OpenRC (supervise-daemon):
# every exit triggers teardown+fresh registration, giving pristine state per job.
#
# Layout:
#   /srv/chroot-template      RO Debian rootfs baked in the immutable slot
#   /srv/chroot               overlay(template, tmpfs upper) rebuilt every cycle
#   /srv/chroot/opt/actions-runner  overlay(template subdir, tmpfs upper) for creds
#   /data                     persistent ext4, bound into chroot at /data
#
# Required /data/conf/env (root-only readable):
#   GITHUB_URL=https://github.com/OWNER/REPO
#   GITHUB_TOKEN=<PAT used only to mint registration tokens>
#   RUNNER_LABELS=pine64,aarch64,self-hosted

CONF=/data/conf/env
[ -r "$CONF" ] || { echo "FATAL: $CONF missing/unreadable"; sleep 30; exit 1; }
. "$CONF"

: "${RUNNER_LABELS:=self-hosted,aarch64}"
: "${CHROOT_OVERLAY_SIZE:-512M}"
: "${MINT_RETRIES:=6}"

[ -n "${GITHUB_URL}" ] || { echo "FATAL: GITHUB_URL unset"; sleep 30; exit 1; }
[ -n "${GITHUB_TOKEN}" ] || { echo "FATAL: GITHUB_TOKEN unset"; sleep 30; exit 1; }

case "$GITHUB_URL" in
    https://github.com/*)
        REPO_PATH=${GITHUB_URL#https://github.com/}
        API_BASE=https://api.github.com ;;
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

mkdir -p /data/runner/home /data/runner/_work
chown 1001:1001 /data/runner/home /data/runner/_work
find /data/runner/_work -mindepth 1 -delete 2>/dev/null || true

RUNNER_NAME=${RUNNER_NAME:-$(hostname)}
if [ -z "${RUNNER_NAME_SET:-}" ]; then
    MAC=$(cat /sys/class/net/eth0/address 2>/dev/null | tail -c 6 | tr -d ':')
    [ -n "$MAC" ] && RUNNER_NAME="${RUNNER_NAME}-${MAC}"
fi

TOKEN=""
i=0
while [ $i -lt "$MINT_RETRIES" ]; do
    RESP=$(curl -sS --max-time 20 -X POST \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${API_BASE}/repos/${REPO_PATH}/actions/runners/registration-token" 2>/dev/null || true)
    TOKEN=$(printf '%s' "$RESP" | jq -r '.token // empty')
    [ -n "$TOKEN" ] && break
    i=$((i+1)); echo "[cycle] token mint failed ($i/$MINT_RETRIES), retrying"; sleep 15
done
[ -n "$TOKEN" ] || { echo "FATAL: could not mint registration token"; "$TEARDOWN" || true; exit 1; }

echo "[cycle] registering runner '${RUNNER_NAME}' (ephemeral)"
RUNNER_ENV="export HOME=/data/runner/home"
setpriv --reuid=1001 --regid=1001 --clear-groups \
    chroot /srv/chroot /bin/bash -c "
    $RUNNER_ENV
    cd /opt/actions-runner && \
    ./config.sh --url '${GITHUB_URL}' \
        --token '${TOKEN}' \
        --name '${RUNNER_NAME}' \
        --labels '${RUNNER_LABELS}' \
        --ephemeral --disableupdate --unattended --work /data/runner/_work
" || { echo "FATAL: config.sh failed"; "$TEARDOWN" || true; exit 1; }

echo "[cycle] starting runner listener"
exec setpriv --reuid=1001 --regid=1001 --clear-groups \
    chroot /srv/chroot /bin/bash -c "
    $RUNNER_ENV
    cd /opt/actions-runner && exec ./run.sh
"
