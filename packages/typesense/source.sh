#!/usr/bin/env bash
# Downloads the Typesense source of a release (the v<version> tag; published next to the
# binaries we mirror, for the GPL).
# Usage: packages/typesense/source.sh <version> <file.tar.gz>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <file>}"; OUT="${2:?usage: source.sh <version> <file>}"

fetch "https://github.com/typesense/typesense/archive/refs/tags/v$V.tar.gz" "$OUT"
