FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    wget \
    jq \
    git \
    tar \
    gzip \
    pigz \
    xz \
    rsync \
    findutils \
    coreutils \
    util-linux \
    sfdisk \
    parted \
    dosfstools \
    e2fsprogs \
    e2fsprogs-extra \
    debootstrap \
    debian-archive-keyring \
    u-boot-tools \
    file \
    mtools

# Build scripts are mounted from the repo at runtime: -v $PWD/scripts:/scripts
RUN mkdir -p /input /output /work

ENTRYPOINT ["/scripts/build.sh"]
