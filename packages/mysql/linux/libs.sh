#!/usr/bin/env bash
# Builds the two libraries Oracle's Linux MySQL needs from the system but not every distribution
# has under that name: libaio.so.1 (Ubuntu 24.04+ ships it as libaio.so.1t64) and libnuma.so.1.
# They go into MySQL's lib/private, which its programs search first ($ORIGIN/../lib/private). Both
# are LGPL-2.1: their licenses and source tarballs go into <licenses-dir>.
# Usage: packages/mysql/linux/libs.sh <lib-dir> <licenses-dir>
#   LIBAIO_VERSION, LIBAIO_SHA256    Debian's libaio source (upstream publishes no checksums)
#   NUMACTL_VERSION, NUMACTL_SHA256  numactl's release tarball (its release predates GitHub's
#                                    asset digests; the pinned SHA-256 matches Fedora's SHA-512)
set -euo pipefail
. "$(dirname "$0")/../../../scripts/lib.sh"
LIB="${1:?usage: libs.sh <lib-dir> <licenses-dir>}"; LICENSES="${2:?usage: libs.sh <lib-dir> <licenses-dir>}"
: "${LIBAIO_VERSION:?}" "${LIBAIO_SHA256:?}" "${NUMACTL_VERSION:?}" "${NUMACTL_SHA256:?}"
mkdir -p "$LIB" "$LICENSES"
tmp="$(mktemp -d)"

aio="libaio-$LIBAIO_VERSION.tar.gz"
fetch "https://deb.debian.org/debian/pool/main/liba/libaio/libaio_$LIBAIO_VERSION.orig.tar.gz" "$tmp/$aio"
check_sha256 "$tmp/$aio" "$LIBAIO_SHA256"
mkdir "$tmp/aio" && tar -C "$tmp/aio" --strip-components 1 -xzf "$tmp/$aio"
make -C "$tmp/aio/src" -j"$(nproc)" >/dev/null
cp "$tmp"/aio/src/libaio.so.1.* "$LIB/libaio.so.1"
cp "$tmp/aio/COPYING" "$LICENSES/libaio.txt"
cp "$tmp/$aio" "$LICENSES/"

numa="numactl-$NUMACTL_VERSION.tar.gz"
fetch "https://github.com/numactl/numactl/releases/download/v$NUMACTL_VERSION/$numa" "$tmp/$numa"
check_sha256 "$tmp/$numa" "$NUMACTL_SHA256"
mkdir "$tmp/numa" && tar -C "$tmp/numa" --strip-components 1 -xzf "$tmp/$numa"
(cd "$tmp/numa" && ./configure --quiet --disable-static >/dev/null && make -j"$(nproc)" libnuma.la >/dev/null)
cp "$tmp"/numa/.libs/libnuma.so.1.* "$LIB/libnuma.so.1"
cp "$tmp/numa/LICENSE.LGPL2.1" "$LICENSES/libnuma.txt"
cp "$tmp/$numa" "$LICENSES/"

strip --strip-unneeded "$LIB/libaio.so.1" "$LIB/libnuma.so.1"
rm -rf "$tmp"
echo "✓ bundled libaio $LIBAIO_VERSION and libnuma $NUMACTL_VERSION"
