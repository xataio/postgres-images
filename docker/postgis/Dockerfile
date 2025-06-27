ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-bookworm
FROM ${CNPG_BASE}

USER root

# Install PostGIS and its dependencies
# Note: Using the standard (non-minimal) image as base, so we have more tools available
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-17-postgis-3 \
    postgresql-17-postgis-3-scripts \
    postgis \
    postgresql-contrib-17 \
    && rm -rf /var/lib/apt/lists/*

# Clean up
RUN apt-get clean

USER postgres