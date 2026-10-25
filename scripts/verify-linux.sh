#!/usr/bin/env bash
# Checks that a Linux build runs on the distributions Flock supports, not just where it was built:
# every ELF file links only libraries a desktop Linux always has (glibc, libstdc++, libgcc, zlib, libuuid, ncurses)
# or that the package bundles itself, and needs no newer glibc than the build machine's (the
# oldest Ubuntu LTS Flock supports). Prints one line per problem; fails if there is any.
# Usage: scripts/verify-linux.sh <dir>
#   LINUX_SYSTEM_LIBS  more system libraries a mirrored package may link (versions.json: MongoDB's
#                      OpenSSL and libcurl); Flock's Linux packages depend on them
set -uo pipefail
DIR="${1:?usage: verify-linux.sh <dir>}"
system='^(libc|libm|libpthread|libdl|librt|libutil|libresolv|libcrypt|libgcc_s|libstdc\+\+|libz|libuuid|libtinfo|libncurses|libncursesw|ld-linux-x86-64|ld-linux-aarch64)\.so'
max_glibc="$(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$')"
bundled="$(find "$DIR" -name '*.so*' -printf '%f\n' | sort -u)"
problems=0 checked=0

while IFS= read -r -d '' f; do
  file -b "$f" | grep -q '^ELF' || continue
  checked=$((checked + 1))
  while read -r lib; do
    [[ "$lib" =~ $system ]] && continue
    grep -qxF "$lib" <<<"$bundled" && continue
    [[ " ${LINUX_SYSTEM_LIBS:-} " == *" $lib "* ]] && continue
    echo "✗ ${f#"$DIR"/} links $lib, which isn't part of the package"; problems=$((problems + 1))
  done < <(readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
  while read -r path; do
    [[ "$path" == '$ORIGIN'* ]] && continue
    echo "✗ ${f#"$DIR"/} looks for libraries in $path, outside the package"; problems=$((problems + 1))
  done < <(readelf -d "$f" 2>/dev/null | sed -n 's/.*(R\(UN\)\{0,1\}PATH).*\[\(.*\)\]/\2/p' | tr ':' '\n')
  newest="$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -V | tail -1)"
  if [[ -n "$newest" && "$(printf '%s\n%s\n' "$newest" "$max_glibc" | sort -V | tail -1)" != "$max_glibc" ]]; then
    echo "✗ ${f#"$DIR"/} needs glibc $newest, newer than $max_glibc"; problems=$((problems + 1))
  fi
done < <(find "$DIR" -type f -print0)

echo "checked $checked ELF files, glibc ≤ $max_glibc"
[[ $problems -eq 0 ]] && echo "✓ only system libraries and the package's own"
exit $((problems > 0))
