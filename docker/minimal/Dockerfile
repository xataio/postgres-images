ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-minimal-bookworm
FROM ${CNPG_BASE}

# Build-time knobs (overridden by Makefile)
ARG PG_MAJOR=17
ARG CONFIG_FILE=docker/minimal/extensions.${PG_MAJOR}.json

# Prepend the version-specific postgres bindir to PATH, so that we run the binaries
# directly, rather than through the debian wrapper.
ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"

USER root

# Install missing tools that minimal image doesn't have
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    gnupg \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Add PostgreSQL APT repository (detect codename without lsb_release)
RUN CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"') && \
    echo "deb http://apt.postgresql.org/pub/repos/apt $CODENAME-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg && \
    apt-get update

# Copy extensions file into image
COPY ${CONFIG_FILE} /tmp/extensions.json

# Generate plain version map for verification
RUN jq -r '.extensions[] | "\(.name) \(.version)"' /tmp/extensions.json > /usr/local/share/extensions-versions.txt

# Install pgbackrest from PostgreSQL APT repository
RUN apt-get update && apt-get install -y --no-install-recommends \
    pgbackrest \
    && rm -rf /var/lib/apt/lists/*


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
    rm /tmp/xatautils.deb

# Remove build tools (keep ca-certificates for pgbackrest TLS connections)
RUN apt-get purge -y --auto-remove \
    wget \
    gnupg \
    jq \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /etc/apt/sources.list.d/pgdg.list \
    && rm -rf /etc/apt/trusted.gpg.d/postgresql.gpg \
    && rm -rf /tmp/extensions.json \
    && apt-get clean

# Add version verification script
RUN cat <<'EOF' > /usr/local/bin/verify-extensions.sh
#!/bin/bash
set -e

echo "Verifying SQL extension versions..."
mismatches=()

while read -r name expected_version; do
    # Skip xatautils as it's verified via file_check
    if [[ "$name" == "xatautils" ]]; then
        echo "Skipping SQL version check for ${name}"
        continue
    fi

    actual_version=$(psql -tAc "SELECT default_version FROM pg_available_extensions WHERE name='${name}';" 2>/dev/null | xargs)
    if [ -z "$actual_version" ]; then
        mismatches+=("Extension '${name}' not found (expected ${expected_version})")
    elif [ "$actual_version" != "$expected_version" ]; then
        mismatches+=("Extension '${name}': expected ${expected_version}, found ${actual_version}")
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

USER postgres
