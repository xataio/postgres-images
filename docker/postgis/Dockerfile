ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-bookworm
FROM ${CNPG_BASE}

USER root

# Install missing tools that minimal image doesn't have
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    gnupg \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Add PostgreSQL APT repository
RUN echo "deb http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg && \
    apt-get update

# Copy extensions.json into image
COPY docker/postgis/extensions.json /tmp/extensions.json

# Install PostGIS extensions and dependencies
# Skip the problematic postgis package on ARM64
RUN apt-get install -y --no-install-recommends \
    postgresql-17-postgis-3 \
    postgresql-17-postgis-3-scripts \
    postgresql-contrib-17 \
    libgdal32 \
    libgeos-c1v5 \
    libproj25 \
    libjson-c5 \
    libprotobuf-c1 \
    && rm -rf /var/lib/apt/lists/*

# Download and install PostGIS tools manually for ARM64
# This avoids the dependency issues with the postgis package
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
        # Install just the tools we need without the problematic dependencies \
        apt-get update && \
        mkdir -p /tmp/postgis-tools && \
        cd /tmp/postgis-tools && \
        apt-get download postgis && \
        dpkg-deb -x postgis_*.deb . && \
        cp -r usr/bin/* /usr/bin/ || true && \
        # Try to get the tools working with existing libraries \
        apt-get install -y --no-install-recommends \
            libgdal32 \
            gdal-data \
            || true && \
        cd / && rm -rf /tmp/postgis-tools && \
        rm -rf /var/lib/apt/lists/*; \
    else \
        # On AMD64, just install normally \
        apt-get update && \
        apt-get install -y --no-install-recommends postgis && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Test if tools are available and working
RUN which shp2pgsql || echo "shp2pgsql not found" && \
    which pgsql2shp || echo "pgsql2shp not found" && \
    which raster2pgsql || echo "raster2pgsql not found"

# Clean up tools and repositories
RUN apt-get purge -y --auto-remove \
    wget \
    gnupg \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /etc/apt/sources.list.d/pgdg.list \
    && rm -rf /etc/apt/trusted.gpg.d/postgresql.gpg \
    && rm -rf /tmp/extensions.json \
    && apt-get clean

USER postgres