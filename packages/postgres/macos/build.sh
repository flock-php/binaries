#!/usr/bin/env bash
# Builds the PostgreSQL server, client tools and contrib extensions for macOS (Apple Silicon),
# with a static OpenSSL (pgcrypto, sslinfo) and only macOS system libraries otherwise.
# Relocatable: PostgreSQL finds share/ and lib/ relative to bin/, libraries are @loader_path.
# Usage: packages/postgres/macos/build.sh <version> <out-dir>
#   OPENSSL_VERSION  OpenSSL to link statically (required)
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
V="${1:?usage: build.sh <version> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: build.sh <version> <out-dir>}" && cd "$2" && pwd)"
: "${OPENSSL_VERSION:?OPENSSL_VERSION is required}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="${WORK_DIR:-$PWD/postgres-work}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
# Never pick up Homebrew's libraries or tools.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK" && cd "$WORK"
echo "::group::OpenSSL $OPENSSL_VERSION"
bash "$ROOT/scripts/macos/openssl.sh" "$OPENSSL_VERSION" "$WORK/openssl"
echo "::endgroup::"

echo "::group::Configure PostgreSQL $V"
bash "$ROOT/packages/postgres/source.sh" "$V" postgresql.tar.bz2
rm -rf src && mkdir src && tar -C src --strip-components 1 -xjf postgresql.tar.bz2
cd src
# Installed straight into OUT; relocate.sh then removes every reference to that path.
# libedit ships with macOS and gives psql line editing; ICU stays off (Flock uses --locale=C).
./configure --prefix="$OUT" --with-openssl --with-uuid=e2fs --without-icu --with-libedit-preferred --with-zlib \
  CPPFLAGS="-I$WORK/openssl/include" LDFLAGS="-L$WORK/openssl/lib"
echo "::endgroup::"

echo "::group::Build"
rm -rf "$OUT" && mkdir -p "$OUT"
make -j"$JOBS"
make -C contrib -j"$JOBS"
make install
make -C contrib install
echo "::endgroup::"

# Headers, static libraries and pkg-config files are only for building against PostgreSQL.
rm -rf "$OUT/include" "$OUT/lib/pkgconfig" "$OUT/share/doc" "$OUT/share/man"
find "$OUT/lib" -name '*.a' -delete
bash "$ROOT/scripts/macos/relocate.sh" "$OUT" "$OUT"

mkdir -p "$OUT/LICENSES"
cp COPYRIGHT "$OUT/LICENSES/postgresql.txt"
cp "$WORK/openssl/LICENSE.txt" "$OUT/LICENSES/openssl.txt"
"$OUT/bin/postgres" --version
