#!/usr/bin/env bash

# Note: we cut on both ':' and '@' here to support pre-1.62.0 and post 1.62.0 `cargo pkgid` output
command -v cargo >/dev/null && cargo pkgid | cut -d'#' -f2 | cut -d':' -f2 | cut -d'@' -f2
