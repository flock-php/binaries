#!/usr/bin/env bash
# Builds a static OpenSSL into <prefix> (Linux, like scripts/macos/openssl.sh), checked against the
# SHA-256 published with the OpenSSL release. Reuses <prefix> when it already holds this build.
# Usage: scripts/linux/openssl.sh <version> <prefix>
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
V="${1:?usage: openssl.sh <version> <prefix>}"; PREFIX="${2:?usage: openssl.sh <version> <prefix>}"

[[ -f "$PREFIX/lib/libssl.a" && -f "$PREFIX/.version-$V-no-dso" ]] && exit 0
case "$(uname -m)" in
  x86_64) target=linux-x86_64 ;;
  aarch64) target=linux-aarch64 ;;
  *) echo "unsupported machine $(uname -m)" >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
url="https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz"
fetch "$url" "$tmp/openssl.tar.gz"
check_sha256 "$tmp/openssl.tar.gz" "$(fetch_text "$url.sha256" | awk '{print $1}')"
mkdir "$tmp/src" && tar -C "$tmp/src" --strip-components 1 -xzf "$tmp/openssl.tar.gz"
rm -rf "$PREFIX"
# -fPIC: it ends up in shared libraries (libpq.so, MariaDB's plugins). no-dso: nothing loads
# OpenSSL modules here, and without it every library linking libcrypto.a would also need -ldl.
(cd "$tmp/src" \
  && ./Configure "$target" no-shared no-dso no-tests no-docs no-apps -fPIC --prefix="$PREFIX" --libdir=lib \
  && make -j"$(nproc)" && make install_sw)
cp "$tmp/src/LICENSE.txt" "$PREFIX/LICENSE.txt"
touch "$PREFIX/.version-$V-no-dso"
rm -rf "$tmp"
