#!/usr/bin/env bash
# Smoke-tests a PHP package directory (bin/php, bin/php-fpm, ext/*.so).
#   - php and php-fpm run, php-fpm accepts a minimal config
#   - every compiled-in extension is loaded
#   - every shared extension in ext/ loads on its own (zend_extension for xdebug)
#   - opentelemetry's hook() fires (scripts/smoke-opentelemetry.php)
# Missing compiled-in extensions fail the test. Shared extensions are reported; pass
# REQUIRE_SHARED=1 to fail on them too. Results are appended to $GITHUB_STEP_SUMMARY when set.
# Usage: scripts/smoke-php.sh <dir> <static-ext,...> <shared-ext,...>
set -uo pipefail

DIR="${1:?usage: smoke-php.sh <dir> <static-exts> <shared-exts>}"
STATIC="${2:-}"
SHARED="${3:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
php="$DIR/bin/php"
failed=0

echo "### $("$php" -n -r 'echo "PHP ", PHP_VERSION, " (", PHP_OS, " ", php_uname("m"), ")";')" | tee -a "$summary"

if ! "$DIR/bin/php-fpm" -n -v >/dev/null; then
  echo "✗ php-fpm does not run" | tee -a "$summary"; failed=1
fi
fpm_conf="$(mktemp)"
printf '[global]\nerror_log=/dev/null\n[www]\nlisten=127.0.0.1:9999\npm=static\npm.max_children=1\n' >"$fpm_conf"
if ! "$DIR/bin/php-fpm" -n -t -y "$fpm_conf" >/dev/null 2>&1; then
  echo "✗ php-fpm -t rejected a minimal config" | tee -a "$summary"; failed=1
fi

modules="$("$php" -n -m | tr '[:upper:]' '[:lower:]')"
missing=()
for ext in ${STATIC//,/ }; do
  case "$ext" in
    mbregex) continue ;;
    opcache) [[ -f "$DIR/ext/opcache.so" ]] && continue; ext="zend opcache" ;; # shared on 7.4
  esac
  grep -qx "$ext" <<<"$modules" || missing+=("$ext")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "✗ compiled-in extensions missing: ${missing[*]}" | tee -a "$summary"; failed=1
else
  echo "✓ all compiled-in extensions loaded" | tee -a "$summary"
fi

{
  echo
  echo "| shared extension | result | size |"
  echo "|---|---|---|"
} >>"$summary"
# Every listed extension, plus any other .so in ext/ (e.g. opcache on PHP 7.4).
for so in "$DIR"/ext/*.so; do
  [[ -f "$so" ]] || continue
  name="$(basename "$so" .so)"
  [[ ",$SHARED," == *",$name,"* ]] || SHARED="${SHARED:+$SHARED,}$name"
done
for ext in ${SHARED//,/ }; do
  # Absolute: PHP resolves relative extension paths against extension_dir.
  so="$(cd "$DIR/ext" && pwd)/$ext.so"
  if [[ ! -f "$so" ]]; then
    echo "| $ext | ✗ not built | |" >>"$summary"; echo "✗ $ext.so not built"
    [[ "${REQUIRE_SHARED:-0}" == 1 ]] && failed=1
    continue
  fi
  directive="extension"; name="$ext"
  case "$ext" in xdebug) directive="zend_extension" ;; opcache) directive="zend_extension"; name="Zend OPcache" ;; esac
  out="$("$php" -n -d "$directive=$so" -r "echo phpversion('$name');" 2>&1)"
  rc=$?
  size="$(du -h "$so" | cut -f1)"
  if [[ $rc -eq 0 && -n "$out" && "$out" != *Warning* && "$out" != *Error* ]]; then
    echo "| $ext | ✓ $out | $size |" >>"$summary"; echo "✓ $ext $out"
  else
    echo "| $ext | ✗ does not load | $size |" >>"$summary"; echo "✗ $ext does not load: $out"
    [[ "${REQUIRE_SHARED:-0}" == 1 ]] && failed=1
  fi
done

# opentelemetry is only there for its hook(): loading is not enough, the hooks have to fire.
if [[ -f "$DIR/ext/opentelemetry.so" ]]; then
  out="$("$php" -n -d "extension=$(cd "$DIR/ext" && pwd)/opentelemetry.so" "$(dirname "$0")/smoke-opentelemetry.php" 2>&1)"
  if [[ "$out" == "hook ok "* ]]; then
    echo "✓ opentelemetry $out" | tee -a "$summary"
  else
    echo "✗ opentelemetry hook(): $out" | tee -a "$summary"
    [[ "${REQUIRE_SHARED:-0}" == 1 ]] && failed=1
  fi
fi

exit $failed
