#!/usr/bin/env bash
# Uploads a package to its release <package>-<version>, creating the release if needed. For
# packages with publish_source in versions.json (GPL, SSPL, AGPL), the upstream source tarball
# is uploaded first as <package>-<version>-source.<ext>, once per release.
# A published asset is never replaced: uploading one that exists fails.
# Usage: scripts/publish.sh <package> <version> <asset-file>     (GH_TOKEN, GH_REPO set)
set -euo pipefail
PKG="$1"; V="$2"; ASSET="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="$PKG-$V"

title() {
  case "$PKG" in
    postgres) echo PostgreSQL ;; mariadb) echo MariaDB ;; mysql) echo MySQL ;; mongodb) echo MongoDB ;;
    redis) echo Redis ;; valkey) echo Valkey ;; meilisearch) echo Meilisearch ;; typesense) echo Typesense ;;
    rustfs) echo RustFS ;; node) echo Node.js ;; *) echo "$PKG" ;;
  esac
}

if ! gh release view "$TAG" >/dev/null 2>&1; then
  # Two platforms can publish at once: losing the race to create the release is fine.
  gh release create "$TAG" --title "$(title) $V" --latest=false \
    --notes "$(title) $V for Flock. Packages are listed in the signed manifest." \
    || gh release view "$TAG" >/dev/null
fi

assets="$(gh release view "$TAG" --json assets --jq '.assets[].name')"
if [[ "$(jq -r --arg p "$PKG" '.packages[$p].publish_source // false' "$ROOT/versions.json")" == true ]]; then
  ext=tar.gz; [[ "$PKG" == postgres ]] && ext=tar.bz2
  src="$PKG-$V-source.$ext"
  if ! grep -qx "$src" <<<"$assets"; then
    tmp="$(mktemp -d)"
    bash "$ROOT/packages/$PKG/source.sh" "$V" "$tmp/$src"
    gh release upload "$TAG" "$tmp/$src" || gh release view "$TAG" --json assets --jq '.assets[].name' | grep -qx "$src"
  fi
fi

# No --clobber: a published asset is never replaced.
gh release upload "$TAG" "$ASSET"
echo "published $(basename "$ASSET") on $TAG"
