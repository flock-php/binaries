#!/usr/bin/env bash
# Downloads the newest published package of an extension for a PostgreSQL major and platform
# (any build), for testing an extension that requires it (pgRouting needs PostGIS). Prints the
# archive's path.
# Usage: scripts/pg-extension-package.sh <extension>-pg<major> <platform> <dir>   (GH_TOKEN, GH_REPO set)
set -euo pipefail
PKG="${1:?usage: pg-extension-package.sh <package> <platform> <dir>}"
PLATFORM="${2:?}"; DIR="${3:?}"
ext=tar.gz; [[ "$PLATFORM" == windows-* ]] && ext=zip
mkdir -p "$DIR"
for tag in $(gh release list --limit 300 --json tagName --jq '.[].tagName' | grep -E "^$PKG-[0-9]" | sort -t- -k3 -V -r); do
  asset="$(gh release view "$tag" --json assets --jq '.assets[] | select(.state == "uploaded") | .name' \
    | grep -E -- "-build[0-9]+-$PLATFORM\.$ext$" | sort -V | tail -1 || true)"
  if [[ -n "$asset" ]]; then
    gh release download "$tag" -p "$asset" -D "$DIR" --clobber >&2
    echo "$DIR/$asset"
    exit 0
  fi
done
echo "::error::no $PKG package for $PLATFORM is published yet" >&2
exit 1
