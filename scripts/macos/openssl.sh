#!/usr/bin/env bash
# Builds a static OpenSSL (the macOS SDK has none) into <prefix>, checked against the SHA-256
# published with the OpenSSL release. Reuses <prefix> when it already holds this build.
# Usage: scripts/macos/openssl.sh <version> <prefix>
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
V="${1:?usage: openssl.sh <version> <prefix>}"; PREFIX="${2:?usage: openssl.sh <version> <prefix>}"

[[ -f "$PREFIX/lib/libssl.a" && -f "$PREFIX/.version-$V" ]] && exit 0
tmp="$(mktemp -d)"
url="https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz"
fetch "$url" "$tmp/openssl.tar.gz"
check_sha256 "$tmp/openssl.tar.gz" "$(fetch_text "$url.sha256" | awk '{print $1}')"
mkdir "$tmp/src" && tar -C "$tmp/src" --strip-components 1 -xzf "$tmp/openssl.tar.gz"
rm -rf "$PREFIX"
(cd "$tmp/src" \
  && ./Configure darwin64-arm64-cc no-shared no-tests no-docs no-apps --prefix="$PREFIX" --libdir=lib \
  && make -j"$(sysctl -n hw.ncpu)" && make install_sw)
cp "$tmp/src/LICENSE.txt" "$PREFIX/LICENSE.txt"
touch "$PREFIX/.version-$V"
rm -rf "$tmp"
