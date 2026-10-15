#!/usr/bin/env bash
# Downloads the PostgreSQL source tarball, checked against postgresql.org's SHA-256.
# Usage: packages/postgres/source.sh <version> <file.tar.bz2>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <file>}"; OUT="${2:?usage: source.sh <version> <file>}"

url="https://ftp.postgresql.org/pub/source/v$V/postgresql-$V.tar.bz2"
fetch "$url" "$OUT"
check_sha256 "$OUT" "$(fetch_text "$url.sha256" | cut -d' ' -f1)"
