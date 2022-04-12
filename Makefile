.DEFAULT_GOAL := help

ARCH ?= $(shell uname -m)
# This little workaround allows usage of the '#' character on both gnu make 3.8 and 4.3+
H := \#
EXT_VERSION ?= $(shell cargo pkgid | cut -d'$H' -f2 | cut -d':' -f2)
IMAGE_NAME ?= timescaledev/promscale-extension
OS_NAME ?= debian
OS_VERSION ?= 11
RUST_VERSION ?= $(shell rustc --version | cut -d' ' -f2)
PG_CONFIG ?= pg_config
PG_RELEASE_VERSION ?= $(shell ${PG_CONFIG} --version | awk -F'[ \. ]' '{print $$2}')
PG_BUILD_VERSION = $(shell ${PG_CONFIG} --version | awk -F'[ \. ]' '{print $$2}')
# If set to a non-empty value, docker builds will be pushed to the registry
PUSH ?=
TIMESCALEDB_VERSION_FULL=2.6.1
TIMESCALEDB_VERSION_MAJMIN=$(shell echo $(TIMESCALEDB_VERSION_FULL) | cut -d. -f 1,2)
TIMESCALEDB_VERSION_MAJOR=$(shell echo $(TIMESCALEDB_VERSION_FULL) | cut -d. -f 1)

# Transform ARCH to its Docker platform equivalent
ifeq ($(ARCH),arm64)
	DOCKER_PLATFORM=linux/arm64
endif
ifeq ($(ARCH),x86_64)
	DOCKER_PLATFORM=linux/amd64
endif
# Calculate the correct dockerfile to use when running the release target
ifeq ($(OS_NAME),debian)
	DOCKERFILE = deb.dockerfile
	PKG_TYPE = deb
endif
ifeq ($(OS_NAME),ubuntu)
	DOCKERFILE = deb.dockerfile
	PKG_TYPE = deb
endif
ifeq ($(OS_NAME),centos)
	DOCKERFILE = rpm.dockerfile
	PKG_TYPE = rpm
endif
ifeq ($(OS_NAME),rhel)
	DOCKERFILE = rpm.dockerfile
	PKG_TYPE = rpm
endif
ifeq ($(OS_NAME),fedora)
	DOCKERFILE = rpm.dockerfile
	PKG_TYPE = rpm
endif
RELEASE_IMAGE_NAME = promscale-extension-pkg:$(EXT_VERSION)-$(OS_NAME)$(OS_VERSION)-pg$(PG_RELEASE_VERSION)
RELEASE_FILE_NAME = promscale_extension-$(EXT_VERSION).pg$(PG_RELEASE_VERSION).$(OS_NAME)$(OS_VERSION).$(ARCH).$(PKG_TYPE)
TESTER_NAME = pg$(PG_RELEASE_VERSION)-$(OS_NAME)$(OS_VERSION)

.PHONY: help
help:
	@echo "promscale_extension $(EXT_VERSION)"
	@perl -nle'print $& if m{^[a-zA-Z_-]+:.*?## .*$$}' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the extension
	cargo build --release --features pg${PG_BUILD_VERSION} $(EXTRA_RUST_ARGS)
	cargo pgx schema -f pg${PG_BUILD_VERSION} --release

.PHONY: clean
clean: ## Clean up latest build
	cargo clean

.PHONY: dependencies
dependencies: ## Used in docker build to improve build caching
	# both of these steps are also run in the `package` target, so we run them here to provide better caching
	cargo pgx schema pg${PG_BUILD_VERSION} --out sql/promscale--${EXT_VERSION}.sql --release
	cargo pgx package --pg-config ${PG_CONFIG}
	rm sql/promscale--${EXT_VERSION}.sql

.PHONY: package
package: ## Generate extension artifacts for packaging
	cargo pgx schema pg${PG_BUILD_VERSION} --out sql/promscale--${EXT_VERSION}.sql --release
	bash create-upgrade-symlinks.sh
	cargo pgx package --pg-config ${PG_CONFIG}

.PHONY: install
install: ## Install the extension in the Postgres found via pg_config
	bash create-upgrade-symlinks.sh
	cargo pgx install --pg-config ${PG_CONFIG}

.PHONY: release
release: release-builder ## Produces release artifacts based on OS_NAME, OS_VERSION, and PG_RELEASE_VERSION
	@container="$$(docker create $(RELEASE_IMAGE_NAME))"; \
	docker cp "$${container}:/dist/$(RELEASE_FILE_NAME)" ./dist/; \
	docker rm -f "$${container}"

.PHONY: release-builder
release-builder: dist/$(DOCKERFILE) ## Build image with the release artifact for OS_NAME, OS_VERSION, and PG_RELEASE_VERSION
ifndef DOCKERFILE
	$(error Unsupported OS_NAME '$(OS_NAME)'! Expected one of debian,ubuntu,centos,rhel,fedora)
endif
ifndef DOCKER_PLATFORM
	$(error Unsupported ARCH '$(ARCH)'! Expected one of arm64,x86_64)
endif
	docker buildx build --load --platform $(DOCKER_PLATFORM) \
		--build-arg OS_NAME=$(OS_NAME) \
		--build-arg OS_VERSION=$(OS_VERSION) \
		--build-arg PG_VERSION=$(PG_RELEASE_VERSION) \
		--build-arg RUST_VERSION=$(RUST_VERSION) \
		--build-arg RELEASE_FILE_NAME=$(RELEASE_FILE_NAME) \
		--target packager \
		-t $(RELEASE_IMAGE_NAME) \
		-f dist/$(DOCKERFILE) \
		.

.PHONY: release-tester
release-tester: dist/$(DOCKERFILE) ## Build image used for testing a specific release package
ifndef DOCKERFILE
	$(error Unsupported OS_NAME '$(OS_NAME)'! Expected one of debian,ubuntu,centos,rhel,fedora)
endif
ifndef DOCKER_PLATFORM
	$(error Unsupported ARCH '$(ARCH)'! Expected one of arm64,x86_64)
endif
	docker buildx build --load --platform $(DOCKER_PLATFORM) \
		--build-arg OS_NAME=$(OS_NAME) \
		--build-arg OS_VERSION=$(OS_VERSION) \
		--build-arg PG_VERSION=$(PG_RELEASE_VERSION) \
		--build-arg RUST_VERSION=$(RUST_VERSION) \
		--build-arg RELEASE_FILE_NAME=$(RELEASE_FILE_NAME) \
		--target tester \
		-t "$(RELEASE_IMAGE_NAME)-test" \
		-f dist/$(DOCKERFILE) \
		.

.PHONY: release-test
release-test: release-tester ## Test the currently selected release package
	docker run --rm --name "$(TESTER_NAME)" -e POSTGRES_PASSWORD=postgres -dt "$(RELEASE_IMAGE_NAME)-test"; \
	if ! docker run --rm --link "$(TESTER_NAME)" -it timescale/promscale:latest -db.uri "postgres://postgres:postgres@$(TESTER_NAME):5432/postgres?sslmode=allow" -startup.only; then \
		echo "Encountered error while testing package $(RELEASE_FILE_NAME)"; \
	fi; \
	docker rm -f "$(TESTER_NAME)"

.PHONY: docker-image-build-12 docker-image-build-13 docker-image-build-14
docker-image-build-12 docker-image-build-13 docker-image-build-14: alpine.Dockerfile $(SQL_FILES) $(SRCS) Cargo.toml Cargo.lock $(RUST_SRCS)
	docker buildx build $(if $(PUSH),--push,--load) \
		--build-arg TIMESCALEDB_VERSION_FULL=$(TIMESCALEDB_VERSION_FULL) \
		--build-arg TIMESCALEDB_VERSION_MAJOR=$(TIMESCALEDB_VERSION_MAJOR) \
		--build-arg TIMESCALEDB_VERSION_MAJMIN=$(TIMESCALEDB_VERSION_MAJMIN) \
		--build-arg PG_VERSION=$(PG_BUILD_VERSION) \
		-t local/dev_promscale_extension:head-ts$(TIMESCALEDB_VERSION_MAJOR)-pg$(PG_BUILD_VERSION) \
		-t $(IMAGE_NAME):$(EXT_VERSION)-ts$(TIMESCALEDB_VERSION_FULL)-pg$(PG_BUILD_VERSION) \
		-t $(IMAGE_NAME):$(EXT_VERSION)-ts$(TIMESCALEDB_VERSION_MAJOR)-pg$(PG_BUILD_VERSION) \
		-t $(IMAGE_NAME):latest-ts$(TIMESCALEDB_VERSION_MAJOR)-pg$(PG_BUILD_VERSION) \
        -f alpine.Dockerfile \
		.

.PHONY: docker-image-12
docker-image-12: PG_BUILD_VERSION=12
docker-image-12: docker-image-build-12

.PHONY: docker-image-13
docker-image-13: PG_BUILD_VERSION=13
docker-image-13: docker-image-build-13

.PHONY: docker-image-14
docker-image-14: PG_BUILD_VERSION=14
docker-image-14: docker-image-build-14

.PHONY: docker-image
docker-image: docker-image-14 docker-image-13 docker-image-12 ## Build Timescale images with the extension

.PHONY: docker-quick-build-12 docker-quick-build-13 docker-quick-build-14
docker-quick-build-12 docker-quick-build-13 docker-quick-build-14: ## A quick way to rebuild the extension image with only SQL changes
	cargo pgx schema pg$(PG_BUILD_VERSION)
	docker build -f quick.Dockerfile \
		--build-arg TIMESCALEDB_VERSION_MAJOR=$(TIMESCALEDB_VERSION_MAJOR) \
		--build-arg PG_VERSION=$(PG_BUILD_VERSION) \
		--build-arg EXTENSION_VERSION=$(EXT_VERSION) \
		-t local/dev_promscale_extension:head-ts$(TIMESCALEDB_VERSION_MAJOR)-pg$(PG_BUILD_VERSION) \
		-t $(IMAGE_NAME):$(EXT_VERSION)-ts$(TIMESCALEDB_VERSION_FULL)-pg$(PG_BUILD_VERSION) \
		-t $(IMAGE_NAME):$(EXT_VERSION)-ts$(TIMESCALEDB_VERSION_MAJOR)-pg$(PG_BUILD_VERSION) \
		-t $(IMAGE_NAME):latest-ts$(TIMESCALEDB_VERSION_MAJOR)-pg$(PG_BUILD_VERSION) \
		.

.PHONY: docker-quick-14
docker-quick-14: PG_BUILD_VERSION=14
docker-quick-14: docker-quick-build-14

.PHONY: docker-quick-13
docker-quick-13: PG_BUILD_VERSION=13
docker-quick-13: docker-quick-build-13

.PHONY: docker-quick-12
docker-quick-12: PG_BUILD_VERSION=12
docker-quick-12: docker-quick-build-12

.PHONY: setup-buildx
setup-buildx: ## Setup a Buildx builder
	@if ! docker buildx ls | grep buildx-builder >/dev/null; then \
		docker buildx create \
			--buildkitd-flags '--allow-insecure-entitlement security.insecure' \
			--append \
			--name buildx-builder \
			--driver docker-container \
			--use && \
		docker buildx inspect --bootstrap --builder buildx-builder; \
	fi
