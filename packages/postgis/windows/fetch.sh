#!/usr/bin/env bash
# PostGIS for Windows is OSGeo's build: its bundle for the major, of this PostGIS version.
# Usage: packages/postgis/windows/fetch.sh <version> <major> <dir>
set -euo pipefail
bash "$(dirname "$0")/../../../scripts/osgeo-bundle.sh" "${2:?}" "${3:?}" "${1:?}" >/dev/null
