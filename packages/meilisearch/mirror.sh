#!/usr/bin/env bash
# Mirrors the Meilisearch Community Edition binary (MIT), checked against GitHub's SHA-256 of the
# release asset. Upstream ships a bare executable, so it's packed with its license.
# Never the meilisearch-enterprise-* assets: those are BUSL, not for production use.
# Usage: packages/meilisearch/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  macos-arm64) asset=meilisearch-macos-apple-silicon; bin=meilisearch ;;
  windows-x64) asset=meilisearch-windows-amd64.exe; bin=meilisearch.exe ;;
  linux-x64)   asset=meilisearch-linux-amd64; bin=meilisearch ;;
  linux-arm64) asset=meilisearch-linux-aarch64; bin=meilisearch ;;
esac
dir="$(mktemp -d)"
fetch "https://github.com/meilisearch/meilisearch/releases/download/v$V/$asset" "$dir/$bin"
check_sha256 "$dir/$bin" "$(github_digest meilisearch/meilisearch "v$V" "$asset")"
chmod 755 "$dir/$bin"
fetch "https://raw.githubusercontent.com/meilisearch/meilisearch/v$V/LICENSE-MIT" "$dir/LICENSE"
pack "$dir" "$OUT"
