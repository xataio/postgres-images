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

USER postgres