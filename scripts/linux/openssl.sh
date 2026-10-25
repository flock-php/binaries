#!/usr/bin/env bash
# Builds a static, position-independent OpenSSL into <prefix> (shared libraries such as libpq link
# it in), checked against the SHA-256 published with the OpenSSL release. Distributions ship
# different OpenSSL versions and configurations, so packages don't rely on theirs. Reuses <prefix>
# when it already holds this build.
# Usage: scripts/linux/openssl.sh <version> <prefix>
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
V="${1:?usage: openssl.sh <version> <prefix>}"; PREFIX="${2:?usage: openssl.sh <version> <prefix>}"

[[ -f "$PREFIX/lib/libssl.a" && -f "$PREFIX/.version-$V" ]] && exit 0
case "$(uname -m)" in
  x86_64) target=linux-x86_64 ;;
  aarch64) target=linux-aarch64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
url="https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz"
fetch "$url" "$tmp/openssl.tar.gz"
check_sha256 "$tmp/openssl.tar.gz" "$(fetch_text "$url.sha256" | awk '{print $1}')"
mkdir "$tmp/src" && tar -C "$tmp/src" --strip-components 1 -xzf "$tmp/openssl.tar.gz"
rm -rf "$PREFIX"
# The system's certificates, wherever the distribution keeps them: Debian's and Fedora's
# directories both resolve through /etc/ssl (Fedora links it to /etc/pki/tls).
(cd "$tmp/src" \
  && ./Configure "$target" no-shared no-tests no-docs no-apps -fPIC --prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl \
  && make -j"$(nproc)" && make install_sw)
cp "$tmp/src/LICENSE.txt" "$PREFIX/LICENSE.txt"
touch "$PREFIX/.version-$V"
rm -rf "$tmp"
