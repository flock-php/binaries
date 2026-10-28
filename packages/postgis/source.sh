#!/usr/bin/env bash
# Downloads the source of PostGIS and of the libraries the package bundles, each checked against
# what upstream publishes: PostGIS (MD5 file on download.osgeo.org, or its git tag where a release
# has none) and PROJ (MD5 file), GEOS and json-c
# (the SHA-256 GitHub recorded for the release asset), SQLite (SHA3-256 on its download page) and
# libxml2 (GNOME's .sha256sum), the last two for Linux, where they are linked in. The folder is
# what the build unpacks and what is published as the package's source (GPL-2.0, GEOS LGPL).
# Usage: packages/postgis/source.sh <version> <dir>
#   GEOS_VERSION PROJ_VERSION JSONC_TAG SQLITE_VERSION SQLITE_YEAR LIBXML2_VERSION (versions.json)
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <dir>}"; DIR="${2:?usage: source.sh <version> <dir>}"
rm -rf "$DIR" && mkdir -p "$DIR" && cd "$DIR"

f="postgis-$V.tar.gz"
if md5="$(fetch_text "https://download.osgeo.org/postgis/source/$f.md5" 2>/dev/null)"; then
  fetch "https://download.osgeo.org/postgis/source/$f" "$f"
  check_md5 "$f" "$(cut -d' ' -f1 <<<"$md5")"
else
  # Some releases have no .md5 (3.6.2): their source is the release tag instead, cloned (git
  # checks every object by its hash). It has no generated configure: only what OSGeo builds for
  # Windows uses such a release, which publishes this source and doesn't build from it.
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$V" https://github.com/postgis/postgis.git "postgis-$V"
  echo "postgis $V: no checksum on download.osgeo.org, the git tag instead: commit $(git -C "postgis-$V" rev-parse HEAD)"
  tar --exclude .git -czf "postgis-$V-git.tar.gz" "postgis-$V" && rm -rf "postgis-$V"
fi

f="geos-$GEOS_VERSION.tar.bz2"
fetch "https://github.com/libgeos/geos/releases/download/$GEOS_VERSION/$f" "$f"
check_sha256 "$f" "$(github_digest libgeos/geos "$GEOS_VERSION" "$f")"

f="proj-$PROJ_VERSION.tar.gz"
fetch "https://download.osgeo.org/proj/$f" "$f"
check_md5 "$f" "$(fetch_text "https://download.osgeo.org/proj/$f.md5" | awk '{print $NF}')" # MD5 (file) = <hash>

v="${JSONC_TAG#json-c-}"; f="json-c-${v%-*}.tar.gz" # tag json-c-0.19-20260627: json-c-0.19.tar.gz
fetch "https://github.com/json-c/json-c/releases/download/$JSONC_TAG/$f" "$f"
check_sha256 "$f" "$(github_digest json-c/json-c "$JSONC_TAG" "$f")"

f="sqlite-autoconf-$SQLITE_VERSION.tar.gz"
fetch "https://www.sqlite.org/$SQLITE_YEAR/$f" "$f"
want="$(fetch_text https://www.sqlite.org/download.html | awk -F, -v f="$SQLITE_YEAR/$f" '$1 == "PRODUCT" && $3 == f {print $5}')"
got="$(python3 -c 'import hashlib, sys; print(hashlib.sha3_256(open(sys.argv[1], "rb").read()).hexdigest())' "$f")"
[[ -n "$want" && "$got" == "$want" ]] || { echo "::error::$f: SHA3-256 $got, expected ${want:-(none)}" >&2; exit 1; }
echo "✓ $f SHA3-256 $got"

f="libxml2-$LIBXML2_VERSION.tar.xz"
fetch "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/$f" "$f"
check_sha256 "$f" "$(fetch_text "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-$LIBXML2_VERSION.sha256sum" | awk -v f="$f" '$2 == f {print $1}')"
