# PostgreSQL CNPG Custom Image Makefile

# Configuration
REGISTRY ?= ghcr.io
IMAGE_NAME ?= xataio/postgres-images/xata-exp-img
CNPG_BASE ?= ghcr.io/cloudnative-pg/postgresql:17-minimal-bookworm
DOCKERFILE_DIR ?= docker/experimental
DOCKERFILE ?= $(DOCKERFILE_DIR)/Dockerfile
PLATFORMS ?= linux/amd64,linux/arm64
DATE_TAG := $(shell date +%Y%m%d)
CONFIG_FILE := $(DOCKERFILE_DIR)/extensions.json
DESCRIPTION ?= CNPG PostgreSQL with additional extensions and tools
IMAGE_TAG ?= dev # Default tag; CI overrides with commit SHA

# Derived variables
FULL_IMAGE_NAME := $(REGISTRY)/$(IMAGE_NAME)

# extract names where preload_required==true, wrap each in single-quotes,
# then join them with commas
PRELOAD_LIBS := $(shell \
  jq -r '.extensions[] | select(.preload_required==true) | .name' $(CONFIG_FILE) \
    | sed "s/.*/'&'/" \
    | paste -sd, - \
)

# Default target
.PHONY: help
help: ## Show this help message
	@echo "$(DESCRIPTION) Image Build"
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
build-local: get-pg-version get-base-digest ## Build image locally for testing
	@echo "Building local image (tags: latest, $(PG_VERSION), $(PG_VERSION)-$(DATE_TAG), $(IMAGE_TAG))..."
	docker build \
		-f $(DOCKERFILE) \
		-t $(FULL_IMAGE_NAME):$(PG_VERSION)-$(DATE_TAG) \
		-t $(FULL_IMAGE_NAME):$(IMAGE_TAG) \
		--label "base.digest=$(BASE_DIGEST)" \
		--label "org.opencontainers.image.source=https://github.com/xataio/postgres-images" \
		--label "org.opencontainers.image.description=$(DESCRIPTION)" \
		--label "org.opencontainers.image.licenses=PostgreSQL" \
		--build-arg CNPG_BASE=$(CNPG_BASE) \
		.

.PHONY: test
test: ## Run tests on the built image
	@echo "Running tests on $(FULL_IMAGE_NAME):$(IMAGE_TAG)"
	@docker rm -f pg-test 2>/dev/null || true

	@echo "Starting PostgreSQL container..."
	docker run -d --name pg-test \
		-e POSTGRES_PASSWORD=test \
		-e POSTGRES_INITDB_ARGS="--auth-host=trust --encoding=UTF8" \
		-e PGDATA=/var/lib/postgresql/data \
		--user postgres \
		"$(FULL_IMAGE_NAME):$(IMAGE_TAG)" \
		bash -c 'echo "Starting initialization..." && mkdir -p $$PGDATA && if [ ! -f $$PGDATA/PG_VERSION ]; then echo "Initializing database..." && initdb $$POSTGRES_INITDB_ARGS; fi && echo "Starting PostgreSQL..." && postgres'

	@echo "Waiting for PostgreSQL to be ready..."
	@timeout 60s bash -c 'until docker exec pg-test pg_isready 2>/dev/null; do sleep 2; done' || \
		(echo "=== Container failed to start, showing logs ===" && docker logs pg-test && exit 1)

	@echo "Testing basic functionality..."
	docker exec pg-test psql -U postgres -c "SELECT version();"

	@echo "Applying postgres_config settings…"
	@jq -r '.postgres_config[] | "\(.setting) \(.value|@sh)"' $(CONFIG_FILE) \
	  | while IFS=' ' read -r setting val; do \
	      sql="ALTER SYSTEM SET $$setting = $$val;"; \
	      echo " → $$sql"; \
	      docker exec pg-test psql -U postgres -c "$$sql"; \
	    done

	@if [ -n "$(PRELOAD_LIBS)" ]; then \
		echo "Setting shared_preload_libraries to: $(PRELOAD_LIBS)"; \
		docker exec pg-test psql -U postgres -c "ALTER SYSTEM SET shared_preload_libraries TO $(PRELOAD_LIBS);"; \
		echo "Restarting PostgreSQL..."; \
		docker restart pg-test; \
		timeout 60s bash -c 'until docker exec pg-test pg_isready 2>/dev/null; do sleep 2; done' || \
			(echo "=== Container failed after restart, showing logs ===" && docker logs pg-test && exit 1); \
		echo "Verifying preloaded libraries..."; \
		docker exec pg-test psql -U postgres -c "SHOW shared_preload_libraries;"; \
	else \
		echo "No extensions require preloading, skipping shared_preload_libraries configuration"; \
	fi

	@echo "Testing all extensions from $(CONFIG_FILE)..."
	@jq -r '.extensions[] | select(.test_enabled==true) | .name' $(CONFIG_FILE) | while read -r ext; do \
    	echo "Testing extension: $$ext"; \
    	echo "Running commands for $$ext:"; \
    	jq -r --arg ext "$$ext" '.extensions[] | select(.name == $$ext and .test_enabled==true) | .test_commands[]' $(CONFIG_FILE) | sed 's/^/ → /'; \
    	if ! jq -r --arg ext "$$ext" '.extensions[] | select(.name == $$ext and .test_enabled==true) | .test_commands[]' $(CONFIG_FILE) | docker exec -i pg-test psql -U postgres; then \
        	echo "ERROR: Commands failed for extension $$ext"; \
        	docker rm -f pg-test; \
        	exit 1; \
    	fi; \
	done

	@echo "Listing available extensions..."
	docker exec pg-test psql -U postgres -c "SELECT name FROM pg_available_extensions ORDER BY name;"

	@echo "Verifying SQL extension versions..."
	docker exec pg-test /usr/local/bin/verify-extensions.sh

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
	@echo "Building multi-architecture image (tags: latest, $(PG_VERSION), $(PG_VERSION)-$(DATE_TAG), $(IMAGE_TAG))..."
	docker buildx build \
		-f $(DOCKERFILE) \
		--platform $(PLATFORMS) \
		-t $(FULL_IMAGE_NAME):$(PG_VERSION)-$(DATE_TAG) \
		-t $(FULL_IMAGE_NAME):$(IMAGE_TAG) \
		--label "base.digest=$(BASE_DIGEST)" \
		--label "org.opencontainers.image.source=https://github.com/xataio/postgres-images" \
		--label "org.opencontainers.image.description=$(DESCRIPTION)" \
		--label "org.opencontainers.image.licenses=PostgreSQL" \
		--build-arg CNPG_BASE=$(CNPG_BASE) \
		.

.PHONY: push-multiarch
push-multiarch: get-pg-version get-base-digest setup-buildx ## Build and push multi-architecture image
	@echo "Building and pushing multi-architecture image (tags: latest, $(PG_VERSION), $(PG_VERSION)-$(DATE_TAG), $(IMAGE_TAG))..."
	docker buildx build \
		-f $(DOCKERFILE) \
		--platform $(PLATFORMS) \
		-t $(FULL_IMAGE_NAME):$(PG_VERSION)-$(DATE_TAG) \
		-t $(FULL_IMAGE_NAME):$(IMAGE_TAG) \
		--label "base.digest=$(BASE_DIGEST)" \
		--label "org.opencontainers.image.source=https://github.com/xataio/postgres-images" \
		--label "org.opencontainers.image.description=$(DESCRIPTION)" \
		--label "org.opencontainers.image.licenses=PostgreSQL" \
		--build-arg CNPG_BASE=$(CNPG_BASE) \
		--push \
		.
	@echo "Multi-architecture image pushed to $(FULL_IMAGE_NAME)"
	@echo "Available tags: latest, $(PG_VERSION), $(PG_VERSION)-$(DATE_TAG), $(IMAGE_TAG)"
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
	-docker rm -f pg-test pg-verify 2>/dev/null
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
	@echo "Image Tag: $(IMAGE_TAG)"

# CI-friendly target that mirrors the GitHub Actions logic
.PHONY: ci-build
ci-build: ## CI build process (build, test, verify, and conditionally push)
	@echo "Starting CI build process..."
	@if $(MAKE) check-base-updated 2>/dev/null; then \
		echo "Base image updated, proceeding with build..."; \
		$(MAKE) build-and-test && \
		$(MAKE) push-multiarch; \
	else \
		echo "Base image unchanged, skipping build"; \
	fi

# for testing outside of CI
# needs snyk installed and snyk auth
.PHONY: scan
scan: ## Run Snyk vulnerability scan (on demand)
	@echo "Running Snyk container scan for $(FULL_IMAGE_NAME):$(IMAGE_TAG)..."
	@snyk container test $(FULL_IMAGE_NAME):$(IMAGE_TAG) --severity-threshold=high