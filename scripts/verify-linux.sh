#!/usr/bin/env bash
# Checks that every ELF file under a directory runs on other Linux machines:
#   - it needs only glibc's libraries, the dynamic loader, libgcc_s and libstdc++ (on every glibc
#     distribution), and libraries shipped in the directory itself (scripts/linux/bundle.sh),
#     which it finds there, not on this machine
#   - its RPATH or RUNPATH, if any, is relative to itself ($ORIGIN): never into the build tree
#   - it needs no glibc symbol newer than MAX_GLIBC (default 2.17)
# Usage: scripts/verify-linux.sh <dir> [max-glibc]
set -euo pipefail

DIR="$(cd "${1:?usage: verify-linux.sh <dir> [max-glibc]}" && pwd)"
MAX_GLIBC="${2:-2.17}"

ver_gt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]; }
system() {
  case "$1" in
    libc.so.6 | libm.so.6 | libdl.so.2 | libpthread.so.0 | librt.so.1 | libresolv.so.2 | libutil.so.1 | \
      ld-linux-*.so.* | libgcc_s.so.1 | libstdc++.so.6) return 0 ;;
  esac
  return 1
}

failed=0
checked=0
while IFS= read -r -d '' f; do
  [[ "$(head -c 4 "$f" | tr -d '\0')" == $'\x7fELF' ]] || continue
  checked=$((checked + 1))

  resolved="$(ldd "$f" 2>/dev/null || true)"
  while read -r lib; do
    system "$lib" && continue
    path="$(awk -v n="$lib" '$1 == n && $2 == "=>" {print $3}' <<<"$resolved")"
    [[ "$path" == "$DIR"/* ]] || { echo "✗ $f needs $lib (${path:-not found}), not from the package"; failed=1; }
  done < <(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')

  while read -r entry; do
    [[ "$entry" == '$ORIGIN'* ]] || { echo "✗ $f has the rpath $entry"; failed=1; }
  done < <(readelf -d "$f" | sed -n 's/.*(R\(UN\)\{0,1\}PATH).*\[\(.*\)\]/\2/p' | tr ':' '\n')

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
echo "✓ $checked ELF files are portable (glibc ≤ $MAX_GLIBC, other libraries only from the package)"
