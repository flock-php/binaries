#!/usr/bin/env bash
# Fetches the TimescaleDB source of a release tag: the release has no source archive or checksum,
# so the tag is cloned (git checks every object by its hash) and its commit printed.
# Usage: packages/timescaledb/source.sh <version> <dir>
set -euo pipefail
V="${1:?usage: source.sh <version> <dir>}"; DIR="${2:?usage: source.sh <version> <dir>}"
rm -rf "$DIR"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$V" https://github.com/timescale/timescaledb.git "$DIR"
git -C "$DIR" rev-parse HEAD
