#!/bin/bash
# Orchestrator: runs inside the builder container.
set -euo pipefail
source /scripts/lib.sh

need_env DEFAULT_HOSTNAME ALPINE_BRANCH ARCH RUNNER_VERSION SIZE_BOOT SIZE_SLOT SIZE_IMAGE \
         CMDLINE ROOT_OVERLAY_SIZE CHROOT_OVERLAY_SIZE

# tunables with defaults (settable via .env)
export SIZE_TMPFS=${SIZE_TMPFS:-256M}
mkdir -p /output "$WORK"

for stage in 10-fetch 20-rootfs 30-chroot 40-image; do
    log "=== stage $stage ==="
    "/scripts/$stage.sh"
done

log "Build finished."
