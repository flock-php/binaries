#!/usr/bin/env bash
# Builds MariaDB for Linux (x64 or arm64, whichever machine it runs on). MariaDB's own Linux
# tarballs are x64 only and link libraries not every distribution has (libaio, liburing); this
# build links a static OpenSSL and the bundled libraries instead, and otherwise only glibc and
# ncurses. Same configuration as the macOS build where it applies.
# Usage: packages/mariadb/linux/build.sh <version> <out-dir>
#   OPENSSL_VERSION  OpenSSL to link statically (required)
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
V="${1:?usage: build.sh <version> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: build.sh <version> <out-dir>}" && cd "$2" && pwd)"
: "${OPENSSL_VERSION:?OPENSSL_VERSION is required}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="${WORK_DIR:-$PWD/mariadb-work}"
JOBS="$(nproc)"

mkdir -p "$WORK" && cd "$WORK"
echo "::group::OpenSSL $OPENSSL_VERSION"
bash "$ROOT/scripts/linux/openssl.sh" "$OPENSSL_VERSION" "$WORK/openssl"
echo "::endgroup::"

echo "::group::Configure MariaDB $V"
bash "$ROOT/packages/mariadb/source.sh" "$V" mariadb.tar.gz
rm -rf src build && mkdir src build
tar -C src --strip-components 1 -xzf mariadb.tar.gz
# STANDALONE is the layout of MariaDB's own binary tarballs: bin/, scripts/, share/, lib/plugin/,
# usable from any directory with --basedir. InnoDB falls back to its own I/O threads without
# libaio and liburing; the compression providers, PAM, GSSAPI and the key management, S3, DuckDB and
# CONNECT plugins would each need another library from the system.
cmake -S src -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DINSTALL_LAYOUT=STANDALONE \
  -DCMAKE_INSTALL_PREFIX="$OUT" \
  -DWITH_SSL="$WORK/openssl" \
  -DWITH_PCRE=bundled \
  -DWITH_ZLIB=bundled \
  -DWITH_LIBFMT=bundled \
  -DWITH_SYSTEMD=no \
  -DWITH_NUMA=NO \
  -DCMAKE_DISABLE_FIND_PACKAGE_URING=ON -DCMAKE_DISABLE_FIND_PACKAGE_LIBAIO=ON \
  -DWITH_URING=NO -DWITH_LIBAIO=NO \
  -DPLUGIN_TOKUDB=NO -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO -DPLUGIN_CONNECT=NO \
  -DPLUGIN_OQGRAPH=NO -DPLUGIN_SPHINX=NO -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_S3=NO -DPLUGIN_DUCKDB=NO \
  -DPLUGIN_HASHICORP_KEY_MANAGEMENT=NO -DPLUGIN_AUTH_PAM=NO -DPLUGIN_AUTH_PAM_V1=NO \
  -DPLUGIN_AUTH_GSSAPI=NO -DPLUGIN_AUTH_GSSAPI_CLIENT=OFF \
  -DPLUGIN_PROVIDER_BZIP2=NO -DPLUGIN_PROVIDER_LZ4=NO -DPLUGIN_PROVIDER_LZMA=NO \
  -DPLUGIN_PROVIDER_LZO=NO -DPLUGIN_PROVIDER_SNAPPY=NO \
  -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_WSREP=OFF
echo "::endgroup::"

echo "::group::Build"
cmake --build build -j "$JOBS"
rm -rf "$OUT"
cmake --install build
echo "::endgroup::"

rm -rf "$OUT/mysql-test" "$OUT/sql-bench" "$OUT/man" "$OUT/include" "$OUT/share/doc"
# Test, benchmark, backup and storage-engine repair tools (statically linked, ~9 MB each).
rm -f "$OUT"/bin/mariadb-test* "$OUT"/bin/mysqltest* "$OUT"/bin/mariadb-client-test* "$OUT"/bin/mysql_client_test* \
  "$OUT"/bin/mariadb-backup "$OUT"/bin/mariabackup "$OUT"/bin/mbstream "$OUT"/bin/mariadb-slap "$OUT"/bin/mysqlslap \
  "$OUT"/bin/aria_* "$OUT"/bin/myisam* "$OUT"/bin/mariadb-ldb "$OUT"/bin/sst_dump
find "$OUT/lib" -name '*.a' -delete
find "$OUT/bin" "$OUT/lib" -type f \( -perm -u+x -o -name '*.so*' \) -exec sh -c 'file -b "$1" | grep -q ^ELF && strip --strip-unneeded "$1"' _ {} \;

mkdir -p "$OUT/LICENSES"
cp src/COPYING "$OUT/LICENSES/mariadb.txt"
cp "$WORK/openssl/LICENSE.txt" "$OUT/LICENSES/openssl.txt"
"$OUT/bin/mariadbd" --version
