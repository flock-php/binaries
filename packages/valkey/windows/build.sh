#!/usr/bin/env bash
# Builds Valkey for Windows with MSYS2 (run inside the MSYS shell, not MINGW).
# The result links against msys-2.0.dll (the POSIX layer that gives Valkey fork()), which is
# shipped next to the executables together with every other msys-*.dll they need.
#
# Usage: packages/valkey/windows/build.sh <version> <out-dir>
# Approach borrowed from https://github.com/redis-windows/redis-windows.
set -euo pipefail

VERSION="${1:?usage: build.sh <version> <out-dir>}"
OUT="${2:?usage: build.sh <version> <out-dir>}"
WORK="$PWD/valkey-work"

mkdir -p "$WORK" && cd "$WORK"
if [[ ! -d "valkey-$VERSION" ]]; then
  curl -fsSL "https://github.com/valkey-io/valkey/archive/refs/tags/$VERSION.tar.gz" | tar xz
fi

# MSYS2's dlfcn.h hides dladdr() behind __GNU_VISIBLE, which Valkey's crash reporter needs.
sed -i 's/__GNU_VISIBLE/1/' /usr/include/dlfcn.h

cd "valkey-$VERSION"
# TLS stays off like on macOS: Flock only listens on 127.0.0.1.
make -j"$(nproc)" BUILD_TLS=no MALLOC=libc USE_SYSTEMD=no CFLAGS="-Wno-char-subscripts"

cd "$WORK/.."
rm -rf "$OUT" && mkdir -p "$OUT"
for bin in valkey-server valkey-cli valkey-benchmark; do
  cp "$WORK/valkey-$VERSION/src/$bin.exe" "$OUT/"
done
# Ship every MSYS DLL the executables load, found by asking the loader rather than guessing.
for dll in $(ldd "$OUT"/*.exe | awk '/\/usr\/bin\/msys-.*\.dll/ {print $3}' | sort -u); do
  cp "$dll" "$OUT/"
done
cp "$WORK/valkey-$VERSION/COPYING" "$OUT/LICENSE.txt" 2>/dev/null || cp "$WORK/valkey-$VERSION/LICENSE"* "$OUT/" || true

ls -la "$OUT"
"$OUT/valkey-server.exe" --version
