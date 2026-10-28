#!/usr/bin/env bash
# Downloads and unpacks the pgRouting source, checked against the SHA-256 GitHub recorded for the
# release asset. The folder is what the build uses and what is published as its source (GPL-2.0).
# Usage: packages/pgrouting/source.sh <version> <dir>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <dir>}"; DIR="${2:?usage: source.sh <version> <dir>}"
rm -rf "$DIR" && mkdir -p "$DIR"
f="pgrouting-$V.tar.gz"
tmp="$(mktemp -d)"
fetch "https://github.com/pgRouting/pgrouting/releases/download/v$V/$f" "$tmp/$f"
check_sha256 "$tmp/$f" "$(github_digest pgRouting/pgrouting "v$V" "$f")"
tar -C "$DIR" --strip-components 1 -xzf "$tmp/$f"
rm -rf "$tmp"
