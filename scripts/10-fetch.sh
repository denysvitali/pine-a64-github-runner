#!/bin/bash
# Stage 10: fetch and verify upstream artifacts (Alpine minirootfs, actions-runner).
set -euo pipefail
source /scripts/lib.sh

mkdir -p "$CACHE_PATH"

log "Resolving minirootfs filename for $ALPINE_BRANCH/$ARCH"
LATEST_URL="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ARCH/latest-releases.yaml"
MINIROOTFS_NAME=$(curl -fsSL "$LATEST_URL" \
    | grep -o 'alpine-minirootfs-[0-9][0-9.]*-'"$ARCH"'\.tar\.gz' | head -1 || true)
[ -n "$MINIROOTFS_NAME" ] || die "Could not resolve minirootfs tarball name"
MINIROOTFS_URL="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ARCH/$MINIROOTFS_NAME"
SHA_URL="${MINIROOTFS_URL}.sha256"

fetch "$MINIROOTFS_URL" "$CACHE_PATH/minirootfs.tar.gz" &
fetch "$SHA_URL" "$CACHE_PATH/minirootfs.tar.gz.sha256" &
wait
verify_sha256 "$CACHE_PATH/minirootfs.tar.gz" "$(cat "$CACHE_PATH/minirootfs.tar.gz.sha256" | awk '{print $1}')"

# --- GitHub Actions runner ---
RUNNER_VERSION=${RUNNER_VERSION:-latest}
if [ "$RUNNER_VERSION" = "latest" ]; then
    log "Querying latest actions-runner release"
    RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)
    RUNNER_VERSION=${RUNNER_VERSION#v}
fi
case "$RUNNER_VERSION" in
    ''|*[!0-9.]*) die "Invalid RUNNER_VERSION: $RUNNER_VERSION" ;;
esac

TARBALL="actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"

if [ -f "$CACHE_PATH/$TARBALL" ] && [ "${SKIP_CACHE:-}" != "1" ]; then
    log "Using cached $TARBALL"
else
    fetch "$URL" "$CACHE_PATH/$TARBALL"
fi

# Integrity: official per-asset checksum file when present; else record digest.
if curl -fsSI "$URL.sha256" >/dev/null 2>&1; then
    fetch "$URL.sha256" "$CACHE_PATH/$TARBALL.sha256"
    verify_sha256 "$CACHE_PATH/$TARBALL" "$(awk '{print $1}' "$CACHE_PATH/$TARBALL.sha256")"
else
    warn "No official .sha256 asset for $TARBALL; recording digest only (set RUNNER_SHA256 to enforce)"
    [ -z "${RUNNER_SHA256:-}" ] || verify_sha256 "$CACHE_PATH/$TARBALL" "$RUNNER_SHA256"
fi

printf '%s\n' "$RUNNER_VERSION" > "$CACHE_PATH/runner_version"
log "Stage 10 complete: runner v$RUNNER_VERSION, minirootfs $MINIROOTFS_NAME"
