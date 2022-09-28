#!/usr/bin/env bash

trap 'trap "" SIGINT SIGTERM; kill 0' SIGINT SIGTERM EXIT

# Ensure that we have the correct postgres tools on path
export PATH="/usr/lib/postgresql/${DEVENV_PG_VERSION}/bin:${PATH}"
# Ensure that the correct postgres tools are available for `docker exec`
echo "PATH=${PATH}" >> ~/.bashrc

# Set sensible postgres env vars
export PGPORT="288${DEVENV_PG_VERSION}"
export PGHOST=localhost
# Set sensible postgres env vars for `docker exec`
echo "export PGPORT=${PGPORT}" >> ~/.bashrc
echo "export PGHOST=${PGHOST}" >> ~/.bashrc

wait_for_db() {
    echo "waiting for DB"

    for _ in $(seq 10) ; do
      if pg_isready -d postgres -U postgres 1>/dev/null 2>&1; then
        echo "DB up"
        return 0
      fi
      echo -n "."
      sleep 1
    done
    echo
    echo "FAIL waiting for DB"
    exit 1
}

cargo pgx start "pg${DEVENV_PG_VERSION}"
wait_for_db
for db in template1 postgres; do
  psql -h localhost -U "$(whoami)" -p "${PGPORT}" -d $db -c 'CREATE EXTENSION IF NOT EXISTS timescaledb';
done
createdb -h localhost -p "${PGPORT}" "$(whoami)"

# This allows entr to work correctly on docker for mac
export ENTR_INOTIFY_WORKAROUND=true

# Note: this is not a comprehensive list of source files, if you think one is missing, add it
SOURCE_FILES="src migration"
find ${SOURCE_FILES} | entr cargo pgx install --features="pg${DEVENV_PG_VERSION}" > "${HOME}/compile.log" &

tail -f "${HOME}/.pgx/${DEVENV_PG_VERSION}.log" "${HOME}/compile.log" &

wait
