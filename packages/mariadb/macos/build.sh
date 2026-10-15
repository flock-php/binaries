#!/usr/bin/env bash
# Builds MariaDB for macOS (Apple Silicon), which has no upstream binaries. A static OpenSSL is
# built first (the macOS SDK has none); Homebrew is ignored, so the result links only against
# macOS system libraries. Same configuration as Flock's local build (internal/catalog/mariadb.sh).
# Usage: packages/mariadb/macos/build.sh <version> <out-dir>
#   OPENSSL_VERSION  OpenSSL to link statically (required)
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
V="${1:?usage: build.sh <version> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: build.sh <version> <out-dir>}" && cd "$2" && pwd)"
: "${OPENSSL_VERSION:?OPENSSL_VERSION is required}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="${WORK_DIR:-$PWD/mariadb-work}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
CMAKE="$(command -v cmake)"
export PATH="$(dirname "$CMAKE"):/usr/bin:/bin:/usr/sbin:/sbin"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK" && cd "$WORK"
echo "::group::OpenSSL $OPENSSL_VERSION"
bash "$ROOT/scripts/macos/openssl.sh" "$OPENSSL_VERSION" "$WORK/openssl"
echo "::endgroup::"

echo "::group::Configure MariaDB $V"
bash "$ROOT/packages/mariadb/source.sh" "$V" mariadb.tar.gz
rm -rf src build && mkdir src build
tar -C src --strip-components 1 -xzf mariadb.tar.gz
# STANDALONE is the layout of MariaDB's own binary tarballs: bin/, scripts/, share/, lib/plugin/,
# usable from any directory with --basedir.
"$CMAKE" -S src -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DINSTALL_LAYOUT=STANDALONE \
  -DCMAKE_INSTALL_PREFIX="$OUT" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DWITH_SSL="$WORK/openssl" \
  -DWITH_PCRE=bundled \
  -DWITH_ZLIB=system \
  -DPLUGIN_TOKUDB=NO -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO -DPLUGIN_CONNECT=NO \
  -DPLUGIN_OQGRAPH=NO -DPLUGIN_SPHINX=NO -DPLUGIN_COLUMNSTORE=NO \
  -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_WSREP=OFF
echo "::endgroup::"

echo "::group::Build"
"$CMAKE" --build build -j "$JOBS"
rm -rf "$OUT"
"$CMAKE" --install build
echo "::endgroup::"

rm -rf "$OUT/mysql-test" "$OUT/sql-bench" "$OUT/man" "$OUT/include" "$OUT/share/doc"
# Test, benchmark, backup and storage-engine repair tools (statically linked, ~9 MB each).
rm -f "$OUT"/bin/mariadb-test* "$OUT"/bin/mysqltest* "$OUT"/bin/mariadb-client-test* "$OUT"/bin/mysql_client_test* \
  "$OUT"/bin/mariadb-backup "$OUT"/bin/mariabackup "$OUT"/bin/mbstream "$OUT"/bin/mariadb-slap "$OUT"/bin/mysqlslap \
  "$OUT"/bin/aria_* "$OUT"/bin/myisam* "$OUT"/bin/mariadb-ldb "$OUT"/bin/sst_dump
find "$OUT/lib" -name '*.a' -delete
bash "$ROOT/scripts/macos/relocate.sh" "$OUT" "$OUT"

mkdir -p "$OUT/LICENSES"
cp src/COPYING "$OUT/LICENSES/mariadb.txt"
cp "$WORK/openssl/LICENSE.txt" "$OUT/LICENSES/openssl.txt"
"$OUT/bin/mariadbd" --version
