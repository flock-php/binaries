#!/usr/bin/env bash
# Mirrors the Node.js archive unchanged. Checked against SHASUMS256.txt, whose signature is
# verified with the Node.js release keys (nodejs/release-keys). Writes node-<version>.json next to
# it: whether the release is LTS, which Flock goes by when it picks the Node.js to install first.
# Usage: packages/node/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  macos-arm64) name="node-v$V-darwin-arm64.tar.gz" ;;
  windows-x64) name="node-v$V-win-x64.zip" ;;
esac
tmp="$(mktemp -d)"
base="https://nodejs.org/dist/v$V"
fetch "$base/SHASUMS256.txt" "$tmp/SHASUMS256.txt"
fetch "$base/SHASUMS256.txt.sig" "$tmp/SHASUMS256.txt.sig"
fetch https://github.com/nodejs/release-keys/raw/HEAD/gpg/pubring.kbx "$tmp/pubring.kbx"
gpgv --keyring "$tmp/pubring.kbx" "$tmp/SHASUMS256.txt.sig" "$tmp/SHASUMS256.txt"
echo "✓ SHASUMS256.txt signed by a Node.js releaser"
fetch "$base/$name" "$OUT"
check_sha256 "$OUT" "$(awk -v n="$name" '$2 == n {print $1}' "$tmp/SHASUMS256.txt")"
node_release_info "$V" "$(dirname "$OUT")/node-$V.json"
