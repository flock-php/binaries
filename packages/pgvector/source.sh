#!/usr/bin/env bash
# Fetches the pgvector source of a release tag. pgvector publishes no checksums or release
# archives, only git tags: the tag is cloned (git checks every object by its hash) and its commit
# printed, so flock-package.json can record what was built.
# Usage: packages/pgvector/source.sh <version> <dir>
set -euo pipefail
V="${1:?usage: source.sh <version> <dir>}"; DIR="${2:?usage: source.sh <version> <dir>}"
rm -rf "$DIR"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$V" https://github.com/pgvector/pgvector.git "$DIR"
git -C "$DIR" rev-parse HEAD
