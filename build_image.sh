#!/bin/sh
# Build the Pine A64 GitHub-runner SD image in a container.
# Mirrors raspi-k3s DX: docker run builder with input/output mounts.
set -eu

cd "$(dirname "$0")"

DOCKER_IMAGE=${1:-pine-a64-gh-runner-builder:local}
PLATFORM=$(uname -m)
case "$PLATFORM" in
    x86_64) PLATFORM="linux/amd64" ;;
    aarch64|arm64) PLATFORM="linux/arm64" ;;
    *) echo "Unsupported host arch: $PLATFORM" >&2; exit 1 ;;
esac

[ -f .env ] || { echo "No .env found. cp .env.example .env and edit it." >&2; exit 1; }

mkdir -p input output input/build_cache

docker build --platform "$PLATFORM" -t "$DOCKER_IMAGE" ./builder

exec docker run \
    --rm \
    --platform "$PLATFORM" \
    --privileged \
    -v "$PWD/scripts:/scripts" \
    -v "$PWD/input:/input" \
    -v "$PWD/output:/output" \
    --env-file .env \
    "$DOCKER_IMAGE"
