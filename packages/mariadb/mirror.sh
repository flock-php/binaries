#!/usr/bin/env bash
# Mirrors MariaDB's Windows zip unchanged, checked against the SHA-256 from MariaDB's downloads API.
# (macOS has no upstream binaries: packages/mariadb/macos/build.sh.)
# Usage: packages/mariadb/mirror.sh <version> windows-x64 <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

[[ "$PLATFORM" == windows-x64 ]] || { echo "MariaDB is only mirrored for Windows" >&2; exit 1; }
name="mariadb-$V-winx64.zip"
fetch "https://archive.mariadb.org/mariadb-$V/winx64-packages/$name" "$OUT"
check_sha256 "$OUT" "$(mariadb_sha256 "$V" "$name")"
