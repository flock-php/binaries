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

# PHP < 8.2 still has K&R-style function definitions (e.g. ext/bcmath/libbcmath), which
# Xcode's clang rejects now that it defaults to C23. Overrides spc's default C flags.
if [[ "$(printf '%s\n8.2\n' "$PHP_MINOR" | sort -V | head -1)" != "8.2" ]]; then
  export SPC_DEFAULT_C_FLAGS="--target=arm64-apple-darwin -Os -std=gnu17"
fi

# static-php-cli joins swoole's configure flags without a space, producing
# "--with-nghttp2-dir=<buildroot>--disable-iouring". Make that path exist.
ln -sfn "$WORK_DIR/buildroot" "$WORK_DIR/buildroot--disable-iouring"

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
  echo "::group::Build PHP $PHP_MINOR (attempt $attempt${pending:+, shared: $pending})"
  # Start clean: libraries built for an extension we dropped (e.g. curl with brotli for swoole)
  # would otherwise be linked without their dependencies. Pre-built libraries unpack quickly.
  rm -rf buildroot source/php-src
  ok=1
  # static-php-cli's post-build sanity checks are stricter than we need; the smoke test verifies.
  ./spc build "$STATIC_EXTS" ${pending:+--build-shared="$pending"} --build-cli --build-fpm 2>&1 | tee spc-build.out || ok=0
  echo "::endgroup::"
  [[ $ok -eq 1 ]] || print_spc_errors

  [[ -x buildroot/bin/php && -x buildroot/bin/php-fpm ]] || { echo "::error::php or php-fpm missing"; exit 1; }
  cp buildroot/bin/php buildroot/bin/php-fpm "$OUT/bin/"

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

./spc dump-license --for-extensions="$all" --dump-dir="$OUT/LICENSES" \
  || echo "::warning::license dump failed"

# Binaries must be signed to run on Apple Silicon; re-sign after copying/stripping.
find "$OUT/bin" "$OUT/ext" -type f -exec codesign --force --sign - {} \;

"$OUT/bin/php" -n -v
echo "built PHP into $OUT"
