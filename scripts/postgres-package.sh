#!/usr/bin/env bash
# Downloads and unpacks Flock's postgres package of a major for a platform: the newest version that
# has the build versions.json asks for (from build 2 on it has the headers and PGXS extensions are
# built with). Extensions are built against it and tested with it, the server Flock runs them in.
# Prints the version it took.
# Usage: scripts/postgres-package.sh <major> <platform> <dir>   (GH_TOKEN, GH_REPO set)
set -euo pipefail
MAJOR="${1:?usage: postgres-package.sh <major> <platform> <dir>}"
PLATFORM="${2:?usage: postgres-package.sh <major> <platform> <dir>}"
DIR="${3:?usage: postgres-package.sh <major> <platform> <dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

build="$(jq -r --arg pl "$PLATFORM" '.packages.postgres.platforms[$pl].build' "$ROOT/versions.json")"
ext=tar.gz; [[ "$PLATFORM" == windows-* ]] && ext=zip
# Releases are postgres-<major>.<minor>; the newest minor with that build wins.
asset=""
for tag in $(gh release list --limit 300 --json tagName --jq '.[].tagName' | grep -E "^postgres-$MAJOR\.[0-9]+$" | sort -t. -k2 -n -r); do
  name="$tag-build$build-$PLATFORM.$ext"
  if gh release view "$tag" --json assets --jq '.assets[] | select(.state == "uploaded") | .name' | grep -qx "$name"; then
    asset="$name"; break
  fi
done
[[ -n "$asset" ]] || { echo "::error::no postgres $MAJOR build $build for $PLATFORM is published yet" >&2; exit 1; }

tmp="$(mktemp -d)"
gh release download "${asset%-build*}" -p "$asset" -D "$tmp" >&2
mkdir -p "$DIR"
if [[ "$ext" == zip ]]; then
  (cd "$DIR" && unzip -q "$tmp/$asset")
else
  tar -C "$DIR" -xzf "$tmp/$asset"
fi
rm -rf "$tmp"
version="${asset#postgres-}"
echo "${version%%-build*}"
