#!/usr/bin/env bash
# Smoke-tests a macOS PHP or FrankenPHP package directory against php.macos in versions.json:
# every compiled-in extension loaded, every shared extension in ext/ built and loading.
# Usage: scripts/smoke-php-package.sh <php|frankenphp> <dir>
set -euo pipefail
PKG="${1:?usage: smoke-php-package.sh <php|frankenphp> <dir>}"
DIR="${2:?usage: smoke-php-package.sh <php|frankenphp> <dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# From the environment where set: on a runner with Homebrew hidden there is no jq.
STATIC="${STATIC_EXTS:-$(jq -r '.php.macos.static_extensions' "$ROOT/versions.json")}"
SHARED="${SHARED_EXTS:-$(jq -r '.php.macos.shared_extensions' "$ROOT/versions.json")}"
[[ -n "$STATIC" && "$STATIC" != null ]] || { echo "✗ no extension list from versions.json" >&2; exit 1; }

case "$PKG" in
  php) REQUIRE_SHARED=1 exec bash "$ROOT/scripts/smoke-php.sh" "$DIR" "$STATIC" "$SHARED" ;;
  frankenphp)
    # The embedded PHP must be the minor of $VERSION (set by the workflow); without it, whatever
    # the binary's version line says ("FrankenPHP 1.13.0 PHP 8.4.26 Caddy ...").
    if [[ -n "${VERSION:-}" ]]; then
      minor="$(cut -d. -f1-2 <<<"$VERSION")"
    else
      minor="$("$DIR/bin/frankenphp" version | sed -n 's/.* PHP \([0-9]*\.[0-9]*\)\..*/\1/p' | head -1)"
    fi
    for ext in ${SHARED//,/ }; do
      [[ -f "$DIR/ext/$ext.so" ]] || { echo "✗ $ext.so was not built"; exit 1; }
    done
    exec bash "$ROOT/scripts/smoke-frankenphp.sh" "$DIR" "$minor" "$STATIC" ;;
  *) echo "unknown package $PKG" >&2; exit 1 ;;
esac
