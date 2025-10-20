# PostgreSQL CNPG Custom Image Makefile
PG_MAJOR ?= 17
PG_TAG   ?= $(PG_MAJOR) #17->17, 18->18

POSTGIS_CLI_VERSION_17 ?= 3.6.0+dfsg-1.pgdg12+1

# Configuration
REGISTRY ?= ghcr.io
IMAGE_NAME ?= xataio/postgres-images/cnpg-postgres-plus
CNPG_BASE ?= ghcr.io/cloudnative-pg/postgresql:$(PG_TAG)-minimal-bookworm
DOCKERFILE_DIR ?= docker/custom-postgres
DOCKERFILE ?= $(DOCKERFILE_DIR)/Dockerfile
PLATFORMS ?= linux/amd64,linux/arm64
DATE_TAG := $(shell date +%Y%m%d)
CONFIG_FILE ?= $(DOCKERFILE_DIR)/extensions.$(PG_MAJOR).json
DESCRIPTION ?= CNPG PostgreSQL with additional extensions and tools
IMAGE_TAG ?= latest # Default tag; CI overrides with commit SHA

# GitHub token for private repository access
GITHUB_TOKEN ?= $(shell echo $$GITHUB_TOKEN)

# Validate GitHub token is available
ifndef GITHUB_TOKEN
$(warning GITHUB_TOKEN is not set - this will cause builds to fail when accessing private xata-utils repository)
endif

# Derived variables
FULL_IMAGE_NAME := $(REGISTRY)/$(IMAGE_NAME)

# Common tag set used by build commands
DOCKER_TAGS = \
	-t $(FULL_IMAGE_NAME):$(PG_VERSION) \
	-t $(FULL_IMAGE_NAME):$(PG_VERSION)-$(DATE_TAG) \
	-t $(FULL_IMAGE_NAME):$(IMAGE_TAG)

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
	@echo "PostgreSQL major target: $(PG_MAJOR)"
	@echo "PostgreSQL version (from base): $(PG_VERSION)"

.PHONY: get-base-digest
get-base-digest: pull-base ## Get base image digest
	$(eval BASE_DIGEST := $(shell docker image inspect $(CNPG_BASE) --format '{{.Id}}'))
	@echo "Base image digest: $(BASE_DIGEST)"

.PHONY: check-github-token
check-github-token: ## Check if GitHub token is set
	@if [ -z "$(GITHUB_TOKEN)" ]; then \
		echo "ERROR: GITHUB_TOKEN environment variable is required for accessing private xata-utils repository"; \
		echo "Please set GITHUB_TOKEN with a token that has read access to the xataio/xata-utils repository"; \
		echo ""; \
		echo "Example:"; \
		echo "  export GITHUB_TOKEN=\"ghp_your_token_here\""; \
		echo "  make build-local"; \
		echo ""; \
		echo "Token requirements:"; \
		echo "  - 'repo' scope for private repository access"; \
		echo "  - Read access to xataio/xata-utils repository"; \
		exit 1; \
	else \
		echo "✓ GitHub token is set (length: $$(echo '$(GITHUB_TOKEN)' | wc -c) chars)"; \
		echo "✓ Ready to access private xata-utils repository"; \
	fi

.PHONY: build-local
build-local: get-pg-version get-base-digest check-github-token ## Build image locally for testing
	@echo "Building local image (tags: $(PG_VERSION), $(PG_VERSION)-$(DATE_TAG), $(IMAGE_TAG))..."
	@echo "$(GITHUB_TOKEN)" | docker build \
		-f $(DOCKERFILE) \
		$(DOCKER_TAGS) \
		--label "base.digest=$(BASE_DIGEST)" \
		--label "org.opencontainers.image.source=https://github.com/xataio/postgres-images" \
		--label "org.opencontainers.image.description=$(DESCRIPTION)" \
		--label "org.opencontainers.image.licenses=PostgreSQL" \
		--build-arg CNPG_BASE=$(CNPG_BASE) \
		--build-arg PG_MAJOR=$(PG_MAJOR) \
		--build-arg CONFIG_FILE=$(CONFIG_FILE) \
		--build-arg POSTGIS_CLI_VERSION_17=$(POSTGIS_CLI_VERSION_17) \
		--secret id=github_token,src=/dev/stdin \
		.

.PHONY: test
test: ## Run tests on the built image
	@echo "Running tests on $(FULL_IMAGE_NAME):$(IMAGE_TAG)"
	@docker rm -f pg-test 2>/dev/null || true

	@echo "Starting PostgreSQL container..."
	docker run -d --name pg-test \
		-e POSTGRES_PASSWORD=test \
		-e POSTGRES_INITDB_ARGS="--auth-host=trust" \
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

	@echo "Verifying declared shared objects exist (file_check)…"
	@jq -r '.extensions[] | select(.file_check and .file_check != "") | .file_check' $(CONFIG_FILE) \
	  | while read -r path; do \
	      echo " → checking $$path"; \
	      docker exec pg-test bash -lc "[ -f $$path ] || { echo 'Missing: $$path'; exit 1; }"; \
	    done


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
build-multiarch: get-pg-version get-base-digest check-github-token setup-buildx ## Build multi-architecture image (no push)
	@echo "Building multi-architecture image (tags: latest, $(PG_VERSION), $(PG_VERSION)-$(DATE_TAG), $(IMAGE_TAG))..."
	@echo "$(GITHUB_TOKEN)" | docker buildx build \
		-f $(DOCKERFILE) \
		--platform $(PLATFORMS) \
		$(DOCKER_TAGS) \
		--label "base.digest=$(BASE_DIGEST)" \
		--label "org.opencontainers.image.source=https://github.com/xataio/postgres-images" \
		--label "org.opencontainers.image.description=$(DESCRIPTION)" \
		--label "org.opencontainers.image.licenses=PostgreSQL" \
		--build-arg CNPG_BASE=$(CNPG_BASE) \
		--build-arg PG_MAJOR=$(PG_MAJOR) \
		--build-arg CONFIG_FILE=$(CONFIG_FILE) \
		--build-arg POSTGIS_CLI_VERSION_17=$(POSTGIS_CLI_VERSION_17) \
		--secret id=github_token,src=/dev/stdin \
		.

.PHONY: push-arch
push-arch: get-pg-version get-base-digest check-github-token setup-buildx ## Build and push multi-architecture image
	@echo "Building and pushing multi-architecture image (tags: $(IMAGE_TAG))..."
	@echo "$(GITHUB_TOKEN)" | docker buildx build \
		-f $(DOCKERFILE) \
		--platform $(PLATFORMS) \
		-t $(FULL_IMAGE_NAME):$(IMAGE_TAG) \
		--label "base.digest=$(BASE_DIGEST)" \
		--label "org.opencontainers.image.source=https://github.com/xataio/postgres-images" \
		--label "org.opencontainers.image.description=$(DESCRIPTION)" \
		--label "org.opencontainers.image.licenses=PostgreSQL" \
		--build-arg CNPG_BASE=$(CNPG_BASE) \
		--build-arg PG_MAJOR=$(PG_MAJOR) \
		--build-arg CONFIG_FILE=$(CONFIG_FILE) \
		--build-arg POSTGIS_CLI_VERSION_17=$(POSTGIS_CLI_VERSION_17) \
		--secret id=github_token,src=/dev/stdin \
		--output type=image,push=true \
		.

	@echo "Pushed $(FULL_IMAGE_NAME):$(IMAGE_TAG) Platforms: $(PLATFORMS)"

.PHONY: check-base-updated
check-base-updated: get-base-digest get-pg-version ## Check if base image has been updated
	@echo "Checking if base image has been updated (reference tag: $(PG_VERSION))..."
	@if docker pull $(FULL_IMAGE_NAME):$(PG_VERSION) 2>/dev/null; then \
		EXISTING_DIGEST=$$(docker image inspect $(FULL_IMAGE_NAME):$(PG_VERSION) --format '{{index .Config.Labels "base.digest"}}' 2>/dev/null || echo ""); \
		if [ "$$EXISTING_DIGEST" = "$(BASE_DIGEST)" ]; then \
			echo "Base image unchanged, no rebuild needed"; \
			exit 1; \
		else \
			echo "Base image updated, rebuild needed"; \
		fi; \
	else \
		echo "No existing image with tag $(PG_VERSION) found, build needed"; \
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
	@echo "PG Major (target): $(PG_MAJOR)"
	@echo "CNPG Base Tag: $(PG_TAG)"
	@echo "PostgreSQL Version: $(PG_VERSION)"
	@echo "Base Digest: $(BASE_DIGEST)"
	@echo "Date Tag: $(DATE_TAG)"
	@echo "Platforms: $(PLATFORMS)"
	@echo "Dockerfile: $(DOCKERFILE)"
	@echo "Image Tag: $(IMAGE_TAG)"
	@echo "Config File: $(CONFIG_FILE)"
	@echo "GitHub Token: $(if $(GITHUB_TOKEN),SET,NOT SET)"

# CI-friendly target that mirrors the GitHub Actions logic
.PHONY: ci-build
ci-build: check-github-token ## CI build process (build, test, verify, and conditionally push)
	@echo "Starting CI build process..."
	@if $(MAKE) check-base-updated 2>/dev/null; then \
		echo "Base image updated, proceeding with build..."; \
		$(MAKE) build-and-test && \
		$(MAKE) push-arch; \
	else \
		echo "Base image unchanged, skipping build"; \
	fi

# for testing outside of CI
# needs snyk installed and snyk auth
.PHONY: scan
scan: ## Run Snyk vulnerability scan (on demand)
	@echo "Running Snyk container scan for $(FULL_IMAGE_NAME):$(IMAGE_TAG)..."
	@snyk container test $(FULL_IMAGE_NAME):$(IMAGE_TAG) --severity-threshold=high

# Convenience: build/push both majors
.PHONY: build-both
build-both: check-github-token
	@echo "Building both PG versions with GitHub token..."
	$(MAKE) build-and-test PG_MAJOR=17 IMAGE_TAG=pg17
	$(MAKE) build-and-test PG_MAJOR=18 IMAGE_TAG=pg18

.PHONY: push-both
push-both: check-github-token
	@echo "Pushing both PG versions with GitHub token..."
	$(MAKE) push-arch PG_MAJOR=17 IMAGE_TAG=pg17
	$(MAKE) push-arch PG_MAJOR=18 IMAGE_TAG=pg18

# Test GitHub token access to xata-utils repository
.PHONY: test-github-access
test-github-access: check-github-token ## Test GitHub token access to xata-utils repository
	@echo "Testing GitHub token access to xataio/xata-utils repository..."
	@if curl -s -H "Authorization: token $(GITHUB_TOKEN)" \
		-H "Accept: application/vnd.github.v3+json" \
		"https://api.github.com/repos/xataio/xata-utils" >/dev/null 2>&1; then \
		echo "✓ GitHub token has access to xataio/xata-utils repository"; \
	else \
		echo "✗ GitHub token does NOT have access to xataio/xata-utils repository"; \
		echo "Please ensure:"; \
		echo "  1. Token has 'repo' scope"; \
		echo "  2. Token has access to xataio organization"; \
		echo "  3. Token has read access to xata-utils repository"; \
		exit 1; \
	fi

# Build experimental image
.PHONY: build-experimental
build-experimental: check-github-token ## Build experimental image locally
	@echo "Building experimental PostgreSQL image..."
	$(MAKE) build-and-test \
		DOCKERFILE_DIR=docker/experimental \
		IMAGE_NAME=xataio/postgres-images/experimental \
		PG_MAJOR=17 \
		IMAGE_TAG=experimental-local