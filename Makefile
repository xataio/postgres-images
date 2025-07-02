# PostgreSQL CNPG Custom Image Makefile

# Configuration
REGISTRY ?= ghcr.io
IMAGE_NAME ?= xataio/postgres-images/cnpg-postgres-plus
CNPG_BASE ?= ghcr.io/cloudnative-pg/postgresql:17-minimal-bookworm
DOCKERFILE_DIR ?= docker/custom-postgres
DOCKERFILE ?= $(DOCKERFILE_DIR)/Dockerfile
PLATFORMS ?= linux/amd64,linux/arm64
DATE_TAG := $(shell date +%Y%m%d)
CONFIG_FILE := $(DOCKERFILE_DIR)/extensions.json

# Derived variables
FULL_IMAGE_NAME := $(REGISTRY)/$(IMAGE_NAME)

# extract names where preload_required==true, wrap each in single‐quotes,
# then join them with commas
PRELOAD_LIBS := $(shell \
  jq -r '.extensions[] | select(.preload_required==true) | .name' $(CONFIG_FILE) \
    | sed "s/.*/'&'/" \
    | paste -sd, - \
)

# now iterate the postgres_config array directly
CONFIG_CMDS := $(shell \
  jq -r ".postgres_config[] | \
    if (.value|test(\"^[0-9]+$$\")) then \
      \"ALTER SYSTEM SET \\(.setting) = \\(.value);\" \
    else \
      \"ALTER SYSTEM SET \\(.setting) = '\\(.value)';\" \
    end" \
    $(CONFIG_FILE) \
)
# Default target
.PHONY: help
help: ## Show this help message
	@echo "PostgreSQL CNPG Custom Image Build"
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: pull-base
pull-base: ## Pull the base CNPG PostgreSQL image
	@echo "Pulling base image: $(CNPG_BASE)"
	docker pull $(CNPG_BASE)

.PHONY: get-pg-version
get-pg-version: pull-base ## Get PostgreSQL version from base image
	$(eval PG_VERSION := $(shell docker run --rm $(CNPG_BASE) postgres -V | awk '{print $$3}'))
	@echo "PostgreSQL version: $(PG_VERSION)"

.PHONY: get-base-digest
get-base-digest: pull-base ## Get base image digest
	$(eval BASE_DIGEST := $(shell docker image inspect $(CNPG_BASE) --format '{{.Id}}'))
	@echo "Base image digest: $(BASE_DIGEST)"

.PHONY: build-local
build-local: get-pg-version get-base-digest ## Build image locally for testing (amd64 only)
	@echo "Building local image for testing..."
	docker build \
		-f $(DOCKERFILE) \
		-t $(FULL_IMAGE_NAME):latest \
		-t $(FULL_IMAGE_NAME):$(PG_VERSION) \
		-t $(FULL_IMAGE_NAME):$(PG_VERSION)-$(DATE_TAG) \
		--label "base.digest=$(BASE_DIGEST)" \
		--label "org.opencontainers.image.source=https://github.com/xataio/postgres-images" \
		--label "org.opencontainers.image.description=CNPG PostgreSQL with additional extensions and tools" \
		--label "org.opencontainers.image.licenses=PostgreSQL" \
		--build-arg CNPG_BASE=$(CNPG_BASE) \
		.

.PHONY: test
test: ## Run tests on the built image
	@echo "Running tests on $(FULL_IMAGE_NAME)"
	@docker rm -f pg-test 2>/dev/null || true

	@echo "Starting PostgreSQL container..."
	docker run -d --name pg-test \
		-e POSTGRES_PASSWORD=test \
		-e POSTGRES_INITDB_ARGS="--auth-host=trust" \
		-e PGDATA=/var/lib/postgresql/data \
		--user postgres \
		"$(FULL_IMAGE_NAME):latest" \
		bash -c 'echo "Starting initialization..." && mkdir -p $$PGDATA && if [ ! -f $$PGDATA/PG_VERSION ]; then echo "Initializing database..." && initdb $$POSTGRES_INITDB_ARGS; fi && echo "Starting PostgreSQL..." && postgres'

	@echo "Waiting for PostgreSQL to be ready..."
	@timeout 60s bash -c 'until docker exec pg-test pg_isready 2>/dev/null; do sleep 2; done' || \
		(echo "=== Container failed to start, showing logs ===" && docker logs pg-test && exit 1)

	@echo "Testing basic functionality..."
	docker exec pg-test psql -U postgres -c "SELECT version();"

	@echo "Testing basic extensions..."
	@for ext in pg_partman pg_trgm pgcrypto citext hstore ltree pg_buffercache pg_freespacemap pg_visibility pgrowlocks moddatetime insert_username hypopg dblink; do \
		echo "Testing extension: $$ext"; \
		docker exec pg-test psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS \"$$ext\";" || exit 1; \
		docker exec pg-test psql -U postgres -c "\dx" | grep "$$ext" || exit 1; \
	done

	@echo "Testing wal2json plugin..."
	docker exec pg-test ls -la /usr/lib/postgresql/17/lib/wal2json.so

	@echo "Applying postgres_config settings…"
	@jq -r '.postgres_config[] \
	           | if (.value|type=="number") then \
	               "ALTER SYSTEM SET \(.setting) = \(.value);" \
	             else \
	               "ALTER SYSTEM SET \(.setting) = '\''\(.value)'\'';" \
	             end' $(CONFIG_FILE) \
	  | while IFS= read -r sql; do \
	      echo " → $$sql"; \
	      docker exec pg-test psql -U postgres -c "$$sql"; \
	    done

	@echo "Setting shared_preload_libraries to: $(PRELOAD_LIBS)"
	docker exec pg-test psql -U postgres -c "ALTER SYSTEM SET shared_preload_libraries TO $(PRELOAD_LIBS);"

	@echo "Restarting PostgreSQL..."
	docker restart pg-test
	@timeout 60s bash -c 'until docker exec pg-test pg_isready 2>/dev/null; do sleep 2; done' || \
		(echo "=== Container failed after restart, showing logs ===" && docker logs pg-test && exit 1)

	@echo "Verifying configuration..."
	docker exec pg-test psql -U postgres -c "SHOW wal_level;"
	docker exec pg-test psql -U postgres -c "SHOW shared_preload_libraries;"

	@echo "Testing preloaded extensions..."
	@for ext in pg_stat_statements pg_prewarm pg_cron; do \
		echo "Testing preloaded extension: $$ext"; \
		docker exec pg-test psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS \"$$ext\";" || exit 1; \
		docker exec pg-test psql -U postgres -c "\dx" | grep "$$ext" || exit 1; \
	done

	@echo "Testing auto_explain module..."
	docker exec pg-test psql -U postgres -c "SHOW shared_preload_libraries;" | grep "auto_explain"

	@echo "Configuring pg_cron..."
	docker exec pg-test psql -U postgres -c "ALTER SYSTEM SET cron.database_name = 'postgres';"
	docker exec pg-test psql -U postgres -c "SELECT pg_reload_conf();"

	@echo "Testing wal2json replication..."
	docker exec pg-test psql -U postgres -c "SELECT pg_create_logical_replication_slot('test_slot', 'wal2json');"
	docker exec pg-test psql -U postgres -c "CREATE TABLE test_wal2json (id SERIAL PRIMARY KEY, data TEXT);"
	docker exec pg-test psql -U postgres -c "INSERT INTO test_wal2json (data) VALUES ('test data');"
	docker exec pg-test psql -U postgres -c "SELECT data FROM pg_logical_slot_get_changes('test_slot', NULL, NULL, 'pretty-print', '1');"
	docker exec pg-test psql -U postgres -c "SELECT pg_drop_replication_slot('test_slot');"

	@echo "Testing additional functionality..."
	docker exec pg-test psql -U postgres -c "SELECT count(*) FROM pg_stat_statements;"
	docker exec pg-test psql -U postgres -c "SELECT cron.schedule('test-job', '* * * * *', 'SELECT 1;');"
	docker exec pg-test psql -U postgres -c "SELECT cron.unschedule('test-job');"

	@echo "Testing text search..."
	docker exec pg-test psql -U postgres -c "CREATE TABLE test_search (text_col text); INSERT INTO test_search VALUES ('hello world');"
	docker exec pg-test psql -U postgres -c "SELECT similarity('hello', text_col) FROM test_search;"

	@echo "Testing hstore..."
	docker exec pg-test psql -U postgres -c "CREATE TABLE test_hstore (data hstore); INSERT INTO test_hstore VALUES ('key=>value');"
	docker exec pg-test psql -U postgres -c "SELECT data->'key' FROM test_hstore;"

	@echo "Testing hypopg..."
	docker exec pg-test psql -U postgres -c "SELECT hypopg_create_index('CREATE INDEX ON test_search (text_col)');"
	docker exec pg-test psql -U postgres -c "SELECT hypopg_reset();"

	@echo "Listing available extensions..."
	docker exec pg-test psql -U postgres -c "SELECT name FROM pg_available_extensions ORDER BY name;"

	@echo "Cleaning up test container..."
	docker rm -f pg-test
	@echo "All tests passed!"

.PHONY: build-and-test
build-and-test: build-local test ## Build locally and run tests

.PHONY: setup-buildx
setup-buildx: ## Setup Docker buildx for multi-platform builds
	@if ! docker buildx ls | grep -q multiarch; then \
		echo "Creating buildx instance for multi-platform builds..."; \
		docker buildx create --name multiarch --use --platform $(PLATFORMS); \
	else \
		echo "Using existing buildx instance..."; \
		docker buildx use multiarch; \
	fi

.PHONY: build-multiarch
build-multiarch: get-pg-version get-base-digest setup-buildx ## Build multi-architecture image (no push)
	@echo "Building multi-architecture image..."
	docker buildx build \
		-f $(DOCKERFILE) \
		--platform $(PLATFORMS) \
		-t $(FULL_IMAGE_NAME):latest \
		-t $(FULL_IMAGE_NAME):$(PG_VERSION) \
		-t $(FULL_IMAGE_NAME):$(PG_VERSION)-$(DATE_TAG) \
		--label "base.digest=$(BASE_DIGEST)" \
		--label "org.opencontainers.image.source=https://github.com/xataio/postgres-images" \
		--label "org.opencontainers.image.description=CNPG PostgreSQL with additional extensions and tools" \
		--label "org.opencontainers.image.licenses=PostgreSQL" \
		--build-arg CNPG_BASE=$(CNPG_BASE) \
		.

.PHONY: push-multiarch
push-multiarch: get-pg-version get-base-digest setup-buildx ## Build and push multi-architecture image
	@echo "Building and pushing multi-architecture image..."
	docker buildx build \
		-f $(DOCKERFILE) \
		--platform $(PLATFORMS) \
		-t $(FULL_IMAGE_NAME):latest \
		-t $(FULL_IMAGE_NAME):$(PG_VERSION) \
		-t $(FULL_IMAGE_NAME):$(PG_VERSION)-$(DATE_TAG) \
		--label "base.digest=$(BASE_DIGEST)" \
		--label "org.opencontainers.image.source=https://github.com/xataio/postgres-images" \
		--label "org.opencontainers.image.description=CNPG PostgreSQL with additional extensions and tools" \
		--label "org.opencontainers.image.licenses=PostgreSQL" \
		--build-arg CNPG_BASE=$(CNPG_BASE) \
		--push \
		.
	@echo "Multi-architecture images pushed to $(FULL_IMAGE_NAME)"
	@echo "Available tags: latest, $(PG_VERSION), $(PG_VERSION)-$(DATE_TAG)"
	@echo "Platforms: $(PLATFORMS)"

.PHONY: check-base-updated
check-base-updated: get-base-digest ## Check if base image has been updated
	@echo "Checking if base image has been updated..."
	@if docker pull $(FULL_IMAGE_NAME):latest 2>/dev/null; then \
		EXISTING_DIGEST=$$(docker image inspect $(FULL_IMAGE_NAME):latest --format '{{index .Config.Labels "base.digest"}}' 2>/dev/null || echo ""); \
		if [ "$$EXISTING_DIGEST" = "$(BASE_DIGEST)" ]; then \
			echo "Base image unchanged, no rebuild needed"; \
			exit 1; \
		else \
			echo "Base image updated, rebuild needed"; \
		fi; \
	else \
		echo "No existing image found, build needed"; \
	fi

.PHONY: clean
clean: ## Clean up Docker resources
	@echo "Cleaning up..."
	-docker rm -f pg-test 2>/dev/null
	-docker system prune -f
	@echo "Cleanup complete"

.PHONY: show-info
show-info: get-pg-version get-base-digest ## Show build information
	@echo "=== Build Information ==="
	@echo "Registry: $(REGISTRY)"
	@echo "Image Name: $(IMAGE_NAME)"
	@echo "Full Image: $(FULL_IMAGE_NAME)"
	@echo "Base Image: $(CNPG_BASE)"
	@echo "PostgreSQL Version: $(PG_VERSION)"
	@echo "Base Digest: $(BASE_DIGEST)"
	@echo "Date Tag: $(DATE_TAG)"
	@echo "Platforms: $(PLATFORMS)"
	@echo "Dockerfile: $(DOCKERFILE)"

# CI-friendly target that mirrors the GitHub Actions logic
.PHONY: ci-build
ci-build: ## CI build process (build, test, and conditionally push)
	@echo "Starting CI build process..."
	@if $(MAKE) check-base-updated 2>/dev/null; then \
		echo "Base image updated, proceeding with build..."; \
		$(MAKE) build-and-test && \
		$(MAKE) push-multiarch; \
	else \
		echo "Base image unchanged, skipping build"; \
	fi