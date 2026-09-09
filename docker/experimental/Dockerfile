ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-minimal-bookworm
FROM ${CNPG_BASE}

# Build-time knobs (overridden by Makefile)
# PG_MAJOR is used for package names/paths (17, 18, etc.)
ARG PG_MAJOR=17
# Per-major extension manifest (set by Makefile)
ARG CONFIG_FILE=docker/experimental/extensions.${PG_MAJOR}.json
ARG POSTGIS_CLI_VERSION_17=
ARG PG_DEV_VERSION=""
# PGDG package suffix for the base image's Debian suite: pgdg12 on bookworm,
# pgdg13 on trixie. Set by the Makefile from DEBIAN_SUITE.
ARG PGDG_SUFFIX=pgdg12+1

# Prepend the version-specific postgres bindir to PATH, so that we run the binaries
# directly, rather than through the debian wrapper.
ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"

USER root

# Hold PostgreSQL packages at current version if pinning is requested
RUN if [ -n "${PG_DEV_VERSION}" ]; then \
        echo "=== Holding PostgreSQL at version ${PG_DEV_VERSION} ===" && \
        echo "postgresql-${PG_MAJOR} hold" | dpkg --set-selections && \
        echo "postgresql-${PG_MAJOR}-client hold" | dpkg --set-selections && \
        echo "postgresql-client-common hold" | dpkg --set-selections && \
        echo "postgresql-common hold" | dpkg --set-selections; \
    fi

# Install missing tools that minimal image doesn't have
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    gnupg \
    ca-certificates \
    jq \
    unzip \
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

# Enable Percona repo/channel and install only percona-* packages from JSON, then disable Percona
# Enable Percona ONLY for majors that have a channel; skip for PG18+
RUN set -eux; \
  if [ "${PG_MAJOR}" -ge 18 ]; then \
    echo "Skipping Percona setup for PG${PG_MAJOR} (ppg-${PG_MAJOR} not available)"; \
  else \
    apt-get update && apt-get install -y --no-install-recommends curl lsb-release; \
    CODENAME="$(. /etc/os-release; echo "$VERSION_CODENAME")"; \
    wget -O /tmp/percona-release.deb "https://repo.percona.com/apt/percona-release_latest.${CODENAME}_all.deb"; \
    dpkg -i /tmp/percona-release.deb; rm -f /tmp/percona-release.deb; \
    percona-release setup -y "ppg-${PG_MAJOR}"; \
    apt-get update; \
    PERCONA_PKGS="$(jq -r '.extensions[] | select((.package? // "") | startswith("percona-")) \
     | if (.package_version and (.package_version != "")) then "\(.package)=\(.package_version)" else .package end' \
     /tmp/extensions.json | sort -u | tr '\n' ' ' )"; \
    echo "Percona packages to install: ${PERCONA_PKGS:-<none>}"; \
    if [ -n "${PERCONA_PKGS}" ]; then  \
      apt-get install -y --no-install-recommends ${PERCONA_PKGS};  \
    fi; \
    rm -f /etc/apt/sources.list.d/percona*.list; \
    apt-get update; \
  fi

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
     '.extensions[] | select(.package != $v) | select((.package? // "") | startswith("percona-") | not) | select(.package_version and (.package_version != "")) | "\(.package)=\(.package_version)"' \
    /tmp/extensions.json | sort -u | tr '\n' ' ' )"; \
  echo "Installing pinned (PG${PG_MAJOR}): ${PINNED_PKGS}"; \
  if [ -n "${PINNED_PKGS}" ]; then \
    apt-get update && apt-get install -y --no-install-recommends ${PINNED_PKGS}; \
  fi; \
  rm -rf /var/lib/apt/lists/*

# Pin unqualified pg_catalog builtins in ip4r's extension scripts.
COPY docker/custom-postgres/harden-ip4r-scripts.sh /tmp/harden-ip4r-scripts.sh
RUN bash /tmp/harden-ip4r-scripts.sh "/usr/share/postgresql/${PG_MAJOR}/extension" \
    && rm -f /tmp/harden-ip4r-scripts.sh

# Install PostGIS extensions and additional dependencies
# GDAL/GEOS/PROJ/json-c/protobuf-c are pulled in as dependencies of
# postgresql-${PG_MAJOR}-postgis-3. Do not name them here: the package names
# carry the library ABI version (libgdal32, libgeos-c1v5, ...) and those names
# change between Debian suites, so a hardcoded list breaks on a suite bump.
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-${PG_MAJOR}-postgis-3 \
    postgresql-${PG_MAJOR}-postgis-3-scripts \
    && rm -rf /var/lib/apt/lists/*

# Download and install PostGIS tools manually for ARM64
# Use pinned package version matching the SQL extension version (3.6.4)
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
        POSTGIS_PKG_VERSION=3.6.4+dfsg-2.${PGDG_SUFFIX} && \
        apt-get update && \
        mkdir -p /tmp/postgis-tools && \
        cd /tmp/postgis-tools && \
        echo "Downloading pinned postgis CLI: ${POSTGIS_PKG_VERSION}"; \
        apt-get download postgis=${POSTGIS_PKG_VERSION} && \
        dpkg-deb -x postgis_*.deb . && cp -r usr/bin/* /usr/bin/ || true; \
        # dpkg-deb -x skips dependency resolution, so pull the shared libraries
        # back in via the package that declares them, not by hardcoded name.
        apt-get install -y --no-install-recommends \
            postgresql-${PG_MAJOR}-postgis-3 \
            gdal-data \
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

# Install pgbackrest from PostgreSQL APT repository
RUN apt-get update && apt-get install -y --no-install-recommends \
    pgbackrest


# Verify pgbackrest installation
RUN pgbackrest version

# Install xatautils extension using Docker secrets for GitHub token
RUN --mount=type=secret,id=github_token \
    ARCH=$(dpkg --print-architecture) && \
    if [ ! -f "/run/secrets/github_token" ]; then \
        echo "ERROR: GitHub token secret is required to access private xata-utils repository"; \
        exit 1; \
    fi && \
    GITHUB_TOKEN=$(cat /run/secrets/github_token) && \
    # Pin to the version in the extension manifest
    XATA_VERSION="v$(jq -r '.extensions[] | select(.name=="xatautils") | .version' /tmp/extensions.json)" && \
    if [ "$XATA_VERSION" = "v" ] || [ "$XATA_VERSION" = "vnull" ]; then \
        echo "ERROR: no xatautils version pinned in the extension manifest"; \
        exit 1; \
    fi && \
    echo "Pinned xatautils version: ${XATA_VERSION}" && \
    # Get the release info to find the asset download URL
    RELEASE_INFO=$(wget --header="Authorization: token $GITHUB_TOKEN" \
                        --header="Accept: application/vnd.github.v3+json" \
                        -O- -q \
                        "https://api.github.com/repos/xataio/xata-utils/releases/tags/${XATA_VERSION}") && \
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
    # verify-extensions.sh skips xatautils, so check the installed version here
    INSTALLED_XATA_VERSION="$(dpkg-query -W -f='${Version}' xatautils)" && \
    if [ "$INSTALLED_XATA_VERSION" != "${XATA_VERSION#v}" ]; then \
        echo "ERROR: installed xatautils ${INSTALLED_XATA_VERSION} != pinned ${XATA_VERSION}"; \
        exit 1; \
    fi && \
    echo "Installed xatautils: ${INSTALLED_XATA_VERSION}" && \
    rm /tmp/xatautils.deb;

# Install pg_deltax from the public GitHub release (deb assets exist for PG17+).
# Driven by the per-major manifest: skipped when the extension is not listed.
RUN set -eux; \
    DELTAX_VERSION="$(jq -r '.extensions[] | select(.name=="pg_deltax") | .version' /tmp/extensions.json)"; \
    if [ -n "${DELTAX_VERSION}" ]; then \
      ARCH=$(dpkg --print-architecture); \
      wget -O /tmp/pg-deltax.deb \
        "https://github.com/xataio/deltax/releases/download/v${DELTAX_VERSION}/pg-deltax-pg${PG_MAJOR}_${DELTAX_VERSION}_${ARCH}.deb"; \
      dpkg -i /tmp/pg-deltax.deb; \
      rm -f /tmp/pg-deltax.deb; \
    else \
      echo "pg_deltax not in manifest for PG${PG_MAJOR}, skipping"; \
    fi

# Install pg_textsearch from the public GitHub release (zip wrapping a deb, per arch).
# Driven by the per-major manifest: skipped when the extension is not listed.
RUN set -eux; \
    TEXTSEARCH_VERSION="$(jq -r '.extensions[] | select(.name=="pg_textsearch") | .version' /tmp/extensions.json)"; \
    if [ -n "${TEXTSEARCH_VERSION}" ]; then \
      ARCH=$(dpkg --print-architecture); \
      wget -O /tmp/pg-textsearch.zip \
        "https://github.com/timescale/pg_textsearch/releases/download/v${TEXTSEARCH_VERSION}/pg-textsearch-v${TEXTSEARCH_VERSION}-pg${PG_MAJOR}-${ARCH}.zip"; \
      unzip -o /tmp/pg-textsearch.zip -d /tmp/pg-textsearch; \
      dpkg -i /tmp/pg-textsearch/*.deb; \
      rm -rf /tmp/pg-textsearch.zip /tmp/pg-textsearch; \
    else \
      echo "pg_textsearch not in manifest for PG${PG_MAJOR}, skipping"; \
    fi

# Remove tools
RUN set -eux; \
    if [ "${PG_MAJOR}" -ge 18 ]; then \
      apt-get purge -y --auto-remove \
        wget \
        gnupg \
        jq \
        unzip; \
    else \
      apt-get purge -y --auto-remove \
        wget \
        gnupg \
        jq \
        unzip \
        curl \
        lsb-release; \
    fi; \
    rm -rf /var/lib/apt/lists/* \
    && rm -rf /etc/apt/sources.list.d/pgdg.list \
    && rm -rf  /etc/apt/trusted.gpg.d/postgresql.gpg \
    && rm -rf  /tmp/extensions.json \
    && apt-get clean


# Add version verification script AFTER cleanup (so it persists)
RUN cat <<'EOF' > /usr/local/bin/verify-extensions.sh
#!/bin/bash
set -e

echo "Verifying SQL extension versions..."
mismatches=()

while read -r name expected_version; do
    # Skip preload-only modules or non-creatable ones
    if [[ "$name" == "auto_explain" || "$name" == "auth_delay" || "$name" == "wal2json" ]]; then
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
