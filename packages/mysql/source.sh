#!/usr/bin/env bash
# Downloads the MySQL source tarball (published next to the binaries we mirror, for the GPL).
# Checked against Oracle's MD5 while the release is on the CDN; archived releases have none.
# Usage: packages/mysql/source.sh <version> <file.tar.gz>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <file>}"; OUT="${2:?usage: source.sh <version> <file>}"

mysql_fetch "$V" "mysql-$V.tar.gz" "$OUT"
