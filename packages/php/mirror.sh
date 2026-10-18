#!/usr/bin/env bash
# Mirrors the official thread-safe x64 build of PHP for Windows from windows.php.net unchanged,
# checked against the SHA-256 in releases.json. That file lists the current build of every minor
# (7.4 and up); once superseded, a build moves to archives/ and its checksum is no longer
# published, so the daily run mirrors each build while it is current.
# Usage: packages/php/mirror.sh <version> windows-x64 <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

[[ "$PLATFORM" == windows-x64 ]] || { echo "PHP is only mirrored for Windows (macOS: build-php-macos.yml)" >&2; exit 1; }
base=https://downloads.php.net/~windows/releases
# Release candidates (8.6.0RC3) are in qa/, which has a releases.json of its own.
[[ "$V" =~ RC[0-9]+$ ]] && base=https://downloads.php.net/~windows/qa
minor="$(cut -d. -f1-2 <<<"$V")"
read -r version zip sum < <(fetch_text "$base/releases.json" | jq -r --arg m "$minor" '
  .[$m] as $r | ($r | keys[] | select(test("^ts-v[sc][0-9]+-x64$"))) as $k
  | "\($r.version) \($r[$k].zip.path) \($r[$k].zip.sha256)"')
[[ "$version" == "$V" ]] || { echo "::error::windows.php.net's current PHP $minor is $version, not $V; its checksum is gone" >&2; exit 1; }
fetch "$base/$zip" "$OUT"
check_sha256 "$OUT" "${sum,,}"
