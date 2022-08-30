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
sed -i'' "s/^version.*=.*\"${OLD_VERSION}\"\$/version = \"${NEW_VERSION}\"/g" Cargo.toml

cargo update --workspace

# replace current version with new version in *.md
sed -i'' "s/${OLD_VERSION}/${NEW_VERSION}/g" INSTALL.md
