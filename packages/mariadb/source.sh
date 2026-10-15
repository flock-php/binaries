#!/usr/bin/env bash
# Downloads the MariaDB source tarball, checked against the SHA-256 from MariaDB's downloads API.
# Usage: packages/mariadb/source.sh <version> <file.tar.gz>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <file>}"; OUT="${2:?usage: source.sh <version> <file>}"

name="mariadb-$V.tar.gz"
fetch "https://archive.mariadb.org/mariadb-$V/source/$name" "$OUT"
check_sha256 "$OUT" "$(mariadb_sha256 "$V" "$name")"
