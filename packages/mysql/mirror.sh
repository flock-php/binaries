#!/usr/bin/env bash
# Mirrors Oracle's MySQL Community Server archive unchanged (macOS tar.gz, Windows zip).
#
# Linux: Oracle's generic glibc build, repacked as tar.gz with what it needs from the system added
# to lib/private, where its binaries look first ($ORIGIN/../lib/private): libaio and libnuma
# (mysqld) and ncurses (the client), taken from AlmaLinux 8, the glibc 2.28 system Oracle builds
# against (its packages are signature-checked by dnf). libaio is the reason: Ubuntu 24.04 renamed
# its library, so mysqld can't start there otherwise. libaio and numactl are LGPL: their source
# packages go to <out-dir>/sources/, published next to the archive. On arm64 Oracle publishes no
# minimal build, so the debug server and plugins are dropped and debug info stripped, which is
# what the minimal x86-64 build is. Needs Docker, on a machine of the platform's architecture.
# Usage: packages/mysql/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  # Oracle names macOS builds after the oldest macOS they support, which moves over time.
  macos-arm64) names=("mysql-$V-macos15-arm64.tar.gz" "mysql-$V-macos14-arm64.tar.gz" "mysql-$V-macos26-arm64.tar.gz") ;;
  windows-x64) names=("mysql-$V-winx64.zip") ;;
  # 8.0 is built against glibc 2.17, later lines against 2.28.
  linux-x64)   names=("mysql-$V-linux-glibc2.28-x86_64-minimal.tar.xz" "mysql-$V-linux-glibc2.17-x86_64-minimal.tar.xz") ;;
  linux-arm64) names=("mysql-$V-linux-glibc2.28-aarch64.tar.xz") ;;
esac

if [[ "$PLATFORM" != linux-* ]]; then
  for name in "${names[@]}"; do
    mysql_fetch "$V" "$name" "$OUT" && exit 0
  done
  exit 1
fi

tmp="$(mktemp -d)"
for name in "${names[@]}"; do
  mysql_fetch "$V" "$name" "$tmp/$name" && break
  rm -f "$tmp/$name"
done
[[ -f "$tmp/$name" ]] || exit 1
tar -C "$tmp" -xJf "$tmp/$name"
dir="$tmp/${name%.tar.xz}"
[[ -d "$dir/lib/private" ]] || { echo "::error::$name has no lib/private" >&2; exit 1; }

if [[ "$PLATFORM" == linux-arm64 ]]; then
  rm -f "$dir/bin/mysqld-debug"
  rm -rf "$dir/lib/plugin/debug"
  while IFS= read -r -d '' f; do
    [[ "$(head -c 4 "$f" | tr -d '\0')" == $'\x7fELF' ]] && strip --strip-debug "$f"
  done < <(find "$dir/bin" "$dir/lib" -type f -print0)
  echo "✓ dropped the debug server and plugins, stripped debug info"
fi

# The libraries the binaries need of these: ncurses 6, or 5 for the glibc 2.17 build of 8.0.
libs="$(find "$dir/bin" "$dir/lib" -type f -exec sh -c 'readelf -d "$1" 2>/dev/null' _ {} \; \
  | sed -n 's/.*(NEEDED).*\[\(libaio\|libnuma\|libncurses\|libtinfo\)\(\.so\.[0-9]*\)\]/\1\2/p' | sort -u | tr '\n' ' ')"
echo "adding $libs"
sources="$(dirname "$OUT")/sources"
mkdir -p "$sources"
docker run --rm -e libs="$libs" -v "$dir/lib/private:/out" -v "$sources:/sources" almalinux:8 bash -euc '
  # tsflags: the image skips documentation, where libaio keeps its license. ncurses-libs has none:
  # ncurses-base, built from the same source, does. numactl ships none at all (below).
  dnf install -y -q --setopt=tsflags= libaio numactl-libs ncurses-libs ncurses-compat-libs >/dev/null
  for lib in $libs; do cp -L "/usr/lib64/$lib" /out/; done
  rpm -q --qf "%{SOURCERPM}\n" libaio numactl-libs >/sources/srpms.txt
  rpm -q --qf "%{VERSION}" numactl-libs >/sources/numactl-version
  mkdir -p /out/LICENSES
  for pkg in libaio ncurses-base; do
    for f in $(rpm -qL "$pkg"; rpm -qd "$pkg" | grep -Ei "/(copying|license)[^/]*$"); do
      [[ -f "$f" ]] && cp "$f" "/out/LICENSES/$pkg-$(basename "$f")"
    done
  done
  chown -R "$(stat -c %u:%g /out)" /out /sources'
while read -r srpm; do
  fetch "https://vault.almalinux.org/8.10/BaseOS/Source/Packages/$srpm" "$sources/$srpm"
  echo "✓ $srpm"
done <"$sources/srpms.txt"
rm "$sources/srpms.txt"
fetch "https://raw.githubusercontent.com/numactl/numactl/v$(cat "$sources/numactl-version")/LICENSE.LGPL2.1" \
  "$dir/lib/private/LICENSES/numactl-LICENSE.LGPL2.1"
rm "$sources/numactl-version"
echo "✓ added libaio, libnuma and ncurses from AlmaLinux 8 to lib/private"

tar -C "$tmp" -czf "$OUT" "$(basename "$dir")"
rm -rf "$tmp"
