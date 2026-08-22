#!/bin/bash
# Orchestrator: runs inside the builder container.
set -euo pipefail
source /scripts/lib.sh

need_env DEFAULT_HOSTNAME ALPINE_BRANCH ARCH RUNNER_VERSION SIZE_BOOT SIZE_SLOT SIZE_IMAGE \
         CMDLINE ROOT_OVERLAY_SIZE CHROOT_OVERLAY_SIZE

# tunables with defaults (settable via .env)
export SIZE_TMPFS=${SIZE_TMPFS:-256M}

# geometry sanity: DATA needs breathing room
MIN_IMAGE=$(( SIZE_BOOT + SIZE_SLOT * 2 + 512 ))
if [ "${SIZE_IMAGE:-0}" -lt "$MIN_IMAGE" ]; then
    warn "SIZE_IMAGE=${SIZE_IMAGE}M cannot fit BOOT+2 slots+DATA; bumping to ${MIN_IMAGE}M"
    export SIZE_IMAGE=$MIN_IMAGE
fi

mkdir -p /output "$WORK"

for stage in 10-fetch 20-rootfs 30-chroot 40-image; do
    log "=== stage $stage ==="
    "/scripts/$stage.sh"
done

log "Build finished."
