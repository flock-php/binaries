#!/usr/bin/env bash
# Mirrors Oracle's MySQL Community Server archive unchanged on macOS (tar.gz) and Windows (zip).
# On Linux Oracle's generic build (glibc 2.28+, .tar.xz) is checked, then made fit for a desktop:
# without the debug server, debug symbols and test suite (1 GB → ~100 MB), and with libaio and
# libnuma bundled in lib/private (packages/mysql/linux/libs.sh), repacked as .tar.gz.
# Usage: packages/mysql/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  # Oracle names macOS builds after the oldest macOS they support, which moves over time.
  macos-arm64) names=("mysql-$V-macos15-arm64.tar.gz" "mysql-$V-macos14-arm64.tar.gz" "mysql-$V-macos26-arm64.tar.gz") ;;
  windows-x64) names=("mysql-$V-winx64.zip") ;;
  linux-x64) names=("mysql-$V-linux-glibc2.28-x86_64.tar.xz") ;;
  linux-arm64) names=("mysql-$V-linux-glibc2.28-aarch64.tar.xz") ;;
esac
if [[ "$PLATFORM" != linux-* ]]; then
  for name in "${names[@]}"; do
    mysql_fetch "$V" "$name" "$OUT" && exit 0
  done
  exit 1
fi

tmp="$(mktemp -d)"
mysql_fetch "$V" "${names[0]}" "$tmp/mysql.tar.xz"
mkdir "$tmp/pkg" && tar -C "$tmp/pkg" -xJf "$tmp/mysql.tar.xz"
D="$(echo "$tmp"/pkg/*)"
rm -rf "$D/bin/mysqld-debug" "$D/lib/plugin/debug" "$D/mysql-test" "$D/docs" "$D/man" "$D/include"
find "$D" -name '*.a' -delete
find "$D/bin" "$D/lib" -type f -exec sh -c 'file -b "$1" | grep -q ^ELF && strip --strip-debug "$1"' _ {} \;
bash "$(dirname "$0")/linux/libs.sh" "$D/lib/private" "$D/LICENSES"
pack "$tmp/pkg" "$OUT"
rm -rf "$tmp"
