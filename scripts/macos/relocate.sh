#!/usr/bin/env bash
# Makes an install relocatable: every reference a Mach-O file under <dir> has to a library under
# <prefix> (the install prefix the build used) becomes @loader_path-relative, rpaths into
# <prefix> are dropped, and everything is re-signed ad hoc (required on Apple Silicon after
# editing load commands). scripts/verify-macos.sh checks the result.
# Usage: scripts/macos/relocate.sh <dir> <prefix>
set -euo pipefail
DIR="$(cd "${1:?usage: relocate.sh <dir> <prefix>}" && pwd)"; PREFIX="${2:?usage: relocate.sh <dir> <prefix>}"
PREFIX="${PREFIX%/}"

relpath() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"; }

while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  [[ -L "$f" ]] && continue
  chmod u+w "$f"
  here="$(dirname "$f")"
  args=()
  # A dylib's own id: @rpath/<name>, so nothing records the build path.
  id="$(otool -D "$f" | sed -n 2p)"
  if [[ "$id" == "$PREFIX"/* ]]; then args+=(-id "@rpath/$(basename "$id")"); fi
  while read -r dep _; do
    if [[ "$dep" == "$PREFIX"/* ]]; then
      target="$DIR/${dep#"$PREFIX"/}"
      args+=(-change "$dep" "@loader_path/$(relpath "$target" "$here")")
    fi
  done < <(otool -L "$f" | tail -n +2)
  while read -r rp; do
    if [[ "$rp" == "$PREFIX"* ]]; then args+=(-delete_rpath "$rp"); fi
  done < <(otool -l "$f" | awk '/cmd LC_RPATH/{r=1} r&&/ path /{print $2; r=0}')
  if [[ ${#args[@]} -gt 0 ]]; then
    install_name_tool "${args[@]}" "$f" 2>&1 | grep -v 'invalidate the code signature' || true
  fi
  codesign --force --sign - "$f"
done < <(find "$DIR" -type f -print0)
echo "✓ relocated $DIR (was $PREFIX)"
