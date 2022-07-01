#!/usr/bin/env bash

prev_versions=$(cat promscale.control | sed -n 's/# upgradeable_from = \(.*\)/\1/p' | sed "s/[[:space:]']//g" | tr ',' '\n')
cur_version=$(./extract-extension-version.sh | tr -d '\n')

for prev_version in $prev_versions; do
  if [ -n "${prev_version}" ] && [ -n "${cur_version}" ]; then
    ln -s -f "promscale--${cur_version}.sql" "sql/promscale--${prev_version}--${cur_version}.sql"
  fi
done
