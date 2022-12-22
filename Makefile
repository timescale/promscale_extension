.DEFAULT_GOAL := help

ARCH ?= $(shell uname -m)
# This little workaround allows usage of the '#' character on both gnu make 3.8 and 4.3+
H := \#
# We want to be able to execute `sudo make install`, but cargo and rustc are probably both
# not available for sudo, so we use `command -v` to only run them if they are available
EXT_VERSION ?= $(shell command -v cargo >/dev/null && ./extract-extension-version.sh | tr -d '\n')
RUST_VERSION ?= $(shell command -v rustc >/dev/null && rustc --version | cut -d' ' -f2)
SQL_FILENAME ?= sql/promscale--${EXT_VERSION}.sql
IMAGE_NAME ?= timescaledev/promscale-extension
OS_NAME ?= debian
OS_VERSION ?= 11
PG_CONFIG ?= pg_config
PG_RELEASE_VERSION ?= $(shell ${PG_CONFIG} --version | awk -F'[ \. ]' '{print $$2}')
PG_BUILD_VERSION = $(shell ${PG_CONFIG} --version | awk -F'[ \. ]' '{print $$2}')
# If set to a non-empty value, docker builds will be pushed to the registry
PUSH ?=
TIMESCALEDB_VERSION_FULL=2.9.0
TIMESCALEDB_VERSION_MAJMIN=$(shell echo $(TIMESCALEDB_VERSION_FULL) | cut -d. -f 1,2)
TIMESCALEDB_VERSION_MAJOR=$(shell echo $(TIMESCALEDB_VERSION_FULL) | cut -d. -f 1)
TS_DOCKER_IMAGE ?= local/dev_promscale_extension:head-ts2-pg14
export TS_DOCKER_IMAGE

# Transform ARCH to its Docker platform equivalent
ifeq ($(ARCH),arm64)
	DOCKER_PLATFORM=linux/arm64
endif
ifeq ($(ARCH),aarch64)
	DOCKER_PLATFORM=linux/arm64
endif
ifeq ($(ARCH),x86_64)
	DOCKER_PLATFORM=linux/amd64
endif
ifeq ($(ARCH),amd64)
	DOCKER_PLATFORM=linux/amd64
endif
# Calculate the correct dockerfile to use when running the release target
ifeq ($(OS_NAME),debian)
	DOCKERFILE = deb.dockerfile
	TESTDOCKERFILE = deb.test.dockerfile
	DOCKER_DISTRO_NAME = debian
	PKG_TYPE = deb
endif
ifeq ($(OS_NAME),ubuntu)
	DOCKERFILE = deb.dockerfile
	TESTDOCKERFILE = deb.test.dockerfile
	DOCKER_DISTRO_NAME = ubuntu
	PKG_TYPE = deb
endif
ifeq ($(OS_NAME),centos)
	DOCKERFILE = rpm.dockerfile
	TESTDOCKERFILE = rpm.test.dockerfile
	DOCKER_DISTRO_NAME = centos
	PKG_TYPE = rpm
endif
ifeq ($(OS_NAME),rocky)
	DOCKERFILE = rpm.dockerfile
	TESTDOCKERFILE = rpm.test.dockerfile
	DOCKER_DISTRO_NAME = rockylinux
	PKG_TYPE = rpm
endif
RELEASE_IMAGE_NAME = promscale-extension-pkg:$(EXT_VERSION)-$(OS_NAME)$(OS_VERSION)-pg$(PG_RELEASE_VERSION)
RELEASE_FILE_NAME = promscale-extension-$(EXT_VERSION).pg$(PG_RELEASE_VERSION).$(OS_NAME)$(OS_VERSION).$(ARCH).$(PKG_TYPE)

.PHONY: help
help:
	@echo "promscale_extension $(EXT_VERSION)"
	@perl -nle'print $& if m{^[a-zA-Z_-]+:.*?## .*$$}' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: promscale.control ## Build the extension
	cargo build --release --features pg${PG_BUILD_VERSION} $(EXTRA_RUST_ARGS)

.PHONY: clean
clean: clean-generated ## Clean up latest build
	cargo clean

.PHONY: clean-generated
clean-generated:
	-rm ${SQL_FILENAME}
	-rm promscale.control

.PHONY: run-12
run-12: PG_BUILD_VERSION=12
run-12: run

.PHONY: run-13
run-13: PG_BUILD_VERSION=13
run-13: run

.PHONY: run-14
run-14: PG_BUILD_VERSION=14
run-14: run

.PHONY: run
run: promscale.control ## Custom wrapper around cargo pgx run
	PGX_FORCE_CREATE_OR_REPLACE=true cargo pgx run pg${PG_BUILD_VERSION}

.PHONY: dependencies
dependencies: promscale.control ## Used in docker build to improve build caching
	# both of these steps are also run in the `package` target, so we run them here to provide better caching
	cargo pgx schema pg${PG_BUILD_VERSION} --out ${SQL_FILENAME} --release
	cargo pgx package --pg-config ${PG_CONFIG}
	rm ${SQL_FILENAME}

.PHONY: package
package: promscale.control ## Generate extension artifacts for packaging
	cargo pgx schema pg${PG_BUILD_VERSION} --release >/dev/null
	cargo pgx schema pg${PG_BUILD_VERSION} --out ${SQL_FILENAME} --release
	bash create-upgrade-symlinks.sh
	cargo pgx package --pg-config ${PG_CONFIG}

.PHONY: install
install: ## Install the extension in the Postgres found via pg_config
	cp -R ./target/release/promscale-pg${PG_BUILD_VERSION}/* /

.PHONY: release
release: dist/$(RELEASE_FILE_NAME) ## Produces release artifacts based on OS_NAME, OS_VERSION, and PG_RELEASE_VERSION

.PHONY: release-builder
release-builder: dist/$(DOCKERFILE) ## Build image with the release artifact for OS_NAME, OS_VERSION, and PG_RELEASE_VERSION
ifndef DOCKERFILE
	$(error Unsupported OS_NAME '$(OS_NAME)'! Expected one of debian,ubuntu,centos,rocky)
endif
ifndef DOCKER_PLATFORM
	$(error Unsupported ARCH '$(ARCH)'! Expected one of arm64,x86_64)
endif
	docker buildx build --load --platform $(DOCKER_PLATFORM) \
		--build-arg DOCKER_DISTRO_NAME=$(DOCKER_DISTRO_NAME) \
		--build-arg OS_NAME=$(OS_NAME) \
		--build-arg OS_VERSION=$(OS_VERSION) \
		--build-arg PG_VERSION=$(PG_RELEASE_VERSION) \
		--build-arg RUST_VERSION=$(RUST_VERSION) \
		--build-arg RELEASE_FILE_NAME=$(RELEASE_FILE_NAME) \
		--target packager \
		-t $(RELEASE_IMAGE_NAME) \
		-f dist/$(DOCKERFILE) \
		.

dist/$(RELEASE_FILE_NAME): dist/$(DOCKERFILE)
ifndef DOCKERFILE
	$(error Unsupported OS_NAME '$(OS_NAME)'! Expected one of debian,ubuntu,centos,rocky)
endif
ifndef DOCKER_PLATFORM
	$(error Unsupported ARCH '$(ARCH)'! Expected one of arm64,x86_64)
endif
	docker buildx build --progress plain --platform $(DOCKER_PLATFORM) \
    		--build-arg DOCKER_DISTRO_NAME=$(DOCKER_DISTRO_NAME) \
    		--build-arg OS_NAME=$(OS_NAME) \
    		--build-arg OS_VERSION=$(OS_VERSION) \
    		--build-arg PG_VERSION=$(PG_RELEASE_VERSION) \
    		--build-arg RUST_VERSION=$(RUST_VERSION) \
    		--build-arg RELEASE_FILE_NAME=$(RELEASE_FILE_NAME) \
    		--target bundler \
    		--load \
    		-t $(RELEASE_IMAGE_NAME) \
    		-f dist/$(DOCKERFILE) \
    		.
	docker save --output=./dist/$(RELEASE_FILE_NAME)-docker $(RELEASE_IMAGE_NAME)
	@container="$$(docker create $(RELEASE_IMAGE_NAME))"; \
	docker cp "$${container}:/dist/$(RELEASE_FILE_NAME)" ./dist; \
	touch ./dist/${RELEASE_FILE_NAME}; \
	docker rm -f "$${container}"

dist/$(RELEASE_FILE_NAME)-docker-test: dist/$(RELEASE_FILE_NAME) dist/$(TESTDOCKERFILE) ## Build image used for testing a specific release package
ifndef DOCKERFILE
	$(error Unsupported OS_NAME '$(OS_NAME)'! Expected one of debian,ubuntu,centos,rocky)
endif
ifndef DOCKER_PLATFORM
	$(error Unsupported ARCH '$(ARCH)'! Expected one of arm64,x86_64)
endif
	docker buildx build --platform $(DOCKER_PLATFORM) \
		--build-arg=DOCKER_DISTRO_NAME=$(DOCKER_DISTRO_NAME) \
		--build-arg=DISTRO=$(OS_NAME) \
		--build-arg=DISTRO_VERSION=$(OS_VERSION) \
		--build-arg=PG_VERSION=$(PG_RELEASE_VERSION) \
		--build-arg=RELEASE_FILE_NAME=dist/$(RELEASE_FILE_NAME) \
		--load \
		-t "$(RELEASE_IMAGE_NAME)-test" \
		-f dist/$(TESTDOCKERFILE) \
		.
	docker save --output=./dist/$(RELEASE_FILE_NAME)-docker-test "$(RELEASE_IMAGE_NAME)-test"

.PHONY: release-test
release-test: dist/$(RELEASE_FILE_NAME)-docker-test ## Test the currently selected release package
	docker load --input dist/$(RELEASE_FILE_NAME)-docker-test
	./tools/smoke-test "$(RELEASE_IMAGE_NAME)-test" $(DOCKER_PLATFORM)

.PHONY: post-release
post-release: promscale.control
	cargo pgx schema pg${PG_BUILD_VERSION} --out ${SQL_FILENAME} --release
	bash create-upgrade-symlinks.sh

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
docker-quick-build-12 docker-quick-build-13 docker-quick-build-14: promscale.control ## A quick way to rebuild the extension image with only SQL changes
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

promscale.control: ## A hack to boostrap the build, some pgx commands require this file. It gets re-generated later.
	cp templates/promscale.control ./promscale.control

DEVENV_CONTAINER_NAME = promscale-extension-devcontainer

.PHONY: devcontainer
devcontainer: ## Builds an image for an interactive development container, that includes TimescaleDB with this extension
	docker build -f dev.Dockerfile -t ${DEVENV_CONTAINER_NAME} .

DEVENV_PG_VERSION ?= ${PG_BUILD_VERSION}
DEVENV_PG_INTERNAL_PORT ?= 288${DEVENV_PG_VERSION}

.PHONY: devenv-internal-build-install
devenv-internal-build-install: clean-generated promscale.control
	cargo pgx install --features="pg${DEVENV_PG_VERSION}"

DEVENV_ENTR ?= 1

.PHONY: devenv
devenv: VOLUME_NAME=promscale-extension-build-cache
devenv: devcontainer promscale.control ## Starts an interactive container from an image built by devcontainer target. It monitors working directory and re-builds/re-installs the extension.
	docker volume inspect ${VOLUME_NAME} 1>/dev/null 2>&1 || docker volume create ${VOLUME_NAME}
	docker run --rm -v ${VOLUME_NAME}:/tmp/target ubuntu bash -c "chmod a+w /tmp/target"
	docker run -ti -e DEVENV_ENTR=${DEVENV_ENTR} -e DEVENV_PG_VERSION=${DEVENV_PG_VERSION} --rm -v ${VOLUME_NAME}:/tmp/target -p54321:${DEVENV_PG_INTERNAL_PORT} -v$(shell pwd):/code --name ${DEVENV_CONTAINER_NAME} ${DEVENV_CONTAINER_NAME}

.PHONY: devenv-no-entr
devenv-no-entr: DEVENV_ENTR=0
devenv-no-entr: devenv

POSTGRES_URL ?= $(shell $(MAKE) devenv-url)

.PHONY: devenv-export-url
devenv-export-url:
	@echo "export POSTGRES_URL=${POSTGRES_URL}"

.PHONY: devenv-url
devenv-url: ## Outputs PSQL url that can be used to connect to the devenv
	@echo "postgres://ubuntu@localhost:54321/"

.PHONY: sql-tests
sql-tests: ## Run tests from sql-tests workspace
	POSTGRES_URL=${POSTGRES_URL} cargo test -p sql-tests

.PHONY: gendoc
gendoc: ## Generate SQL API documentation
	POSTGRES_URL=${POSTGRES_URL} cargo run -p gendoc > docs/sql-api.md

DEVENV_EXEC ?= docker exec -it -e POSTGRES_URL=postgres://ubuntu@localhost:${DEVENV_PG_INTERNAL_PORT}/ ${DEVENV_CONTAINER_NAME}

.PHONY: dev-sql-tests
dev-sql-tests: ## Run tests from sql-tests workspace within the devenv. The devenv must be started separately.
	${DEVENV_EXEC} make sql-tests

.PHONY: dev-gendoc
dev-gendoc: ## Generate SQL API documentation within the devenv. The devenv must be started separately.
	${DEVENV_EXEC} make gendoc

.PHONY: dev-build
dev-build: ## (Re)builds and installs the extension inside the devenv container. The devenv must be started separately.
	${DEVENV_EXEC} make devenv-internal-build-install

.PHONY: dev-bash
dev-bash: ## Gets a bash shell inside the devenv container. The devenv must be started separately.
	${DEVENV_EXEC} bash

.PHONY: dev-psql
dev-psql: ## Gets a psql shell connected to the devenv container. The devenv must be started separately.
	psql "${POSTGRES_URL}"
