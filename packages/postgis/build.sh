#!/usr/bin/env bash
# Builds PostGIS for macOS or Linux against Flock's postgres package of one major, into the layout
# Flock links:
#   lib/        postgis-3, postgis_topology-3 (modules)
#   extension/  postgis, postgis_topology, postgis_tiger_geocoder (control and SQL files)
#   deps/       GEOS and PROJ, shared: the modules find them through their rpath (@loader_path,
#               $ORIGIN; on Linux Flock also puts deps/ on LD_LIBRARY_PATH)
#   share/proj  PROJ's data (proj.db): PROJ finds it as ../share/proj from its own library
# json-c (and on Linux SQLite and libxml2) are linked in statically; macOS has libxml2 and SQLite.
# Not included: raster (GDAL), SFCGAL, protobuf (ST_AsMVT, ST_AsGeobuf), address_standardizer
# (it would need the system's PCRE2 on Linux).
# Usage: packages/postgis/build.sh <version> <postgres-dir> <out-dir>
#   GEOS_VERSION PROJ_VERSION JSONC_TAG SQLITE_VERSION SQLITE_YEAR LIBXML2_VERSION CMAKE_VERSION
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../scripts/lib.sh"
V="${1:?usage: build.sh <version> <postgres-dir> <out-dir>}"
PG="$(cd "${2:?usage: build.sh <version> <postgres-dir> <out-dir>}" && pwd -P)"
OUT="$(mkdir -p "${3:?usage: build.sh <version> <postgres-dir> <out-dir>}" && cd "$3" && pwd)"
WORK="${WORK_DIR:-$PWD/postgis-work}"
PG_CONFIG="$PG/bin/pg_config"
JOBS="$(getconf _NPROCESSORS_ONLN)"
mkdir -p "$WORK" && cd "$WORK"

OS="$(uname -s)"
CMAKE=cmake RPATH=() BE=()
if [[ "$OS" == Darwin ]]; then
  CMAKE="$(macos_cmake "$WORK/cmake")"
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  # Modules link against the server; PostGIS' topology Makefile rewrites bindir, so name it outright.
  BE=(BE_DLLLIBS="-bundle_loader $PG/bin/postgres")
else
  RPATH=(-DCMAKE_INSTALL_RPATH='$ORIGIN')
fi
cmake_build() { # <source> <build> <args...>
  local src="$1" build="$2"; shift 2
  "$CMAKE" -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" "$@"
  "$CMAKE" --build "$build" -j"$JOBS"
  "$CMAKE" --install "$build"
}

echo "::group::Sources"
bash "$HERE/source.sh" "$V" "$WORK/sources"
rm -rf src && mkdir src
for f in sources/*; do tar -C src -xf "$f"; done
echo "::endgroup::"

STATIC="$WORK/static" # linked into the modules and libraries, not shipped
echo "::group::json-c (static)"
jsonc="$(cd src && ls -d json-c-*)"
cmake_build "src/$jsonc" jsonc-build -DCMAKE_INSTALL_PREFIX="$STATIC" -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_TESTING=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
echo "::endgroup::"

SQLITE=() XML2CONFIG=/usr/bin/xml2-config
if [[ "$OS" != Darwin ]]; then
  echo "::group::SQLite, libxml2 (static)"
  (cd "src/sqlite-autoconf-$SQLITE_VERSION" && CFLAGS="-O2 -fPIC" ./configure --prefix="$STATIC" --disable-shared --enable-static && make -j"$JOBS" && make install)
  (cd "src/libxml2-$LIBXML2_VERSION" && ./configure --prefix="$STATIC" --disable-shared --enable-static --with-pic \
    --without-python --without-icu --without-lzma --without-zlib --without-http --without-ftp && make -j"$JOBS" && make install)
  SQLITE=(-DSQLite3_INCLUDE_DIR="$STATIC/include" -DSQLite3_LIBRARY="$STATIC/lib/libsqlite3.a" -DEXE_SQLITE3="$STATIC/bin/sqlite3")
  XML2CONFIG="$STATIC/bin/xml2-config"
  echo "::endgroup::"
fi

echo "::group::GEOS $GEOS_VERSION, PROJ $PROJ_VERSION (shared, deps/)"
rm -rf "$OUT" && mkdir -p "$OUT"
cmake_build "src/geos-$GEOS_VERSION" geos-build -DCMAKE_INSTALL_PREFIX="$OUT" -DCMAKE_INSTALL_LIBDIR=deps \
  -DCMAKE_INSTALL_NAME_DIR="$OUT/deps" ${RPATH[@]+"${RPATH[@]}"} -DBUILD_TESTING=OFF -DBUILD_DOCUMENTATION=OFF
cmake_build "src/proj-$PROJ_VERSION" proj-build -DCMAKE_INSTALL_PREFIX="$OUT" -DCMAKE_INSTALL_LIBDIR=deps \
  -DCMAKE_INSTALL_NAME_DIR="$OUT/deps" ${RPATH[@]+"${RPATH[@]}"} ${SQLITE[@]+"${SQLITE[@]}"} \
  -DENABLE_TIFF=OFF -DENABLE_CURL=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DEMBED_PROJ_DATA_PATH=OFF
echo "::endgroup::"

echo "::group::PostGIS $V"
cd "src/postgis-$V"
LDFLAGS="-L$OUT/deps" ./configure --with-pgconfig="$PG_CONFIG" --with-geosconfig="$OUT/bin/geos-config" \
  --with-projdir="$OUT" --with-jsondir="$STATIC" --with-xml2config="$XML2CONFIG" \
  --without-raster --without-protobuf --without-gui --without-sfcgal --without-address-standardizer
# -j1: PostGIS' Makefiles generate the same raster SQL from two targets, which races in parallel.
make -j1 ${BE[@]+"${BE[@]}"}
rm -rf "$WORK/stage" && make install ${BE[@]+"${BE[@]}"} DESTDIR="$WORK/stage"
pg_collect "$WORK/stage" "$PG_CONFIG" "$OUT"
cd "$WORK"
echo "::endgroup::"

# Only for building against them: headers, CMake and pkg-config files, static libraries, tools.
rm -rf "$OUT/include" "$OUT/deps/cmake" "$OUT/deps/pkgconfig" "$OUT/bin"
find "$OUT/deps" -name '*.a' -delete
if [[ "$OS" == Darwin ]]; then
  bash "$HERE/../../scripts/macos/relocate.sh" "$OUT" "$OUT"
else
  for f in "$OUT"/lib/*.so; do patchelf --set-rpath '$ORIGIN/../deps' "$f"; done
  for f in "$OUT"/deps/*.so*; do [[ -f "$f" && ! -L "$f" ]] && patchelf --set-rpath '$ORIGIN' "$f"; done
  find "$OUT" -name '*.so*' -type f -exec strip --strip-unneeded {} +
fi

mkdir -p "$OUT/LICENSES"
cp "src/postgis-$V/COPYING" "$OUT/LICENSES/postgis.txt"
cp "src/geos-$GEOS_VERSION/COPYING" "$OUT/LICENSES/geos.txt"
cp "src/proj-$PROJ_VERSION/COPYING" "$OUT/LICENSES/proj.txt"
cp "src/$jsonc/COPYING" "$OUT/LICENSES/json-c.txt"
if [[ "$OS" != Darwin ]]; then
  cp "src/libxml2-$LIBXML2_VERSION/Copyright" "$OUT/LICENSES/libxml2.txt"
  echo "SQLite is in the public domain: https://sqlite.org/copyright.html" >"$OUT/LICENSES/sqlite.txt"
fi
du -sh "$OUT"/*
