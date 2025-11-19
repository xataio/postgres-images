ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-minimal-bookworm
FROM ${CNPG_BASE}

# Build-time knobs (overridden by Makefile)
# PG_MAJOR is used for package names/paths (17, 18, etc.)
ARG PG_MAJOR=17
# Per-major extension manifest (set by Makefile)
ARG CONFIG_FILE=docker/custom-postgres/extensions.${PG_MAJOR}.json
ARG POSTGIS_CLI_VERSION_17=

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

# Copy extensions file into image
COPY ${CONFIG_FILE} /tmp/extensions.json
# Generate plain version map for verification
RUN jq -r '.extensions[] | "\(.name) \(.version)"' /tmp/extensions.json > /usr/local/share/extensions-versions.txt



# Install pinned package versions (skip contrib virtual and ignore blank pins)
# - postgresql-contrib-${PG_MAJOR} is virtual so it does not get a proper version
# - for RC builds we allow empty package_version to pull the latest
# Assumes: ARG PG_MAJOR and /tmp/extensions.json already COPY'd
# Requires: jq installed earlier in the image
# Assumes: ARG PG_MAJOR and /tmp/extensions.json already COPY'd
# Requires: jq installed earlier
# Assumes: ARG PG_MAJOR and /tmp/extensions.json already COPY'd; jq is installed
RUN set -e; \
  VIRTUAL="postgresql-contrib-${PG_MAJOR}"; \
  PINNED_PKGS="$(jq -r --arg v "$VIRTUAL" \
    '.extensions[] | select(.package != $v) | select(.package_version and (.package_version != "")) | "\(.package)=\(.package_version)"' \
    /tmp/extensions.json | sort -u | tr '\n' ' ' )"; \
  echo "Installing pinned (PG${PG_MAJOR}): ${PINNED_PKGS}"; \
  if [ -n "${PINNED_PKGS}" ]; then \
    apt-get update && apt-get install -y --no-install-recommends ${PINNED_PKGS}; \
  fi; \
  rm -rf /var/lib/apt/lists/*

# Install PostGIS extensions and additional dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-${PG_MAJOR}-postgis-3 \
    postgresql-${PG_MAJOR}-postgis-3-scripts \
    libgdal32 \
    libgeos-c1v5 \
    libproj25 \
    libjson-c5 \
    libprotobuf-c1 \
    && rm -rf /var/lib/apt/lists/*

# Download and install PostGIS tools manually for ARM64
# Use pinned package version matching the SQL extension version (3.5.3)
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
        POSTGIS_PKG_VERSION=3.6.1+dfsg-1.pgdg12+1 && \
        apt-get update && \
        mkdir -p /tmp/postgis-tools && \
        cd /tmp/postgis-tools && \
        # For PG17 we prefer a pinned CLI version when provided; for others (e.g. 18-rc1) use latest if available.
        echo "Downloading pinned postgis CLI for PG17: ${POSTGIS_PKG_VERSION}"; \
        apt-get download postgis=${POSTGIS_PKG_VERSION} && \
        dpkg-deb -x postgis_*.deb . && cp -r usr/bin/* /usr/bin/ || true; \
        apt-get install -y --no-install-recommends \
            libgdal32 \
            gdal-data \
            libgeos-c1v5 \
            libproj25 \
            libjson-c5 \
            libprotobuf-c1 \
            || true && \
        cd / && rm -rf /tmp/postgis-tools && \
        rm -rf /var/lib/apt/lists/*; \
    else \
        apt-get update && \
        apt-get install -y --no-install-recommends postgis && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Test if PostGIS tools are available and working
RUN which shp2pgsql || echo "shp2pgsql not found" && \
    which pgsql2shp || echo "pgsql2shp not found" && \
    which raster2pgsql || echo "raster2pgsql not found"

# Install xatautils extension using Docker secrets for GitHub token
RUN --mount=type=secret,id=github_token \
    ARCH=$(dpkg --print-architecture) && \
    if [ ! -f "/run/secrets/github_token" ]; then \
        echo "ERROR: GitHub token secret is required to access private xata-utils repository"; \
        exit 1; \
    fi && \
    GITHUB_TOKEN=$(cat /run/secrets/github_token) && \
    # First, get the release info to find the asset download URL
    RELEASE_INFO=$(wget --header="Authorization: token $GITHUB_TOKEN" \
                        --header="Accept: application/vnd.github.v3+json" \
                        -O- -q \
                        "https://api.github.com/repos/xataio/xata-utils/releases/latest") && \
    # Extract the asset download URL for the specific file we need
    XATA_VERSION=$(printf '%s' "$RELEASE_INFO" | jq -r '.tag_name') && \
    ASSET_NAME="xatautils-${XATA_VERSION}-pg${PG_MAJOR}-${ARCH}-linux-gnu.deb" && \
    echo "Downloading xatautils extension: ${ASSET_NAME}..." && \
    DOWNLOAD_URL=$(printf '%s' "$RELEASE_INFO" | jq -r ".assets[] | select(.name==\"$ASSET_NAME\") | .url") && \
    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then \
        echo "ERROR: Asset ${ASSET_NAME} not found in release ${XATA_VERSION}"; \
        echo "Available assets:"; \
        echo "$RELEASE_INFO" | jq -r '.assets[].name'; \
        exit 1; \
    fi && \
    echo "Downloading from: $DOWNLOAD_URL" && \
    # Download the asset using the GitHub API
    wget --header="Authorization: token $GITHUB_TOKEN" \
         --header="Accept: application/octet-stream" \
         -O /tmp/xatautils.deb \
         "$DOWNLOAD_URL" && \
    dpkg -i /tmp/xatautils.deb && \
    rm /tmp/xatautils.deb

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


# Add version verification script AFTER cleanup (so it persists)
RUN cat <<'EOF' > /usr/local/bin/verify-extensions.sh
#!/bin/bash
set -e

echo "Verifying SQL extension versions..."
mismatches=()

while read -r name expected_version; do
    # Skip preload-only modules or non-creatable ones
    if [[ "$name" == "auto_explain" || "$name" == "wal2json" ]]; then
        so_path=$(find /usr/lib/postgresql -name "${name}.so" 2>/dev/null)
        if [[ -z "$so_path" ]]; then
            mismatches+=("Module '${name}' not found (.so missing)")
        fi
        continue
    fi

    if  [[ "$name" != "xatautils" ]]; then
        actual_version=$(psql -tAc "SELECT default_version FROM pg_available_extensions WHERE name='${name}';" 2>/dev/null | xargs)
        if [ -z "$actual_version" ]; then
            mismatches+=("Extension '${name}' not found (expected ${expected_version})")
        elif [ "$actual_version" != "$expected_version" ]; then
            mismatches+=("Extension '${name}': expected ${expected_version}, found ${actual_version}")
        fi
    else
        echo "Skipping SQL version check for ${name}"
    fi
done < /usr/local/share/extensions-versions.txt

if [ ${#mismatches[@]} -gt 0 ]; then
    echo "Version mismatches detected:"
    for mismatch in "${mismatches[@]}"; do
        echo "  - $mismatch"
    done
    exit 1
else
    echo "All extension versions match expected values."
fi
EOF

RUN chmod +x /usr/local/bin/verify-extensions.sh

# Verify locales are still available after cleanup
RUN echo "Available locales after cleanup:" && locale -a | wc -l && echo "locales installed"

USER postgres
