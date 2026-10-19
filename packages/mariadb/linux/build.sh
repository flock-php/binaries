#!/usr/bin/env bash
# Builds MariaDB for Linux with the configuration of the macOS build (packages/mariadb/macos):
# a static OpenSSL, bundled zlib and PCRE, the STANDALONE layout of MariaDB's own tarballs. The
# client's line editing (libedit, ncurses) comes from the build container and is bundled in lib/
# (scripts/linux/bundle.sh). No libaio: InnoDB then does its I/O with its own threads, and the
# package doesn't depend on libaio.so.1, which Ubuntu 24.04 renamed. No systemd either.
# Runs in the manylinux_2_28 container (build-service.yml, AlmaLinux 8), so it needs glibc 2.28.
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

echo "::group::Build dependencies"
# libedit-devel is in AlmaLinux 8's PowerTools repository; OpenSSL's Configure needs Perl's core
# modules (IPC::Cmd), which the image's minimal Perl lacks; source.sh reads the checksum with jq.
dnf install -y -q --enablerepo=powertools libedit-devel ncurses-devel bison perl jq
echo "::endgroup::"

mkdir -p "$WORK" && cd "$WORK"
echo "::group::OpenSSL $OPENSSL_VERSION"
bash "$ROOT/scripts/linux/openssl.sh" "$OPENSSL_VERSION" "$WORK/openssl"
echo "::endgroup::"

echo "::group::Configure MariaDB $V"
bash "$ROOT/packages/mariadb/source.sh" "$V" mariadb.tar.gz
rm -rf src build && mkdir src build
tar -C src --strip-components 1 -xzf mariadb.tar.gz
cmake -S src -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DINSTALL_LAYOUT=STANDALONE \
  -DCMAKE_INSTALL_PREFIX="$OUT" \
  -DWITH_SSL="$WORK/openssl" \
  -DWITH_PCRE=bundled \
  -DWITH_ZLIB=bundled \
  -DWITH_LIBEDIT=OFF -DWITH_READLINE=OFF `# not the bundled copies: the container's libedit` \
  -DWITH_URING=NO -DWITH_LIBAIO=NO -DWITH_SYSTEMD=no \
  -DPLUGIN_TOKUDB=NO -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO -DPLUGIN_CONNECT=NO \
  -DPLUGIN_OQGRAPH=NO -DPLUGIN_SPHINX=NO -DPLUGIN_COLUMNSTORE=NO \
  -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_WSREP=OFF
echo "::endgroup::"

echo "::group::Build"
cmake --build build -j "$JOBS"
rm -rf "$OUT"
cmake --install build
echo "::endgroup::"

rm -rf "$OUT/mysql-test" "$OUT/sql-bench" "$OUT/man" "$OUT/include" "$OUT/share/doc"
# Test, benchmark, backup and storage-engine repair tools, as on macOS.
rm -f "$OUT"/bin/mariadb-test* "$OUT"/bin/mysqltest* "$OUT"/bin/mariadb-client-test* "$OUT"/bin/mysql_client_test* \
  "$OUT"/bin/mariadb-backup "$OUT"/bin/mariabackup "$OUT"/bin/mbstream "$OUT"/bin/mariadb-slap "$OUT"/bin/mysqlslap \
  "$OUT"/bin/aria_* "$OUT"/bin/myisam* "$OUT"/bin/mariadb-ldb "$OUT"/bin/sst_dump
find "$OUT/lib" -name '*.a' -delete
bash "$ROOT/scripts/linux/bundle.sh" "$OUT"

mkdir -p "$OUT/LICENSES"
cp src/COPYING "$OUT/LICENSES/mariadb.txt"
cp "$WORK/openssl/LICENSE.txt" "$OUT/LICENSES/openssl.txt"
"$OUT/bin/mariadbd" --version
