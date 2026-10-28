#!/usr/bin/env bash
# Downloads OSGeo's PostGIS bundle for Windows of a PostgreSQL major (PostGIS and pgRouting built
# for PostgreSQL's own MSVC builds, with GEOS, PROJ and the rest), checked against the MD5 OSGeo
# publishes next to it, and unpacks it. Without a version, the current bundle of the major; with
# one, that bundle, from the major's folder or its archive/. Prints the bundle's folder.
# Usage: scripts/osgeo-bundle.sh <major> <dir> [<postgis-version>]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
MAJOR="${1:?usage: osgeo-bundle.sh <major> <dir> [<postgis-version>]}"; DIR="${2:?}"; V="${3:-}"
base="https://download.osgeo.org/postgis/windows/pg$MAJOR"
if [[ -z "$V" ]]; then
  V="$(fetch_text "$base/" | grep -o "postgis-bundle-pg$MAJOR-[0-9.]*x64\.zip\"" | sed -E 's/.*-([0-9.]+)x64.*/\1/' | sort -V | tail -1)"
  [[ -n "$V" ]] || { echo "::error::no PostGIS bundle for PostgreSQL $MAJOR" >&2; exit 1; }
fi
name="postgis-bundle-pg$MAJOR-${V}x64.zip"
url="$base/$name"
curl -fsI "$url" >/dev/null 2>&1 || url="$base/archive/$name"
rm -rf "$DIR" && mkdir -p "$DIR"
fetch "$url" "$DIR/$name" >&2
check_md5 "$DIR/$name" "$(fetch_text "$url.md5" | awk '{print $1}')" >&2
(cd "$DIR" && unzip -q "$name" && rm "$name")
dirname "$(find "$DIR" -name postgis.control | head -1)" | sed 's|/share/extension$||'
