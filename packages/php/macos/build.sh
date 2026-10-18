#!/usr/bin/env bash
# Builds PHP for macOS with static-php-cli: either php + php-fpm (NTS) or FrankenPHP (ZTS,
# PHP embedded), each with the same compiled-in extensions plus shared extensions as .so.
#
# Usage: packages/php/macos/build.sh <major.minor[.patch]> <out-dir>
#   major.minor builds the newest patch release; major.minor.patch exactly that release.
#   SPC_VERSION     static-php-cli release to use (required)
#   STATIC_EXTS     comma-separated extensions compiled in (required)
#   SHARED_EXTS     comma-separated extensions built as .so (optional)
#   TARGET          php (default: bin/php, bin/php-fpm) or frankenphp (bin/frankenphp, PHP >= 8.2)
#   DOWNLOAD_ARGS   extra arguments for `spc download`, e.g. --custom-url=xdebug:https://… (optional)
#   FRANKENPHP_VERSION  FrankenPHP release for TARGET=frankenphp, e.g. 1.13.0 (default: newest)
#   WORK_DIR        static-php-cli workspace (default: ./spc-work)
#   GITHUB_TOKEN    lets static-php-cli query GitHub without the anonymous rate limit
#
# Produces <out-dir>/bin/…, <out-dir>/ext/*.so and <out-dir>/LICENSES/.
# A shared extension that fails to build is reported, not fatal: PHP is still usable without it.
set -euo pipefail

PHP_VERSION="${1:?usage: build.sh <major.minor[.patch]> <out-dir>}"
PHP_MINOR="$(cut -d. -f1-2 <<<"$PHP_VERSION")"
OUT="$(mkdir -p "${2:?usage: build.sh <major.minor[.patch]> <out-dir>}" && cd "$2" && pwd)"
: "${SPC_VERSION:?SPC_VERSION is required}"
: "${STATIC_EXTS:?STATIC_EXTS is required}"
SHARED_EXTS="${SHARED_EXTS:-}"
TARGET="${TARGET:-php}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

case "$TARGET" in
  php)        build_flags=(--build-cli --build-fpm); binaries=(php php-fpm) ;;
  frankenphp) build_flags=(--enable-zts --build-frankenphp); binaries=(frankenphp) ;;
  *)          echo "unknown TARGET $TARGET" >&2; exit 1 ;;
esac

mkdir -p "${WORK_DIR:=$PWD/spc-work}"
cd "$WORK_DIR"

# PHP 8.1 still has K&R-style function definitions (e.g. ext/bcmath/libbcmath), which Xcode's
# clang rejects now that it defaults to C23. Only PHP's own C flags get -std=gnu17: the
# default flags also reach C++ compilers, which refuse it. (macOS builds start at 8.1.)
if [[ "$PHP_MINOR" == 8.1 ]]; then
  export SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="-g -fstack-protector-strong -fpic -fpie -Werror=unknown-warning-option --target=arm64-apple-darwin -Os -std=gnu17"
fi

# Stable Xdebug: static-php-cli takes the newest tag, which can be an alpha (3.6.0alpha1
# no longer builds for 8.1). 3.5.3 supports PHP 8.0–8.5; 8.6 has only 3.6.0alpha1 so far.
xdebug=3.5.3
[[ "$PHP_MINOR" == 8.6 ]] && xdebug=3.6.0alpha1
DOWNLOAD_ARGS="${DOWNLOAD_ARGS:-} --custom-url=xdebug:https://xdebug.org/files/xdebug-$xdebug.tgz"
# opentelemetry (only its hook() is used, by Flock's runtime capture): static-php-cli takes
# whatever PECL's newest is; pin it like xdebug. Shared and not loaded by default.
DOWNLOAD_ARGS="$DOWNLOAD_ARGS --custom-url=opentelemetry:https://pecl.php.net/get/opentelemetry-1.4.2.tgz"

echo "::group::static-php-cli $SPC_VERSION"
if [[ ! -x ./spc ]]; then
  curl -fsSL "https://github.com/crazywhalecc/static-php-cli/releases/download/$SPC_VERSION/spc-macos-aarch64.tar.gz" | tar xz
  chmod +x spc
fi
./spc --version
./spc doctor --auto-fix
if [[ "$TARGET" == frankenphp ]]; then
  ./spc install-pkg go-xcaddy   # Go toolchain + xcaddy, used to build FrankenPHP
fi
echo "::endgroup::"

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
./spc download --with-php="$with_php" --for-extensions="$all" --prefer-pre-built --retry=3 ${DOWNLOAD_ARGS:-}
if [[ -n "$rc_sum" ]]; then
  rc_file="downloads/$(basename "$rc_url")"
  [[ -f "$rc_file" ]] || { echo "::error::static-php-cli didn't save $rc_file"; ls downloads; exit 1; }
  got="$(shasum -a 256 "$rc_file" | cut -d' ' -f1)"
  [[ "$got" == "$rc_sum" ]] || { echo "::error::$rc_file: SHA-256 $got, expected $rc_sum"; exit 1; }
  echo "✓ $(basename "$rc_file") SHA-256 $got"
fi
if [[ "$TARGET" == frankenphp ]]; then
  # FRANKENPHP_VERSION pins the release; without it static-php-cli takes the newest.
  ./spc download frankenphp --retry=3 \
    ${FRANKENPHP_VERSION:+--custom-url="frankenphp:https://github.com/php/frankenphp/archive/refs/tags/v$FRANKENPHP_VERSION.tar.gz"}
fi
echo "::endgroup::"

# spc hides compiler output; it lands in log/ (wiped by the next spc command), so print the errors.
print_spc_errors() {
  echo "::group::static-php-cli log: errors"
  grep -h -E ' error:|fatal error|Undefined symbols|^  "_|symbol\(s\) not found|\*\*\* \[' log/*.log 2>/dev/null | sort -u | head -80 || true
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
  rm -rf buildroot source/php-src
  ok=1
  # static-php-cli's post-build sanity checks are stricter than we need; the smoke test verifies.
  ./spc build "$STATIC_EXTS" ${pending:+--build-shared="$pending"} "${build_flags[@]}" 2>&1 | tee spc-build.out || ok=0
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

./spc dump-license --for-extensions="$all" --dump-dir="$OUT/LICENSES" \
  || echo "::warning::license dump failed"
if [[ "$TARGET" == frankenphp ]]; then
  cp source/frankenphp/LICENSE "$OUT/LICENSES/frankenphp.txt"
fi

# Binaries must be signed to run on Apple Silicon; re-sign after copying/stripping.
find "$OUT/bin" "$OUT/ext" -type f -exec codesign --force --sign - {} \;

ls -la "$OUT/bin"
echo "built $TARGET for PHP $PHP_VERSION into $OUT"
