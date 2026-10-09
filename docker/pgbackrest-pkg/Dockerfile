# Builds a pgBackRest .deb from source and ships it in a scratch image, the
# same pattern as docker/pg-duckdb-pkg. The .deb is consumed by the runtime
# image Dockerfiles (analytics, minimal, custom-postgres, experimental).
#
# This is for supporting (temporarily) running unreleased pgBackRest versions.
#
# The pgBackRest binary is PostgreSQL-major agnostic, so a single .deb is built
# per architecture and reused across every image and PG major.

ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-minimal-bookworm
FROM ${CNPG_BASE}

# Pin to the exact commit for reproducibility (not the moving `integration` branch).
ARG PGBACKREST_REPO=https://github.com/pgbackrest/pgbackrest.git
ARG PGBACKREST_COMMIT=1d217e626301118ae2c1e7be39a6a4affa86e501
ARG PGBACKREST_VERSION=2.60.0dev
# TARGETARCH is auto-populated by buildx per target platform (amd64 / arm64),
# so the .deb Architecture field is correct even in a single multi-arch build.
ARG TARGETARCH

USER root

# Build dependencies.
# Required by meson.build: liblz4, openssl, libpq, libxml-2.0, zlib, bz2.
# Optional (auto-detected): libzstd, libssh2, libsystemd.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    meson \
    ninja-build \
    pkg-config \
    git \
    ca-certificates \
    python3 \
    python3-yaml \
    libssl-dev \
    libxml2-dev \
    liblz4-dev \
    libzstd-dev \
    libbz2-dev \
    libssh2-1-dev \
    libsystemd-dev \
    zlib1g-dev \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Build pgBackRest with meson/ninja. --prefix=/usr so the binary lands at
# /usr/bin/pgbackrest, matching the location of the upstream apt package.
RUN git clone "${PGBACKREST_REPO}" /tmp/pgbackrest \
    && cd /tmp/pgbackrest \
    && git checkout "${PGBACKREST_COMMIT}" \
    && meson setup /tmp/build /tmp/pgbackrest --prefix=/usr --buildtype=release \
    && ninja -C /tmp/build \
    && DESTDIR=/tmp/pgbackrest_install ninja -C /tmp/build install \
    && /tmp/pgbackrest_install/usr/bin/pgbackrest version

# Create the .deb package.
RUN PKG_NAME="pgbackrest" && \
    SHORT_SHA="$(git -C /tmp/pgbackrest rev-parse --short HEAD)" && \
    PKG_VERSION="${PGBACKREST_VERSION}+git${SHORT_SHA}" && \
    DEB_NAME="${PKG_NAME}-${PKG_VERSION}-${TARGETARCH}-linux-gnu" && \
    DEB_DIR="/tmp/${DEB_NAME}" && \
    mkdir -p "${DEB_DIR}/DEBIAN" && \
    cp -r /tmp/pgbackrest_install/usr "${DEB_DIR}/" && \
    echo "Package: ${PKG_NAME}" > "${DEB_DIR}/DEBIAN/control" && \
    echo "Version: ${PKG_VERSION}" >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Architecture: ${TARGETARCH}" >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Maintainer: Xata <support@xata.io>" >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Depends: libc6, libssl3, libxml2, liblz4-1, libzstd1, libbz2-1.0, libssh2-1, libsystemd0, zlib1g, libpq5" >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Description: Reliable PostgreSQL backup and restore (built from source)" >> "${DEB_DIR}/DEBIAN/control" && \
    echo " pgBackRest built from pgbackrest/pgbackrest@${SHORT_SHA} for the" >> "${DEB_DIR}/DEBIAN/control" && \
    echo " unreleased GCS Workload Identity Federation web-id key type (PR #2839)." >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Homepage: https://pgbackrest.org" >> "${DEB_DIR}/DEBIAN/control" && \
    dpkg-deb --build "${DEB_DIR}" && \
    mkdir -p /output && \
    mv "/tmp/${DEB_NAME}.deb" /output/pgbackrest.deb && \
    echo "Created: ${DEB_NAME}.deb"

# Final stage - minimal image with just the .deb
FROM scratch
COPY --from=0 /output/pgbackrest.deb /pgbackrest.deb
