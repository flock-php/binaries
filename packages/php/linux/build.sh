#!/usr/bin/env bash
# Builds PHP for Linux with static-php-cli in its glibc container (bin/spc-gnu-docker: CentOS 7,
# glibc 2.17): either php + php-fpm (NTS) or FrankenPHP (ZTS, PHP embedded), each with the
# compiled-in extensions plus shared extensions as .so. The binaries link only against glibc
# (everything else is compiled in), so they run on glibc distributions from 2014 on, but not on
# musl ones (Alpine). Unlike a fully static musl build, PHP can load the shared extensions.
#
# Usage: packages/php/linux/build.sh <major.minor[.patch]> <out-dir>
#   major.minor builds the newest patch release; major.minor.patch exactly that release.
#   SPC_VERSION     static-php-cli release to use (required)
#   STATIC_EXTS     comma-separated extensions compiled in (required)
#   SHARED_EXTS     comma-separated extensions built as .so (optional)
#   TARGET          php (default: bin/php, bin/php-fpm) or frankenphp (bin/frankenphp, PHP >= 8.2)
#   FRANKENPHP_VERSION  FrankenPHP release for TARGET=frankenphp, e.g. 1.13.0 (default: newest)
#   DOWNLOAD_ARGS   extra arguments for `spc download`, e.g. --custom-url=xdebug:https://… (optional)
#   WORK_DIR        static-php-cli source checkout, the container's workspace (default: ./spc-src)
#   GITHUB_TOKEN    lets static-php-cli query GitHub without the anonymous rate limit
#
# Needs Docker and patchelf. Produces <out-dir>/bin/…, <out-dir>/ext/*.so and <out-dir>/LICENSES/. A shared extension that fails to build is reported, not fatal: PHP is still
# usable without it.
set -euo pipefail

PHP_VERSION="${1:?usage: build.sh <major.minor[.patch]> <out-dir>}"
PHP_MINOR="$(cut -d. -f1-2 <<<"$PHP_VERSION")"
OUT="$(mkdir -p "${2:?usage: build.sh <major.minor[.patch]> <out-dir>}" && cd "$2" && pwd)"
: "${SPC_VERSION:?SPC_VERSION is required}"
: "${STATIC_EXTS:?STATIC_EXTS is required}"
SHARED_EXTS="${SHARED_EXTS:-}"
TARGET="${TARGET:-php}"

case "$TARGET" in
  php)        build_flags=(--build-cli --build-fpm); binaries=(php php-fpm) ;;
  frankenphp) build_flags=(--enable-zts --build-frankenphp); binaries=(frankenphp) ;;
  *)          echo "unknown TARGET $TARGET" >&2; exit 1 ;;
esac

# The same Xdebug and opentelemetry releases as packages/php/macos/build.sh (see the reasons there).
xdebug=3.5.3
[[ "$PHP_MINOR" == 8.6 ]] && xdebug=3.6.0alpha1
DOWNLOAD_ARGS="${DOWNLOAD_ARGS:-} --custom-url=xdebug:https://xdebug.org/files/xdebug-$xdebug.tgz"
DOWNLOAD_ARGS="$DOWNLOAD_ARGS --custom-url=opentelemetry:https://pecl.php.net/get/opentelemetry-1.4.2.tgz"
# OpenLDAP 2.7 puts declarations right after labels, which the container's GCC 10 rejects (C23
# allows it, GCC 11 accepts it); static-php-cli takes the newest release, so pin the 2.6 line.
DOWNLOAD_ARGS="$DOWNLOAD_ARGS --custom-url=ldap:https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-2.6.15.tgz"

echo "::group::static-php-cli $SPC_VERSION (glibc container)"
# The container script and the image it builds come with the source, not the spc binary.
mkdir -p "${WORK_DIR:=$PWD/spc-src}"
cd "$WORK_DIR"
if [[ ! -x bin/spc-gnu-docker ]]; then
  curl -fsSL "https://github.com/crazywhalecc/static-php-cli/archive/refs/tags/$SPC_VERSION.tar.gz" | tar xz --strip-components 1
fi
# Downloads run on the host, with the spc binary: CentOS 7's curl can't reach servers that only
# speak TLS 1.3 (xdebug.org). SPC_TARGET has it pick the pre-built libraries for the container's
# glibc (<lib>-<arch>-linux-glibc-2.17.txz).
if [[ ! -x ./spc ]]; then
  curl -fsSL "https://github.com/crazywhalecc/static-php-cli/releases/download/$SPC_VERSION/spc-linux-$(uname -m).tar.gz" | tar xz
  chmod +x spc
fi
download() { SPC_TARGET=native-native-gnu.2.17 ./spc download "$@"; }
# The container mounts these; created here, they belong to the runner's user rather than root.
mkdir -p buildroot source dist downloads pkgroot log
spc() { bin/spc-gnu-docker "$@"; }
spc --version
echo "::endgroup::"

# The container runs as root: what it leaves in the mounted folders can only be removed with sudo.
remove() { rm -rf "$@" 2>/dev/null || sudo rm -rf "$@"; }

all="$STATIC_EXTS${SHARED_EXTS:+,$SHARED_EXTS}"

echo "::group::Download sources for PHP $PHP_VERSION"
# A release candidate (8.6.0RC3) isn't on php.net/distributions: php.net's list of release
# candidates has its tarball (on the release manager's downloads.php.net page) and SHA-256.
rc_sum=""
with_php="$PHP_VERSION"
if [[ "$PHP_VERSION" =~ RC[0-9]+$ ]]; then
  read -r rc_url rc_sum < <(curl -fsSL --retry 3 'https://www.php.net/pre-release-builds.php?format=json' \
    | jq -r --arg v "$PHP_VERSION" '.[] | objects | .release | objects | select(.version == $v) | "\(.files.xz.path) \(.files.xz.sha256)"')
  [[ -n "${rc_url:-}" ]] || { echo "::error::php.net doesn't list PHP $PHP_VERSION as a release candidate"; exit 1; }
  DOWNLOAD_ARGS="$DOWNLOAD_ARGS --custom-url=php-src:$rc_url"
  with_php="$PHP_MINOR" # static-php-cli only takes x.y or x.y.z; the source is the RC tarball
fi
# shellcheck disable=SC2086
download --with-php="$with_php" --for-extensions="$all" --prefer-pre-built --retry=3 ${DOWNLOAD_ARGS:-}
if [[ -n "$rc_sum" ]]; then
  rc_file="downloads/$(basename "$rc_url")"
  [[ -f "$rc_file" ]] || { echo "::error::static-php-cli didn't save $rc_file"; ls downloads; exit 1; }
  got="$(sha256sum "$rc_file" | cut -d' ' -f1)"
  [[ "$got" == "$rc_sum" ]] || { echo "::error::$rc_file: SHA-256 $got, expected $rc_sum"; exit 1; }
  echo "✓ $(basename "$rc_file") SHA-256 $got"
fi
if [[ "$TARGET" == frankenphp ]]; then
  # FRANKENPHP_VERSION pins the release; without it static-php-cli takes the newest.
  download frankenphp --retry=3 \
    ${FRANKENPHP_VERSION:+--custom-url="frankenphp:https://github.com/php/frankenphp/archive/refs/tags/v$FRANKENPHP_VERSION.tar.gz"}
fi
echo "::endgroup::"

if [[ "$TARGET" == frankenphp ]]; then
  # Go toolchain + xcaddy, used to build FrankenPHP. After the downloads: the container writes the
  # download lock as root, which the host's spc couldn't update afterwards.
  echo "::group::Go and xcaddy"
  spc install-pkg go-xcaddy
  echo "::endgroup::"
fi

# spc hides compiler output; it lands in log/ (wiped by the next spc command), so print the errors.
print_spc_errors() {
  echo "::group::static-php-cli log: errors"
  grep -h -E ' error:|fatal error|undefined reference|\*\*\* \[' log/*.log 2>/dev/null | sort -u | head -80 || true
  echo "::endgroup::"
  echo "::group::static-php-cli log: last 80 lines"
  tail -n 80 log/spc.shell.log 2>/dev/null || true
  echo "::endgroup::"
}

rm -rf "$OUT" && mkdir -p "$OUT/bin" "$OUT/ext" "$OUT/LICENSES"

# static-php-cli builds the shared extensions one after another and stops at the first that
# fails. Rebuild without that one until every remaining extension built (at most 4 attempts).
pending="$SHARED_EXTS"
for attempt in 1 2 3 4; do
  echo "::group::Build $TARGET for PHP $PHP_VERSION (attempt $attempt${pending:+, shared: $pending})"
  # Start clean: libraries built for an extension we dropped would otherwise be linked
  # without their dependencies. Pre-built libraries unpack quickly.
  remove buildroot source/php-src
  mkdir -p buildroot
  ok=1
  # static-php-cli's post-build sanity checks are stricter than we need; the smoke test verifies.
  spc build "$STATIC_EXTS" ${pending:+--build-shared="$pending"} "${build_flags[@]}" 2>&1 | tee spc-build.out || ok=0
  echo "::endgroup::"
  [[ $ok -eq 1 ]] || print_spc_errors

  for bin in "${binaries[@]}"; do
    [[ -x "buildroot/bin/$bin" ]] || { echo "::error::$bin missing"; exit 1; }
    cp "buildroot/bin/$bin" "$OUT/bin/"
  done

  remaining=""
  for ext in ${pending//,/ }; do
    so="$(find buildroot/modules buildroot/lib/php -name "$ext.so" 2>/dev/null | head -1 || true)"
    if [[ -n "$so" ]]; then cp "$so" "$OUT/ext/"; else remaining="${remaining:+$remaining,}$ext"; fi
  done
  [[ -z "$remaining" ]] && break

  failed="$(sed -n 's/.*Failed module: .*shared extension \([a-z0-9_]*\) builder.*/\1/p' spc-build.out | tail -1)"
  if [[ -z "$failed" ]]; then
    echo "::warning::not built and no failing extension reported: $remaining"
    break
  fi
  echo "::warning::$failed.so failed to build, retrying without it"
  pending="$(tr ',' '\n' <<<"$remaining" | { grep -vx "$failed" || true; } | paste -sd, -)"
  [[ -n "$pending" ]] || break
done
for ext in ${SHARED_EXTS//,/ }; do
  [[ -f "$OUT/ext/$ext.so" ]] || echo "::warning::$ext.so was not built"
done

if [[ "$TARGET" == php && "$PHP_VERSION" == *.*.* ]]; then
  built="$("$OUT/bin/php" -n -r 'echo PHP_VERSION;')"
  [[ "$built" == "$PHP_VERSION" ]] || { echo "::error::asked for PHP $PHP_VERSION, built $built"; exit 1; }
fi

# The binaries keep the container's library path (/app/buildroot/lib) as RPATH: nothing is there
# on a user's machine, and whoever could create it would have PHP load their libraries.
find "$OUT/bin" "$OUT/ext" -type f -exec patchelf --remove-rpath {} \;

# Inside the container, so into a mounted folder.
remove dist/licenses
if spc dump-license --for-extensions="$all" --dump-dir=dist/licenses; then
  cp -R dist/licenses/. "$OUT/LICENSES/"
else
  echo "::warning::license dump failed"
fi
if [[ "$TARGET" == frankenphp ]]; then
  cp source/frankenphp/LICENSE "$OUT/LICENSES/frankenphp.txt"
fi

ls -la "$OUT/bin"
echo "built $TARGET for PHP $PHP_VERSION into $OUT"
