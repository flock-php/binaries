#!/usr/bin/env bash
# Downloads the MongoDB source of a release (the r<version> tag; published next to the binaries
# we mirror, for the SSPL).
# Usage: packages/mongodb/source.sh <version> <file.tar.gz>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <file>}"; OUT="${2:?usage: source.sh <version> <file>}"

fetch "https://github.com/mongodb/mongo/archive/refs/tags/r$V.tar.gz" "$OUT"
