#!/usr/bin/env bash
# Checks that every ELF file under a directory runs on other Linux machines:
#   - it needs only glibc's libraries, the dynamic loader, libgcc_s and libstdc++ (on every glibc
#     distribution); everything else is compiled in
#   - it needs no glibc symbol newer than MAX_GLIBC (default 2.17)
#   - it has no RPATH or RUNPATH (which would point into the build tree)
# Usage: scripts/verify-linux.sh <dir> [max-glibc]
set -euo pipefail

DIR="${1:?usage: verify-linux.sh <dir> [max-glibc]}"
MAX_GLIBC="${2:-2.17}"

ver_gt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]; }

failed=0
checked=0
while IFS= read -r -d '' f; do
  [[ "$(head -c 4 "$f" | tr -d '\0')" == $'\x7fELF' ]] || continue
  checked=$((checked + 1))

  while read -r lib; do
    case "$lib" in
      libc.so.6 | libm.so.6 | libdl.so.2 | libpthread.so.0 | librt.so.1 | libresolv.so.2 | libutil.so.1 | \
        ld-linux-*.so.* | libgcc_s.so.1 | libstdc++.so.6) ;;
      *) echo "✗ $f needs $lib"; failed=1 ;;
    esac
  done < <(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')

  if rpath="$(readelf -d "$f" | grep -E '\((RPATH|RUNPATH)\)')"; then
    echo "✗ $f has $rpath"; failed=1
  fi

  newest="$(readelf -V --wide "$f" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1 || true)"
  if [[ -n "$newest" ]] && ver_gt "$newest" "$MAX_GLIBC"; then
    echo "✗ $f needs glibc $newest (max $MAX_GLIBC)"
    failed=1
  fi
done < <(find "$DIR" -type f -print0)

if [[ $checked -eq 0 ]]; then
  echo "✗ no ELF files found in $DIR"
  exit 1
fi
if [[ $failed -ne 0 ]]; then
  exit 1
fi
echo "✓ $checked ELF files are portable (glibc ≤ $MAX_GLIBC, no other shared libraries)"
