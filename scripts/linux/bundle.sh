#!/usr/bin/env bash
# Makes a Linux install relocatable, like scripts/macos/relocate.sh: every shared library an ELF
# file under <dir> needs from outside it, beyond glibc's own, libgcc_s and libstdc++ (which every
# glibc distribution has), is copied to <dir>/lib, with the license files its RPM package lists
# (into <dir>/LICENSES). Every ELF file that needs a library in <dir>/lib then finds it through a
# RUNPATH relative to itself ($ORIGIN); other rpaths, which point into the build, are dropped.
# Needs patchelf. scripts/verify-linux.sh checks the result.
# Usage: scripts/linux/bundle.sh <dir>
set -euo pipefail
DIR="$(cd "${1:?usage: bundle.sh <dir>}" && pwd)"
LIB="$DIR/lib"

system() {
  case "$1" in
    libc.so.* | libm.so.* | libdl.so.* | libpthread.so.* | librt.so.* | libresolv.so.* | libutil.so.* | \
      ld-linux*.so.* | libgcc_s.so.* | libstdc++.so.*) return 0 ;;
  esac
  return 1
}
elf() { [[ ! -L "$1" && "$(head -c 4 "$1" | tr -d '\0')" == $'\x7fELF' ]]; }

# Copied libraries need others in turn: repeat until nothing new is needed.
added=1
while [[ $added -eq 1 ]]; do
  added=0
  while IFS= read -r -d '' f; do
    elf "$f" || continue
    while read -r name path; do
      system "$name" || [[ -e "$LIB/$name" ]] && continue
      [[ "$path" == /* && -f "$path" ]] || { echo "✗ $f needs $name, which isn't installed" >&2; exit 1; }
      mkdir -p "$LIB" "$DIR/LICENSES"
      cp -L "$path" "$LIB/$name" && chmod 755 "$LIB/$name"
      echo "bundled $name from $path"
      if pkg="$(rpm -qf --qf '%{NAME}' "$path" 2>/dev/null)"; then
        licenses="$(rpm -qL "$pkg" | grep '^/' || true)"
        # A library package can leave the license to another one built from the same source
        # (ncurses-libs to ncurses-base).
        if [[ -z "$licenses" ]]; then
          src="$(rpm -q --qf '%{SOURCERPM}' "$pkg")"
          licenses="$(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' | awk -v s="$src" '$2 == s {print $1}' \
            | xargs -r rpm -qL | grep '^/' || true)"
        fi
        [[ -n "$licenses" ]] || echo "::warning::no license file for $name ($pkg)"
        while read -r license; do
          [[ -f "$license" ]] && cp "$license" "$DIR/LICENSES/$pkg-$(basename "$license")"
        done <<<"$licenses"
      fi
      added=1
    done < <(LD_LIBRARY_PATH="$LIB" ldd "$f" 2>/dev/null | awk '$2 == "=>" {print $1, $3}')
  done < <(find "$DIR" -type f -print0)
done

while IFS= read -r -d '' f; do
  elf "$f" || continue
  chmod u+w "$f"
  uses_lib=0
  for name in $(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
    [[ -e "$LIB/$name" ]] && uses_lib=1
  done
  if [[ $uses_lib -eq 1 ]]; then
    rel="$(realpath --relative-to="$(dirname "$f")" "$LIB")"
    if [[ "$rel" == . ]]; then rpath='$ORIGIN'; else rpath="\$ORIGIN/$rel"; fi
    patchelf --set-rpath "$rpath" "$f"
  else
    patchelf --remove-rpath "$f"
  fi
done < <(find "$DIR" -type f -print0)
echo "✓ bundled the libraries of $DIR in lib/ (\$ORIGIN)"
