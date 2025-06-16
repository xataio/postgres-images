ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17
FROM ${CNPG_BASE}

USER root

# Add PostgreSQL APT repository
RUN apt-get update && apt-get install -y --no-install-recommends wget gnupg lsb-release \
    && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && apt-get update

# Install desired extensions
RUN apt-get install -y --no-install-recommends \
    postgresql-17-partman \
    postgresql-contrib-17 \
    postgresql-17-wal2json \
    postgresql-17-cron \
    postgresql-17-hypopg \
    && rm -rf /var/lib/apt/lists/*

USER postgres