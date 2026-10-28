#!/usr/bin/env bash
# Builds pgvector for macOS or Linux with PGXS against Flock's postgres package of one major, into
# the layout Flock links: lib/vector.<so|dylib>, extension/vector*.{control,sql}.
# No -march=native (OPTFLAGS=""): the package runs on other CPUs than the build machine's.
# Usage: packages/pgvector/build.sh <version> <postgres-dir> <out-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../scripts/lib.sh"
V="${1:?usage: build.sh <version> <postgres-dir> <out-dir>}"
PG="$(cd "${2:?usage: build.sh <version> <postgres-dir> <out-dir>}" && pwd -P)"
OUT="$(mkdir -p "${3:?usage: build.sh <version> <postgres-dir> <out-dir>}" && cd "$3" && pwd)"
WORK="${WORK_DIR:-$PWD/pgvector-work}"
PG_CONFIG="$PG/bin/pg_config"
mkdir -p "$WORK" && cd "$WORK"

echo "pgvector $V: commit $(bash "$HERE/source.sh" "$V" src)"

make=(make -C src PG_CONFIG="$PG_CONFIG" OPTFLAGS="")
# macOS: modules link against the server (-bundle_loader); name it outright.
[[ "$(uname -s)" == Darwin ]] && make+=(BE_DLLLIBS="-bundle_loader $PG/bin/postgres")
"${make[@]}" -j"$(getconf _NPROCESSORS_ONLN)"
"${make[@]}" install pkglibdir="$OUT/lib" datadir="$OUT"
rm -rf "$OUT/include" # vector.h, for building against pgvector

mkdir -p "$OUT/LICENSES"
cp src/LICENSE "$OUT/LICENSES/pgvector.txt"
ls -R "$OUT"
