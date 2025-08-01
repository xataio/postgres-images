ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-minimal-bookworm
FROM ${CNPG_BASE}

USER root

# Install missing tools that minimal image doesn't have
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    gnupg \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install all locales
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales \
    locales-all \
    && rm -rf /var/lib/apt/lists/*

# Generate all locales (this ensures they're available for PostgreSQL)
# The locales-all package should provide most locales, but we'll also
# uncomment all locales in locale.gen and generate them to be thorough
RUN sed -i 's/^# *\([a-zA-Z0-9_]\)/\1/' /etc/locale.gen && \
    locale-gen

# Verify locales are available
RUN locale -a | head -20 && echo "... and more locales available"

# Add PostgreSQL APT repository (detect codename without lsb_release)
RUN CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"') && \
    echo "deb http://apt.postgresql.org/pub/repos/apt $CODENAME-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg && \
    apt-get update

# Copy extensions.json into image
COPY docker/custom-postgres/extensions.json /tmp/extensions.json

# Install all necessary packages from extensions.json
RUN PKGS=$(jq -r '.extensions[].package' /tmp/extensions.json | sort -u | xargs) && \
    echo "Installing packages: $PKGS" && \
    apt-get install -y --no-install-recommends $PKGS && \
    rm -rf /var/lib/apt/lists/*

# Install PostGIS extensions and additional dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-17-postgis-3 \
    postgresql-17-postgis-3-scripts \
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

# Test if PostGIS tools are available and working
RUN which shp2pgsql || echo "shp2pgsql not found" && \
    which pgsql2shp || echo "pgsql2shp not found" && \
    which raster2pgsql || echo "raster2pgsql not found"

# Remove tools
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

# Verify locales are still available after cleanup
RUN echo "Available locales after cleanup:" && locale -a | wc -l && echo "locales installed"

USER postgres