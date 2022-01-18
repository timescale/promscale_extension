.DEFAULT_GOAL := build

PG_CONFIG?=pg_config

EXT_VERSION = $(shell cat promscale.control | grep 'default' | sed "s/^.*'\(.*\)'$\/\1/g")
PG_VERSION = $(shell ${PG_CONFIG} --version | awk -F'[ \.]' '{print $$2}')

.PHONY: build
build:
	cargo build --release --features pg${PG_VERSION} $(EXTRA_RUST_ARGS)
	cargo pgx schema -f pg${PG_VERSION} --release

.PHONY: clean
clean:
	cargo clean

.PHONY: package
package:
	cargo pgx package --pg-config ${PG_CONFIG}

.PHONY: install
install:
	cargo pgx install --pg-config ${PG_CONFIG}

PG_VER ?= pg12
PUSH ?= FALSE
DOCKER_IMAGE_NAME?=promscale-extension
ORGANIZATION?=timescaledev

.PHONY: docker-image-build-1 docker-image-build-2-12 docker-image-build-2-13 docker-image-build-2-14
docker-image-build-1 docker-image-build-2-12 docker-image-build-2-13 docker-image-build-2-14: Dockerfile $(SQL_FILES) $(SRCS) Cargo.toml Cargo.lock $(RUST_SRCS)
	docker build --build-arg TIMESCALEDB_VERSION=$(TIMESCALEDB_VER) --build-arg PG_VERSION_TAG=$(PG_VER) -t $(ORGANIZATION)/$(DOCKER_IMAGE_NAME):$(EXT_VERSION)-$(TIMESCALEDB_VER)-$(PG_VER) .
	docker tag $(ORGANIZATION)/$(DOCKER_IMAGE_NAME):$(EXT_VERSION)-$(TIMESCALEDB_VER)-$(PG_VER) $(ORGANIZATION)/$(DOCKER_IMAGE_NAME):${EXT_VERSION}-ts$(TIMESCALEDB_MAJOR)-$(PG_VER)
	docker tag $(ORGANIZATION)/$(DOCKER_IMAGE_NAME):$(EXT_VERSION)-$(TIMESCALEDB_VER)-$(PG_VER) $(ORGANIZATION)/$(DOCKER_IMAGE_NAME):latest-ts$(TIMESCALEDB_MAJOR)-$(PG_VER)
ifeq ($(PUSH), TRUE)
	docker push $(ORGANIZATION)/$(DOCKER_IMAGE_NAME):$(EXT_VERSION)-$(TIMESCALEDB_VER)-$(PG_VER)
	docker push $(ORGANIZATION)/$(DOCKER_IMAGE_NAME):${EXT_VERSION}-ts$(TIMESCALEDB_MAJOR)-$(PG_VER)
	docker push $(ORGANIZATION)/$(DOCKER_IMAGE_NAME):latest-ts$(TIMESCALEDB_MAJOR)-$(PG_VER)
endif

.PHONY: docker-image-ts1
docker-image-ts1: PG_VER=pg12
docker-image-ts1: TIMESCALEDB_MAJOR=1
docker-image-ts1: TIMESCALEDB_VER=1.7.5
docker-image-ts1: docker-image-build-1

.PHONY: docker-image-ts2-12
docker-image-ts2-12: PG_VER=pg12
docker-image-ts2-12: TIMESCALEDB_MAJOR=2
docker-image-ts2-12: TIMESCALEDB_VER=2.5.0
docker-image-ts2-12: docker-image-build-2-12

.PHONY: docker-image-ts2-13
docker-image-ts2-13: PG_VER=pg13
docker-image-ts2-13: TIMESCALEDB_MAJOR=2
docker-image-ts2-13: TIMESCALEDB_VER=2.5.0
docker-image-ts2-13: docker-image-build-2-13

.PHONY: docker-image-ts2-14
docker-image-ts2-14: PG_VER=pg14
docker-image-ts2-14: TIMESCALEDB_MAJOR=2
docker-image-ts2-14: TIMESCALEDB_VER=2.5.0
docker-image-ts2-14: docker-image-build-2-14

.PHONY: docker-image
docker-image: docker-image-ts2-14 docker-image-ts2-13 docker-image-ts2-12 docker-image-ts1
