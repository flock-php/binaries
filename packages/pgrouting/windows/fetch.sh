#!/usr/bin/env bash
# pgRouting for Windows is OSGeo's build, in its PostGIS bundle for the major: the current one,
# which has to carry this pgRouting version (flockrel's osgeo-bundle lookup read it from there).
# Usage: packages/pgrouting/windows/fetch.sh <version> <major> <dir>
set -euo pipefail
V="${1:?usage: fetch.sh <version> <major> <dir>}"; MAJOR="${2:?}"; DIR="${3:?}"
root="$(bash "$(dirname "$0")/../../../scripts/osgeo-bundle.sh" "$MAJOR" "$DIR")"
[[ -f "$root/share/extension/pgrouting--$V.sql" ]] \
  || { echo "::error::OSGeo's bundle for PostgreSQL $MAJOR has no pgRouting $V: $(ls "$root/share/extension" | grep -E '^pgrouting--[0-9.]+\.sql$')" >&2; exit 1; }
