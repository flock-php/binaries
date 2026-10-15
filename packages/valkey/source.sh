#!/usr/bin/env bash
# Downloads the Valkey source tarball, checked against the SHA-256 in valkey-io/valkey-hashes.
# Usage: packages/valkey/source.sh <version> <file.tar.gz>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <file>}"; OUT="${2:?usage: source.sh <version> <file>}"

fetch "https://github.com/valkey-io/valkey/archive/refs/tags/$V.tar.gz" "$OUT"
check_sha256 "$OUT" "$(fetch_text https://raw.githubusercontent.com/valkey-io/valkey-hashes/main/README \
  | awk -v f="valkey-$V.tar.gz" '$1 == "hash" && $2 == f && $3 == "sha256" {print $4}')"
