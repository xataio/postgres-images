# PostgreSQL CNPG Custom Image - Development Guide

Contains custom-built PostgreSQL images to start Xata clusters

## Prerequisites:

```brew install coreutils```

### Add alias to your shell config
```echo 'alias timeout="gtimeout"' >> ~/.zshrc```

```source ~/.zshrc```

## Quick Start

```bash
# Show all available commands
make help

# Build and test locally
make build-and-test

# Just build (no tests)
make build-local

# Just run tests (assumes image is already built)
make test
```

## Common Development Workflows

### Local Development
```bash
# Build locally for testing
make build-local

# Run tests on the built image
make test

# Build and test in one command
make build-and-test

# Check what will be built
make show-info
```

### Testing Changes
```bash
# Build with custom dockerfile
make build-local DOCKERFILE=./custom/Dockerfile

# Build with different base image
make build-local CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:16-minimal-bookworm

# Build with custom registry/image name
make build-local REGISTRY=localhost:5000 IMAGE_NAME=my-postgres
```

### Multi-Architecture Builds
```bash
# Build for multiple architectures (requires buildx)
make build-multiarch

# Build and push to registry
make push-multiarch

# Build for specific platforms
make build-multiarch PLATFORMS=linux/amd64
```

### CI/CD Simulation
```bash
# Simulate the CI process locally
make ci-build
```

## Available Make Targets

- `help` - Show available targets
- `pull-base` - Pull the base CNPG PostgreSQL image
- `get-pg-version` - Get PostgreSQL version from base image
- `get-base-digest` - Get base image digest
- `build-local` - Build image locally for testing (amd64 only)
- `test` - Run comprehensive tests on the built image
- `build-and-test` - Build locally and run tests
- `setup-buildx` - Setup Docker buildx for multi-platform builds
- `build-multiarch` - Build multi-architecture image (no push)
- `push-multiarch` - Build and push multi-architecture image
- `check-base-updated` - Check if base image has been updated
- `clean` - Clean up Docker resources
- `show-info` - Show build information
- `ci-build` - CI build process (build, test, and conditionally push)

## Configuration

You can customize the build using environment variables:

```bash
# Custom registry
export REGISTRY=my-registry.com
make build-local

# Custom image name
export IMAGE_NAME=my-org/postgres
make build-local

# Custom base image
export CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:16-minimal-bookworm
make build-local

# Custom platforms for multi-arch builds
export PLATFORMS=linux/amd64,linux/arm64,linux/arm/v7
make build-multiarch
```

## Testing

The test suite verifies:
- Basic PostgreSQL functionality
- All extensions can be created and used
- wal2json logical replication plugin works
- Preloaded extensions (pg_stat_statements, pg_cron, etc.)
- Configuration changes persist across restarts
- Sample data operations work correctly

Tests run automatically with `make test` or `make build-and-test`.

## GitHub Actions Integration

The GitHub Actions workflow now uses the Makefile:
- Push/manual triggers: Always build and test
- Scheduled runs: Only build if base image has changed
- Multi-architecture builds are handled by the Makefile
- All build logic is centralized in the Makefile

## Troubleshooting

### Build Issues
```bash
# Clean up and try again
make clean
make build-local

# Check what's being built
make show-info

# Pull latest base image
make pull-base
```

### Test Failures
```bash
# Run tests with verbose output
make test

# Check test container logs manually
docker logs pg-test
```

### Multi-Architecture Issues
```bash
# Recreate buildx instance
docker buildx rm multiarch
make setup-buildx
```

# Bonus: Local development with act
Install act (https://nektosact.com)

```brew install act```

Run: 
```
act -j build-test-publish \                     
-P ubuntu-latest=catthehacker/ubuntu:act-latest \
--container-architecture linux/amd64
```

