#!/usr/bin/env bash
# Mirrors cloudflared, the client of Cloudflare's tunnels (`flock share`), checked against GitHub's
# SHA-256 of the release asset. The executables keep Cloudflare's own signatures; they're repacked
# with the Apache-2.0 license.
# Usage: packages/cloudflared/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  macos-arm64) asset="cloudflared-darwin-arm64.tgz" ;;
  windows-x64) asset="cloudflared-windows-amd64.exe" ;;
esac
tmp="$(mktemp -d)"; dir="$tmp/pkg"; mkdir "$dir"
fetch "https://github.com/cloudflare/cloudflared/releases/download/$V/$asset" "$tmp/$asset"
check_sha256 "$tmp/$asset" "$(github_digest cloudflare/cloudflared "$V" "$asset")"
case "$asset" in
  *.tgz) tar -xzf "$tmp/$asset" -C "$dir" ;;
  *.exe) cp "$tmp/$asset" "$dir/cloudflared.exe" ;;
esac
fetch "https://raw.githubusercontent.com/cloudflare/cloudflared/$V/LICENSE" "$dir/LICENSE"
pack "$dir" "$OUT"
