#!/usr/bin/env bash
# Mirrors Oracle's MySQL Community Server archive unchanged (macOS tar.gz, Windows zip).
# Usage: packages/mysql/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  # Oracle names macOS builds after the oldest macOS they support, which moves over time.
  macos-arm64) names=("mysql-$V-macos15-arm64.tar.gz" "mysql-$V-macos14-arm64.tar.gz" "mysql-$V-macos26-arm64.tar.gz") ;;
  windows-x64) names=("mysql-$V-winx64.zip") ;;
esac
for name in "${names[@]}"; do
  mysql_fetch "$V" "$name" "$OUT" && exit 0
done
exit 1
