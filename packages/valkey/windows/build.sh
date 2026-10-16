#!/usr/bin/env bash
# Builds Valkey for Windows with MSYS2 (run inside the MSYS shell, not MINGW).
# The result links against msys-2.0.dll (the POSIX layer that gives Valkey fork()), which is
# shipped next to the executables together with every other msys-*.dll they need.
#
# Usage: packages/valkey/windows/build.sh <version> <out-dir>
#   SOURCES_DIR  where the MSYS2 runtime's source package goes (default: ./sources)
# Approach borrowed from https://github.com/redis-windows/redis-windows.
set -euo pipefail

VERSION="${1:?usage: build.sh <version> <out-dir>}"
OUT="${2:?usage: build.sh <version> <out-dir>}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$PWD/valkey-work"
SOURCES="${SOURCES_DIR:-$PWD/sources}"

mkdir -p "$WORK" && cd "$WORK"
# The work directory sits inside this repository: without this, the version string would
# record our commit (mkreleasehdr.sh asks git) instead of 00000000 for a release tarball.
export GIT_DIR="$WORK/no-git"
if [[ ! -d "valkey-$VERSION" ]]; then
  bash "$ROOT/packages/valkey/source.sh" "$VERSION" valkey.tar.gz
  mkdir "valkey-$VERSION" && tar -C "valkey-$VERSION" --strip-components 1 -xzf valkey.tar.gz
fi

# MSYS2's dlfcn.h hides dladdr() behind __GNU_VISIBLE, which Valkey's crash reporter needs.
sed -i 's/__GNU_VISIBLE/1/' /usr/include/dlfcn.h

cd "valkey-$VERSION"
# TLS stays off like on macOS: Flock only listens on 127.0.0.1.
# _GNU_SOURCE: MSYS's newlib only declares asprintf() and friends with it.
make -j"$(nproc)" BUILD_TLS=no MALLOC=libc USE_SYSTEMD=no CFLAGS="-D_GNU_SOURCE -Wno-char-subscripts"

cd "$WORK/.."
rm -rf "$OUT" && mkdir -p "$OUT/LICENSES"
for bin in valkey-server valkey-cli valkey-benchmark; do
  cp "$WORK/valkey-$VERSION/src/$bin.exe" "$OUT/"
done
# Ship every MSYS DLL the executables load, found by asking the loader rather than guessing.
for dll in $(ldd "$OUT"/*.exe | awk '/\/usr\/bin\/msys-.*\.dll/ {print $3}' | sort -u); do
  cp "$dll" "$OUT/"
done
cp "$WORK/valkey-$VERSION/COPYING" "$OUT/LICENSES/valkey.txt"
# The MSYS2 runtime (msys-2.0.dll, Cygwin: LGPLv3+) travels with its license and exact version.
# Its source package goes to $SOURCES (published on the release next to the package, for the
# LGPL), checked against MSYS2's signature. msys-gcc_s-seh-1.dll is GCC's runtime library, which
# its runtime library exception lets us ship without its source.
cp /usr/share/licenses/msys2-runtime/* "$OUT/LICENSES/" 2>/dev/null || true
runtime="$(pacman -Q msys2-runtime | awk '{print $2}')"
echo "msys2-runtime $runtime" > "$OUT/LICENSES/msys2-runtime-version.txt"
src="msys2-runtime-$runtime.src.tar.zst"
mkdir -p "$SOURCES"
curl -fsSL --retry 3 -o "$SOURCES/$src" "https://repo.msys2.org/msys/sources/$src"
curl -fsSL --retry 3 -o "$SOURCES/$src.sig" "https://repo.msys2.org/msys/sources/$src.sig"
# gpgv with pacman's keyring (MSYS2's packager keys): pacman-key --verify wants write access to it.
keyring=/etc/pacman.d/gnupg/pubring.gpg
[[ -f "$keyring" ]] || keyring=/etc/pacman.d/gnupg/pubring.kbx
gpgv --keyring "$keyring" "$SOURCES/$src.sig" "$SOURCES/$src"
rm "$SOURCES/$src.sig"
echo "✓ $src (signature verified)"

ls -la "$OUT"
# From the build tree: the copy in OUT would load a second msys-2.0.dll into this MSYS shell.
"$WORK/valkey-$VERSION/src/valkey-server.exe" --version
