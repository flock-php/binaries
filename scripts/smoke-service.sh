#!/usr/bin/env bash
# Smoke-tests a service package on macOS the way Flock runs it: unpack (dropping a single
# top-level folder, as Flock does), initialise a data directory, start on 127.0.0.1, talk to it
# with its own client, shut down. With SIGNER set, the main binary must carry a valid code
# signature whose authority matches that regex (the vendor's, for mirrored packages).
# Usage: scripts/smoke-service.sh <package> <archive>
set -uo pipefail

PKG="${1:?usage: smoke-service.sh <package> <archive>}"
ARCHIVE="${2:?usage: smoke-service.sh <package> <archive>}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
tmp="$(mktemp -d)"
D="$tmp/pkg"
data="$tmp/data"
mkdir -p "$D" "$data"
failed=0

ok() { echo "✓ $*" | tee -a "$summary"; }
fail() { echo "✗ $*" | tee -a "$summary"; failed=1; }
check() { local name="$1"; shift; if out="$("$@" 2>&1)"; then ok "$name"; else fail "$name: $(tail -5 <<<"$out")"; fi; }
wait_port() {
  for _ in $(seq 1 150); do (echo >"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
wait_http() {
  for _ in $(seq 1 150); do curl -fs "$1" >/dev/null && return 0; sleep 0.2; done
  return 1
}
stop() { kill "$1" 2>/dev/null; for _ in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done; kill -9 "$1"; return 1; }

tar -C "$D" -xzf "$ARCHIVE"
# Flock drops a single top-level folder (mysql-8.4.6-macos15-arm64/, node-v22…/).
entries=("$D"/*)
if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then D="${entries[0]}"; fi
echo "### $PKG: $(basename "$ARCHIVE")" | tee -a "$summary"

if [[ -n "${SIGNER:-}" ]]; then
  case "$PKG" in mysql) main=bin/mysqld ;; mongodb) main=bin/mongod ;; node) main=bin/node ;; *) main="" ;; esac
  if codesign --verify --strict "$D/$main" 2>/dev/null \
     && authority="$(codesign -dvv "$D/$main" 2>&1 | sed -n 's/^Authority=//p' | head -1)" \
     && grep -Eq "$SIGNER" <<<"$authority"; then
    ok "code signature: $authority"
  else
    fail "code signature of $main: $(codesign -dvv "$D/$main" 2>&1 | grep -E 'Authority|not signed' | head -2)"
  fi
fi

case "$PKG" in
  postgres)
    check "initdb" "$D/bin/initdb" -D "$data" -U postgres --auth=trust -E UTF8 --locale=C
    "$D/bin/postgres" -D "$data" -p 54329 -c listen_addresses=127.0.0.1 -k "$tmp" >"$tmp/log" 2>&1 &
    pid=$!
    wait_port 54329 || fail "postgres did not start: $(tail -5 "$tmp/log")"
    psql=("$D/bin/psql" -h 127.0.0.1 -p 54329 -U postgres -v ON_ERROR_STOP=1 -At)
    check "query: $("${psql[@]}" -c 'select version()' 2>&1)" "${psql[@]}" -c 'select 1'
    check "contrib extensions (pgcrypto, uuid-ossp, pg_trgm, hstore, citext)" "${psql[@]}" \
      -c 'create extension pgcrypto; create extension "uuid-ossp"; create extension pg_trgm; create extension hstore; create extension citext' \
      -c "select digest('flock', 'sha256'), uuid_generate_v4(), gen_random_uuid(), similarity('flock', 'block'), 'a=>1'::hstore, 'A'::citext = 'a'"
    check "createdb" "$D/bin/createdb" -h 127.0.0.1 -p 54329 -U postgres flock
    check "pg_dump | pg_restore" bash -c "'$D/bin/pg_dump' -h 127.0.0.1 -p 54329 -U postgres -Fc postgres >'$tmp/dump' && '$D/bin/pg_restore' -l '$tmp/dump' >/dev/null"
    check "pg_ctl stop" "$D/bin/pg_ctl" stop -D "$data" -m fast
    ;;

  mariadb | mysql)
    if [[ "$PKG" == mariadb ]]; then
      check "install-db" "$D/scripts/mariadb-install-db" --no-defaults --basedir="$D" --datadir="$data" \
        --auth-root-authentication-method=normal --skip-test-db
      server="$D/bin/mariadbd"; client="$D/bin/mariadb"; admin="$D/bin/mariadb-admin"; extra=()
    else
      check "initialize" "$D/bin/mysqld" --no-defaults --initialize-insecure --basedir="$D" --datadir="$data"
      server="$D/bin/mysqld"; client="$D/bin/mysql"; admin="$D/bin/mysqladmin"; extra=(--mysqlx=OFF)
    fi
    "$server" --no-defaults --basedir="$D" --datadir="$data" --port=33069 --bind-address=127.0.0.1 \
      --socket="$tmp/sql.sock" "${extra[@]}" >"$tmp/log" 2>&1 &
    pid=$!
    wait_port 33069 || fail "server did not start: $(tail -5 "$tmp/log")"
    sql=("$client" --no-defaults -h127.0.0.1 -P33069 -uroot)
    check "query: $("${sql[@]}" -N -e 'select version()' 2>&1)" "${sql[@]}" \
      -e 'create database flock; create table flock.t (id int primary key, v json) engine=innodb; insert into flock.t values (1, json_object("a", 1)); select * from flock.t'
    check "shutdown" "$admin" --no-defaults -h127.0.0.1 -P33069 -uroot shutdown
    wait "$pid"
    ;;

  mongodb)
    check "mongod --version" "$D/bin/mongod" --version
    "$D/bin/mongod" --dbpath "$data" --port 27029 --bind_ip 127.0.0.1 --nounixsocket >"$tmp/log" 2>&1 &
    pid=$!
    if wait_port 27029; then ok "mongod accepts connections"; else fail "mongod did not start: $(tail -5 "$tmp/log")"; fi
    check "stop" stop "$pid"
    ;;

  redis | valkey)
    "$D/$PKG-server" --port 63799 --bind 127.0.0.1 --dir "$data" --daemonize no --appendonly yes >"$tmp/log" 2>&1 &
    pid=$!
    wait_port 63799 || fail "$PKG-server did not start: $(tail -5 "$tmp/log")"
    cli=("$D/$PKG-cli" -p 63799)
    check "version: $("$D/$PKG-server" --version)" test "$("${cli[@]}" PING)" = PONG
    check "SET/GET" bash -c "'$D/$PKG-cli' -p 63799 SET flock works >/dev/null && test \"\$('$D/$PKG-cli' -p 63799 GET flock)\" = works"
    check "BGSAVE" "${cli[@]}" BGSAVE
    sleep 1
    check "SHUTDOWN" bash -c "'$D/$PKG-cli' -p 63799 SHUTDOWN; true"
    wait "$pid"
    ;;

  meilisearch)
    "$D/meilisearch" --db-path "$data/data.ms" --http-addr 127.0.0.1:7709 --env development --no-analytics >"$tmp/log" 2>&1 &
    pid=$!
    if wait_http http://127.0.0.1:7709/health; then ok "health: $(curl -s http://127.0.0.1:7709/version)"; else fail "meilisearch did not start: $(tail -5 "$tmp/log")"; fi
    check "index a document" curl -fs -X POST http://127.0.0.1:7709/indexes/flock/documents -H 'Content-Type: application/json' -d '[{"id":1,"name":"flock"}]'
    check "stop" stop "$pid"
    ;;

  typesense)
    "$D/typesense-server" --data-dir "$data" --api-key=flock --api-address=127.0.0.1 --api-port=8199 \
      --peering-address=127.0.0.1 --peering-port=8198 --enable-cors >"$tmp/log" 2>&1 &
    pid=$!
    for _ in $(seq 1 150); do curl -fs http://127.0.0.1:8199/health | grep -q '"ok":true' && break; sleep 0.2; done
    if curl -fs http://127.0.0.1:8199/health | grep -q '"ok":true'; then ok "health"; else fail "typesense did not become healthy: $(tail -5 "$tmp/log")"; fi
    check "create a collection" curl -fs -X POST http://127.0.0.1:8199/collections -H 'X-TYPESENSE-API-KEY: flock' \
      -d '{"name":"flock","fields":[{"name":"name","type":"string"}]}'
    check "stop" stop "$pid"
    ;;

  rustfs)
    # Upstream's macOS build links Homebrew's liblzma by absolute path; Flock falls back to /usr/lib.
    DYLD_FALLBACK_LIBRARY_PATH=/usr/lib "$D/rustfs" server --address 127.0.0.1:9109 \
      --access-key rustfsadmin --secret-key rustfsadmin "$data" >"$tmp/log" 2>&1 &
    pid=$!
    if wait_port 9109; then ok "rustfs listens: HTTP $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9109/)"; else fail "rustfs did not start: $(tail -5 "$tmp/log")"; fi
    check "stop" stop "$pid"
    ;;

  node)
    check "node $("$D/bin/node" --version)" "$D/bin/node" -e 'require("crypto").createHash("sha256").update("x").digest("hex")'
    check "npm $("$D/bin/npm" --version 2>&1)" "$D/bin/npm" --version
    ;;

  *) fail "no smoke test for $PKG" ;;
esac

exit $failed
