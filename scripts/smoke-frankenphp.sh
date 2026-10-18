#!/usr/bin/env bash
# Smoke-tests a FrankenPHP package directory (bin/frankenphp, ext/*.so) the way Octane uses it:
#   - frankenphp runs, embeds a thread-safe PHP of the expected minor
#   - every compiled-in extension is loaded (frankenphp php-cli)
#   - every shared extension in ext/ loads into the embedded PHP; opentelemetry's hook() fires
#   - a classic request and worker mode (frankenphp_handle_request, state kept between requests)
# Results are appended to $GITHUB_STEP_SUMMARY when set.
# Usage: scripts/smoke-frankenphp.sh <dir> <php-minor> <static-ext,...>
set -uo pipefail

DIR="$(cd "${1:?usage: smoke-frankenphp.sh <dir> <php-minor> <static-exts>}" && pwd)"
MINOR="${2:?php minor required}"
STATIC="${3:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
fp="$DIR/bin/frankenphp"
work="$(mktemp -d)"
failed=0
report() { echo "$1" | tee -a "$summary"; }

report "### $("$fp" version 2>&1 | head -1)"

cat >"$work/info.php" <<'PHP'
<?php
echo PHP_VERSION, ' ', ZEND_THREAD_SAFE ? 'zts' : 'nts', "\n";
echo strtolower(implode("\n", get_loaded_extensions())), "\n";
foreach (get_loaded_extensions(true) as $z) echo strtolower($z), "\n";
PHP
info="$("$fp" php-cli "$work/info.php" 2>&1)"
read -r version ts <<<"$(head -1 <<<"$info")"
if [[ "$version" == "$MINOR".* && "$ts" == zts ]]; then
  report "✓ embedded PHP $version ($ts)"
else
  report "✗ embedded PHP: $(head -3 <<<"$info" | tr '\n' ' ')"; failed=1
fi

missing=()
for ext in ${STATIC//,/ }; do
  case "$ext" in mbregex) continue ;; opcache) ext="zend opcache" ;; esac
  grep -qx "$ext" <<<"$info" || missing+=("$ext")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  report "✗ compiled-in extensions missing: ${missing[*]}"; failed=1
else
  report "✓ all compiled-in extensions loaded"
fi

# Shared extensions: loaded through an ini file, the way Flock would configure them.
# Under `frankenphp php-cli`, $argv[0] is frankenphp and $argv[1] the script.
echo '<?php foreach (array_slice($argv, 2) as $e) echo $e, "=", phpversion($e) ?: "missing", "\n";' >"$work/ext.php"
for so in "$DIR"/ext/*.so; do
  [[ -f "$so" ]] || continue
  name="$(basename "$so" .so)"
  mkdir -p "$work/ini-$name"
  directive="extension"; probe="$name"
  [[ "$name" == xdebug ]] && directive="zend_extension"
  echo "$directive=$so" >"$work/ini-$name/ext.ini"
  out="$(PHP_INI_SCAN_DIR="$work/ini-$name" "$fp" php-cli "$work/ext.php" "$probe" 2>&1)"
  if [[ "$out" == "$probe="* && "$out" != *missing* && "$out" != *Warning* ]]; then
    report "✓ shared $out"
  else
    report "✗ shared $name: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; failed=1
  fi
done
# opentelemetry is only there for its hook(): loading is not enough, the hooks have to fire.
if [[ -d "$work/ini-opentelemetry" ]]; then
  out="$(PHP_INI_SCAN_DIR="$work/ini-opentelemetry" "$fp" php-cli "$(dirname "$0")/smoke-opentelemetry.php" 2>&1)"
  if [[ "$out" == "hook ok "* ]]; then report "✓ opentelemetry $out"; else report "✗ opentelemetry hook(): $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; failed=1; fi
fi

# HTTP: one classic request and two worker-mode requests (the counter proves the worker persists).
mkdir -p "$work/public" "$work/worker"
echo '<?php echo "classic ", PHP_VERSION;' >"$work/public/index.php"
# The worker gets its own root, so it serves every request there.
cat >"$work/worker/index.php" <<'PHP'
<?php
$n = 0;
while (frankenphp_handle_request(function () use (&$n) { echo "worker ", ++$n; })) {
    gc_collect_cycles();
}
PHP
port=18099
"$fp" php-server --listen "127.0.0.1:$port" --root "$work/public" >"$work/classic.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$port/" >/dev/null && break; sleep 0.2; done
body="$(curl -s "http://127.0.0.1:$port/")"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
if [[ "$body" == "classic $MINOR."* ]]; then report "✓ classic request: $body"; else report "✗ classic request: '$body' $(tail -3 "$work/classic.log" | tr '\n' ' ')"; failed=1; fi

port=18100
"$fp" php-server --listen "127.0.0.1:$port" --root "$work/worker" --worker "$work/worker/index.php" >"$work/worker.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$port/" >/dev/null && break; sleep 0.2; done
first="$(curl -s "http://127.0.0.1:$port/")"; second="$(curl -s "http://127.0.0.1:$port/")"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
# The readiness probe above already counted once; what matters is that the counter increases.
if [[ "$first" == "worker "* && "$second" == "worker "* && "${second#worker }" -gt "${first#worker }" ]]; then
  report "✓ worker mode keeps state: '$first' then '$second'"
else
  report "✗ worker mode: '$first' / '$second' $(tail -3 "$work/worker.log" | tr '\n' ' ')"; failed=1
fi

rm -rf "$work"
exit $failed
