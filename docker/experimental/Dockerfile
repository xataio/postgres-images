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
COPY docker/experimental/extensions.json /tmp/extensions.json
# Generate plain version map for verification
RUN jq -r '.extensions[] | "\(.name) \(.version)"' /tmp/extensions.json > /usr/local/share/extensions-versions.txt

# Build pg_duckdb from source (DuckDB v1.3.2, no httpfs)
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      libreadline-dev \
      zlib1g-dev \
      flex \
      bison \
      libxml2-dev \
      libxslt-dev \
      libssl-dev \
      libxml2-utils \
      xsltproc \
      pkg-config \
      libc++-dev \
      libc++abi-dev \
      libglib2.0-dev \
      libtinfo6 \
      cmake \
      libstdc++-12-dev \
      liblz4-dev \
      ninja-build \
      postgresql-server-dev-17 \
      git \
  && rm -rf /var/lib/apt/lists/* \
  && cd /tmp \
  && git clone https://github.com/duckdb/pg_duckdb.git \
  && cd pg_duckdb \
  # Invalidate any prior cached build so our flags take effect
  && rm -rf third_party/duckdb/build/release \
  # Don't fetch remote extensions like httpfs, and turn httpfs off entirely \
  # disable the following: sanitizers, shell, python, unit test,  \
  # does not automagically load extensions at runtime \
  # does not automagicaly try to install extensions from the internet \
  #
  && export DUCKDB_EXTENSION_REMOTE_URLS="" \
  make GEN=ninja CMAKE_VARS="\
      -DENABLE_SANITIZER=FALSE  \
      -DENABLE_UBSAN=0 \
      -DBUILD_SHELL=0  \
      -DBUILD_PYTHON=0  \
      -DBUILD_UNITTESTS=0 \
      -DENABLE_EXTENSION_AUTOLOADING=0  \
      -DENABLE_EXTENSION_AUTOINSTALL=0 \
      -DDUCKDB_EXTENSION_CONFIGS=../pg_duckdb_extensions.cmake \
      -DOVERRIDE_GIT_DESCRIBE=v1.3.2 \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_HTTPFS=OFF"\
  && make install \
  && cd /tmp && rm -rf pg_duckdb \
  # Strip build toolchain to keep image small
  && apt-get purge -y --auto-remove \
       build-essential libreadline-dev zlib1g-dev flex bison libxml2-dev \
       libxslt-dev libssl-dev libxml2-utils xsltproc pkg-config libc++-dev \
       libc++abi-dev libglib2.0-dev cmake libstdc++-12-dev liblz4-dev \
       ninja-build git \
  && rm -rf /var/lib/apt/lists/*

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

# Verify locales are still available after cleanup
RUN echo "Available locales after cleanup:" && locale -a | wc -l && echo "locales installed"

USER postgres
