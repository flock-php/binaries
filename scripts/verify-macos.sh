#!/usr/bin/env bash
# Checks that every Mach-O file under a directory is portable to other Macs:
#   - it links only against macOS system libraries or libraries shipped next to it
#     (@rpath, @loader_path, @executable_path) — never /opt/homebrew, /usr/local or the build tree
#   - it targets macOS <= MAX_MINOS (default 13.0)
# Usage: scripts/verify-macos.sh <dir> [max-minos]
set -euo pipefail

DIR="${1:?usage: verify-macos.sh <dir> [max-minos]}"
MAX_MINOS="${2:-13.0}"

ver_gt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]; }

failed=0
checked=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  checked=$((checked + 1))

  # otool -L prints the file name first, then one dependency per line.
  while read -r dep _; do
    case "$dep" in
      /usr/lib/* | /System/Library/* | @rpath/* | @loader_path/* | @executable_path/*) ;;
      *) echo "✗ $f links $dep"; failed=1 ;;
    esac
  done < <(otool -L "$f" | tail -n +2)

  minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')"
  if [[ -z "$minos" ]]; then
    minos="$(otool -l "$f" | awk '/LC_VERSION_MIN_MACOSX/{b=1} b&&/version/{print $2; exit}')"
  fi
  if [[ -n "$minos" ]] && ver_gt "$minos" "$MAX_MINOS"; then
    echo "✗ $f requires macOS $minos (max $MAX_MINOS)"
    failed=1
  fi
done < <(find "$DIR" -type f -print0)

if [[ $checked -eq 0 ]]; then
  echo "✗ no Mach-O files found in $DIR"
  exit 1
fi
if [[ $failed -ne 0 ]]; then
  exit 1
fi
echo "✓ $checked Mach-O files are portable (system libs only, macOS ≤ $MAX_MINOS)"
