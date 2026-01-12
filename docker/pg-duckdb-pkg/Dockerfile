ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-minimal-bookworm
FROM ${CNPG_BASE}

ARG PG_MAJOR=17
ARG PG_DUCKDB_VERSION=v1.0.0
ARG DUCKDB_VERSION=v1.3.2
ARG ARCH=amd64

USER root

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    gnupg \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Add PostgreSQL APT repository
RUN CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"') && \
    echo "deb http://apt.postgresql.org/pub/repos/apt $CODENAME-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg && \
    apt-get update

# Install build dependencies
RUN apt-get install -y --no-install-recommends \
    build-essential \
    zlib1g-dev \
    cmake \
    ninja-build \
    git \
    pkg-config \
    ccache \
    libssl-dev \
    liblz4-dev \
    postgresql-server-dev-${PG_MAJOR} \
    && rm -rf /var/lib/apt/lists/*

# Build pg_duckdb
RUN cd /tmp \
    && git clone https://github.com/duckdb/pg_duckdb.git \
    && cd pg_duckdb \
    && git checkout ${PG_DUCKDB_VERSION} \
    && export DUCKDB_EXTENSION_REMOTE_URLS="" \
    && make GEN=ninja \
        BUILD_SHELL=0 BUILD_PYTHON=0 BUILD_UNITTESTS=0 BUILD_HTTPFS=0 \
        EXTENSION_CONFIGS="" \
        CMAKE_VARS="\
          -DENABLE_SANITIZER=FALSE \
          -DENABLE_UBSAN=0 \
          -DENABLE_EXTENSION_AUTOLOADING=0 \
          -DENABLE_EXTENSION_AUTOINSTALL=0 \
          -DOVERRIDE_GIT_DESCRIBE=${DUCKDB_VERSION} \
          -DCMAKE_BUILD_TYPE=Release" \
    && make install DESTDIR=/tmp/pg_duckdb_install

# Create .deb package
RUN PKG_NAME="pg-duckdb" && \
    PKG_VERSION="${PG_DUCKDB_VERSION#v}" && \
    DEB_NAME="${PKG_NAME}-${PG_DUCKDB_VERSION}-pg${PG_MAJOR}-${ARCH}-linux-gnu" && \
    DEB_DIR="/tmp/${DEB_NAME}" && \
    mkdir -p "${DEB_DIR}/DEBIAN" && \
    cp -r /tmp/pg_duckdb_install/usr "${DEB_DIR}/" && \
    echo "Package: ${PKG_NAME}" > "${DEB_DIR}/DEBIAN/control" && \
    echo "Version: ${PKG_VERSION}" >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Architecture: ${ARCH}" >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Maintainer: Xata <support@xata.io>" >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Description: DuckDB integration for PostgreSQL ${PG_MAJOR}" >> "${DEB_DIR}/DEBIAN/control" && \
    echo " pg_duckdb is a PostgreSQL extension that integrates DuckDB analytical" >> "${DEB_DIR}/DEBIAN/control" && \
    echo " query engine directly into PostgreSQL. Built with DuckDB ${DUCKDB_VERSION}." >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Depends: postgresql-${PG_MAJOR}" >> "${DEB_DIR}/DEBIAN/control" && \
    echo "Homepage: https://github.com/duckdb/pg_duckdb" >> "${DEB_DIR}/DEBIAN/control" && \
    dpkg-deb --build "${DEB_DIR}" && \
    mkdir -p /output && \
    mv "/tmp/${DEB_NAME}.deb" /output/pg-duckdb.deb && \
    echo "Created: ${DEB_NAME}.deb"

# Final stage - minimal image with just the .deb
FROM scratch
COPY --from=0 /output/pg-duckdb.deb /pg-duckdb.deb
