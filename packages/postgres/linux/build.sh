#!/usr/bin/env bash
# Builds the PostgreSQL server, client tools and contrib extensions for Linux, with a static OpenSSL
# (pgcrypto, sslinfo). zlib, libuuid (uuid-ossp) and libedit (psql's line editing) come from the
# build container and are bundled in lib/ (scripts/linux/bundle.sh). Relocatable: PostgreSQL finds
# share/ and lib/ relative to bin/, and every binary finds lib/ through $ORIGIN.
# Runs in the manylinux_2_28 container (build-service.yml, AlmaLinux 8), so it needs glibc 2.28.
# Usage: packages/postgres/linux/build.sh <version> <out-dir>
#   OPENSSL_VERSION  OpenSSL to link statically (required)
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
V="${1:?usage: build.sh <version> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: build.sh <version> <out-dir>}" && cd "$2" && pwd)"
: "${OPENSSL_VERSION:?OPENSSL_VERSION is required}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="${WORK_DIR:-$PWD/postgres-work}"
JOBS="$(nproc)"

echo "::group::Build dependencies"
# libedit-devel is in AlmaLinux 8's PowerTools repository; OpenSSL's Configure needs Perl's core
# modules (IPC::Cmd), which the image's minimal Perl lacks; PostgreSQL's configure wants flex.
dnf install -y -q --enablerepo=powertools libedit-devel libuuid-devel zlib-devel perl flex
echo "::endgroup::"

mkdir -p "$WORK" && cd "$WORK"
echo "::group::OpenSSL $OPENSSL_VERSION"
bash "$ROOT/scripts/linux/openssl.sh" "$OPENSSL_VERSION" "$WORK/openssl"
echo "::endgroup::"

echo "::group::Configure PostgreSQL $V"
bash "$ROOT/packages/postgres/source.sh" "$V" postgresql.tar.bz2
rm -rf src && mkdir src && tar -C src --strip-components 1 -xjf postgresql.tar.bz2
cd src
# Installed straight into OUT without an rpath; bundle.sh then gives every binary an $ORIGIN one.
# ICU stays off (Flock uses --locale=C). The static libcrypto needs libdl and libpthread.
./configure --prefix="$OUT" --disable-rpath --with-openssl --with-uuid=e2fs --without-icu \
  --with-libedit-preferred --with-zlib \
  CPPFLAGS="-I$WORK/openssl/include" LDFLAGS="-L$WORK/openssl/lib" LIBS="-ldl -lpthread"
echo "::endgroup::"

# PostgreSQL 15+ refuses a libpq that references exit functions (libpq-refs-stamp, using nm).
# The static OpenSSL brings two: atexit (its cleanup handler) and pthread_exit, neither of which
# libpq calls on its own. Hide just those two from the check; anything else still fails it.
mkdir -p "$WORK/nm"
cat >"$WORK/nm/nm" <<'NM'
#!/bin/sh
/usr/bin/nm "$@" | grep -v -E ' (atexit|pthread_exit)(@[A-Z_0-9.@]*)?$'
NM
chmod +x "$WORK/nm/nm"

echo "::group::Build"
rm -rf "$OUT" && mkdir -p "$OUT"
PATH="$WORK/nm:$PATH" make -j"$JOBS"
make -C contrib -j"$JOBS"
make install
make -C contrib install
echo "::endgroup::"

# Headers, static libraries and pkg-config files are only for building against PostgreSQL.
rm -rf "$OUT/include" "$OUT/lib/pkgconfig" "$OUT/share/doc" "$OUT/share/man"
find "$OUT/lib" -name '*.a' -delete
bash "$ROOT/scripts/linux/bundle.sh" "$OUT"

mkdir -p "$OUT/LICENSES"
cp COPYRIGHT "$OUT/LICENSES/postgresql.txt"
cp "$WORK/openssl/LICENSE.txt" "$OUT/LICENSES/openssl.txt"
"$OUT/bin/postgres" --version
