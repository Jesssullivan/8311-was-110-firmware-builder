FROM debian:bookworm-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        fakeroot \
        file \
        findutils \
        gawk \
        git \
        gzip \
        grep \
        jq \
        lz4 \
        mtd-utils \
        p7zip-full \
        perl \
        libdigest-crc-perl \
        python3 \
        sed \
        squashfs-tools \
        tar \
        u-boot-tools \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 builder
USER builder
WORKDIR /work

ENV SUDO=
