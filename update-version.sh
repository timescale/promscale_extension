#!/usr/bin/env bash

# Updates the extension version in all places necessary

set -euo pipefail

SED_ESCAPE_DOTS='s/\./\\\./g'

if [ -z "${1:-}" ]; then
    echo "No version provided"
    exit 1
fi

NEW_VERSION=$(echo "$1" | sed ${SED_ESCAPE_DOTS})

# extract current version from Cargo.toml
OLD_VERSION=$(bash extract-extension-version.sh | tr -d '\n' | sed ${SED_ESCAPE_DOTS})

# replace current version with new version in Cargo.toml
# Note: some care has been taken to make this command portable between Unix and
# BSD sed, hence the "slightly weird" invocation here.
sed -i.bak -e "s/^version.*=.*\"${OLD_VERSION}\"\$/version = \"${NEW_VERSION}\"/g" Cargo.toml && rm Cargo.toml.bak

cargo update --workspace

if [ -z "${NEW_VERSION##*-dev}" ]; then
    echo "Skipping INSTALL.md because it's a dev version."
else
    # replace current version with new version in *.md
    # Note: some care has been taken to make this command portable between Unix and
    # BSD sed, hence the "slightly weird" invocation here.
    sed -i.bak -e "s/${OLD_VERSION}/${NEW_VERSION}/g" INSTALL.md && rm INSTALL.md.bak
fi