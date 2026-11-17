#!/usr/bin/env bash
# Builds the PostgreSQL server, client tools and contrib extensions for Linux (x64 or arm64,
# whichever machine it runs on), with a static OpenSSL (pgcrypto, sslinfo) and ICU (collations),
# and otherwise only libraries every distribution has (glibc, libstdc++, zlib, libuuid).
# Relocatable: PostgreSQL finds share/ and lib/ relative to bin/, and the programs find libpq
# through $ORIGIN.
# psql has no line editing: readline is GPL, and libedit isn't installed everywhere.
# Usage: packages/postgres/linux/build.sh <version> <out-dir>
#   OPENSSL_VERSION  OpenSSL to link statically (required)
#   ICU_VERSION      ICU to link statically (required)
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
V="${1:?usage: build.sh <version> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: build.sh <version> <out-dir>}" && cd "$2" && pwd)"
: "${OPENSSL_VERSION:?OPENSSL_VERSION is required}"
: "${ICU_VERSION:?ICU_VERSION is required}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="${WORK_DIR:-$PWD/postgres-work}"
JOBS="$(nproc)"

mkdir -p "$WORK" && cd "$WORK"
echo "::group::OpenSSL $OPENSSL_VERSION"
bash "$ROOT/scripts/linux/openssl.sh" "$OPENSSL_VERSION" "$WORK/openssl"
echo "::endgroup::"
echo "::group::ICU $ICU_VERSION"
bash "$ROOT/scripts/linux/icu.sh" "$ICU_VERSION" "$WORK/icu"
echo "::endgroup::"

echo "::group::Configure PostgreSQL $V"
bash "$ROOT/packages/postgres/source.sh" "$V" postgresql.tar.bz2
rm -rf src && mkdir src && tar -C src --strip-components 1 -xjf postgresql.tar.bz2
cd src
# Installed straight into OUT, without its absolute path as rpath (patchelf sets $ORIGIN below).
# ICU is the static one from above, named outright (ICU_CFLAGS, ICU_LIBS) rather than found through
# pkg-config; it's C++, so postgres and initdb link the system's libstdc++ (shared: a static one
# would clash with the libstdc++ of C++ extensions such as PostGIS, loaded into the same process).
./configure --prefix="$OUT" --disable-rpath --with-openssl --with-uuid=e2fs --with-icu --without-readline --with-zlib \
  CPPFLAGS="-I$WORK/openssl/include" LDFLAGS="-L$WORK/openssl/lib" \
  ICU_CFLAGS="-I$WORK/icu/include" ICU_LIBS="-L$WORK/icu/lib -licui18n -licuuc -licudata -lstdc++ -lm"
echo "::endgroup::"

# PostgreSQL 15+ refuses a libpq that references exit functions (libpq-refs-stamp, using nm).
# The static OpenSSL brings two: atexit (its cleanup handler) and pthread_exit, neither of which
# libpq calls on its own. Hide just those two from the check; anything else still fails it.
mkdir -p "$WORK/nm"
cat >"$WORK/nm/nm" <<'NM'
#!/bin/sh
/usr/bin/nm "$@" | grep -v -E ' (atexit|pthread_exit)(@.*)?$'
NM
chmod +x "$WORK/nm/nm"

echo "::group::Build"
rm -rf "$OUT" && mkdir -p "$OUT"
PATH="$WORK/nm:$PATH" make -j"$JOBS"
make -C contrib -j"$JOBS"
make install
make -C contrib install
echo "::endgroup::"

# The headers and PGXS stay, so extensions can be built against this PostgreSQL (pg_config).
rm -rf "$OUT/lib/pkgconfig" "$OUT/share/doc" "$OUT/share/man"
find "$OUT/lib" -name '*.a' -delete
find "$OUT/bin" "$OUT/lib" -type f \( -perm -u+x -o -name '*.so*' \) -exec strip --strip-unneeded {} + 2>/dev/null || true
# The programs and libraries in lib/ (ecpg's link libpq) find libpq next to them, wherever unpacked.
for f in "$OUT"/bin/* "$OUT"/lib/*.so*; do
  [[ -f "$f" && ! -L "$f" ]] && file -b "$f" | grep -q '^ELF' && patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN' "$f"
done

mkdir -p "$OUT/LICENSES"
cp COPYRIGHT "$OUT/LICENSES/postgresql.txt"
cp "$WORK/openssl/LICENSE.txt" "$OUT/LICENSES/openssl.txt"
cp "$WORK/icu/LICENSE" "$OUT/LICENSES/icu.txt"
"$OUT/bin/postgres" --version
