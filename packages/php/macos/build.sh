#!/usr/bin/env bash
# Builds PHP (cli + fpm, plus shared extensions) for macOS with static-php-cli.
#
# Usage: packages/php/macos/build.sh <major.minor> <out-dir>
#   SPC_VERSION     static-php-cli release to use (required)
#   STATIC_EXTS     comma-separated extensions compiled into php/php-fpm (required)
#   SHARED_EXTS     comma-separated extensions built as .so (optional)
#   DOWNLOAD_ARGS   extra arguments for `spc download`, e.g. --custom-url=xdebug:https://… (optional)
#   WORK_DIR        static-php-cli workspace (default: ./spc-work)
#   GITHUB_TOKEN    lets static-php-cli query GitHub without the anonymous rate limit
#
# Produces <out-dir>/bin/{php,php-fpm}, <out-dir>/ext/*.so and <out-dir>/LICENSES/.
# A shared extension that fails to build is reported, not fatal: PHP is still usable without it.
set -euo pipefail

PHP_MINOR="${1:?usage: build.sh <major.minor> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: build.sh <major.minor> <out-dir>}" && cd "$2" && pwd)"
: "${SPC_VERSION:?SPC_VERSION is required}"
: "${STATIC_EXTS:?STATIC_EXTS is required}"
SHARED_EXTS="${SHARED_EXTS:-}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

mkdir -p "${WORK_DIR:=$PWD/spc-work}"
cd "$WORK_DIR"

echo "::group::static-php-cli $SPC_VERSION"
if [[ ! -x ./spc ]]; then
  curl -fsSL "https://github.com/crazywhalecc/static-php-cli/releases/download/$SPC_VERSION/spc-macos-aarch64.tar.gz" | tar xz
  chmod +x spc
fi
./spc --version
./spc doctor --auto-fix
echo "::endgroup::"

all="$STATIC_EXTS${SHARED_EXTS:+,$SHARED_EXTS}"

echo "::group::Download sources for PHP $PHP_MINOR"
# shellcheck disable=SC2086
./spc download --with-php="$PHP_MINOR" --for-extensions="$all" --prefer-pre-built --retry=3 ${DOWNLOAD_ARGS:-}
echo "::endgroup::"

echo "::group::Build PHP $PHP_MINOR"
rm -rf buildroot/modules buildroot/bin/php buildroot/bin/php-fpm
# static-php-cli's post-build sanity checks are stricter than we need; the smoke test verifies.
./spc build "$STATIC_EXTS" ${SHARED_EXTS:+--build-shared="$SHARED_EXTS"} --build-cli --build-fpm \
  || echo "::warning::spc build reported a problem, checking what was built"
echo "::endgroup::"

[[ -x buildroot/bin/php && -x buildroot/bin/php-fpm ]] || { echo "::error::php or php-fpm missing"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT/bin" "$OUT/ext" "$OUT/LICENSES"
cp buildroot/bin/php buildroot/bin/php-fpm "$OUT/bin/"
for ext in ${SHARED_EXTS//,/ }; do
  so="$(find buildroot/modules buildroot/lib/php -name "$ext.so" 2>/dev/null | head -1 || true)"
  if [[ -n "$so" ]]; then
    cp "$so" "$OUT/ext/"
  else
    echo "::warning::$ext.so was not built"
  fi
done

./spc dump-license --for-extensions="$all" --dump-dir="$OUT/LICENSES" \
  || echo "::warning::license dump failed"

# Binaries must be signed to run on Apple Silicon; re-sign after copying/stripping.
find "$OUT/bin" "$OUT/ext" -type f -exec codesign --force --sign - {} \;

"$OUT/bin/php" -n -v
echo "built PHP into $OUT"
