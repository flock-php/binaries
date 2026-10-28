#!/usr/bin/env bash
# Downloads Timescale's own Windows build of TimescaleDB for one PostgreSQL major, checked against
# the SHA-256 GitHub recorded for the release asset, and unpacks it. It is repackaged unmodified
# (windows/build.ps1): the Timescale License allows distributing its binaries in standalone form.
# Usage: packages/timescaledb/windows/fetch.sh <version> <major> <dir>
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
V="${1:?usage: fetch.sh <version> <major> <dir>}"; MAJOR="${2:?}"; DIR="${3:?}"
name="timescaledb-postgresql-$MAJOR-windows-amd64.zip"
rm -rf "$DIR" && mkdir -p "$DIR"
fetch "https://github.com/timescale/timescaledb/releases/download/$V/$name" "$DIR/$name"
check_sha256 "$DIR/$name" "$(github_digest timescale/timescaledb "$V" "$name")"
(cd "$DIR" && unzip -q "$name" && rm "$name")
