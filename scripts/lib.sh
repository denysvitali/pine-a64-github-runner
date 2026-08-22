#!/bin/bash
# Shared helpers for the image build pipeline.

set -euo pipefail

export LC_ALL=C
umask 022

: "${CACHE_PATH:=/input/build_cache}"
: "${ALPINE_MIRROR:=https://dl-cdn.alpinelinux.org/alpine}"
: "${ALPINE_BRANCH:=v3.22}"
: "${ARCH:=aarch64}"
: "${WORK:=/work}"

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# head(1) closes the pipe early, SIGPIPE-killing producers under pipefail.
# sed consumes all input, so pipelines into this helper never die with 141.
first_line() { sed -n '1p'; }

need_env() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] || die "Missing required env var: $v"
    done
}

fetch() {
    # fetch <url> <dest>
    local url="$1" dest="$2"
    log "Fetching $url"
    curl -fSL --retry 4 --retry-delay 5 -o "$dest" "$url"
}

verify_sha256() {
    # verify_sha256 <file> <expected-sha256-hex>
    local file="$1" expected="$2" actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        die "sha256 mismatch for $file: expected $expected got $actual"
    fi
    log "sha256 OK: $(basename "$file")"
}

mount_image_partition() {
    # mount_image_partition <img> <partnum> <mnt> -> echoes loopdev
    local img="$1" part="$2" mnt="$3"
    mkdir -p "$mnt"
    LOOPDEV=$(losetup --find --show --partscan "$img")
    trap 'losetup -d "$LOOPDEV" 2>/dev/null || true' EXIT INT TERM
    [ -b "${LOOPDEV}p${part}" ] || die "Loop partition ${LOOPDEV}p${part} not found"
    mount "${LOOPDEV}p${part}" "$mnt"
}

umount_all() {
    sync || true
    for m in "$@"; do
        umount "$m" 2>/dev/null || true
    done
}
