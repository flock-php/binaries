#!/usr/bin/env bash
# Downloads the Redis source tarball, checked against the SHA-256 in redis/redis-hashes.
# Usage: packages/redis/source.sh <version> <file.tar.gz>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <file>}"; OUT="${2:?usage: source.sh <version> <file>}"

fetch "https://download.redis.io/releases/redis-$V.tar.gz" "$OUT"
check_sha256 "$OUT" "$(fetch_text https://raw.githubusercontent.com/redis/redis-hashes/master/README \
  | awk -v f="redis-$V.tar.gz" '$1 == "hash" && $2 == f && $3 == "sha256" {print $4}')"
