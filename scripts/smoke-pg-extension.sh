#!/usr/bin/env bash
# Smoke-tests a PostgreSQL extension package on macOS or Linux the way Flock runs it: both unpacked
# in their own folders, the extension's lib/ and extension/ symlinked into the server's pkglibdir
# and extension directory (Linux: its deps/ on LD_LIBRARY_PATH, as $ORIGIN is the symlink's
# folder there), preloaded when it has to be, then CREATE EXTENSION and a query that uses it.
# PROJ_DATA is unset: PostGIS must find proj.db by itself.
# Usage: scripts/smoke-pg-extension.sh <extension> <postgres-dir> <archive> [<required-archive>...]
set -uo pipefail
EXT="${1:?usage: smoke-pg-extension.sh <extension> <postgres-dir> <archive> [<required-archive>...]}"
PG="$(cd "${2:?}" && pwd -P)"
ARCHIVE="${3:?}"; shift 3
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
unset PROJ_DATA PROJ_LIB
failed=0
ok() { echo "✓ $*" | tee -a "$summary"; }
fail() { echo "✗ $*" | tee -a "$summary"; failed=1; }

lib="$("$PG/bin/pg_config" --pkglibdir)" share="$("$PG/bin/pg_config" --sharedir)"
deps=()
unpack() { # <archive> <name>
  mkdir -p "$tmp/$2" && tar -C "$tmp/$2" -xzf "$1"
  for f in "$tmp/$2"/lib/*; do [[ -e "$f" ]] && ln -sf "$f" "$lib/"; done
  for f in "$tmp/$2"/extension/*; do ln -sf "$f" "$share/extension/"; done
  [[ -d "$tmp/$2/deps" ]] && deps+=("$tmp/$2/deps")
  return 0
}
unpack "$ARCHIVE" "$EXT"
i=0
for required in "$@"; do unpack "$required" "required$i"; i=$((i + 1)); done
echo "### $EXT: $(basename "$ARCHIVE") on PostgreSQL $("$PG/bin/pg_config" --version)" | tee -a "$summary"
if [[ "$(uname -s)" != Darwin && ${#deps[@]} -gt 0 ]]; then
  export LD_LIBRARY_PATH="$(IFS=:; echo "${deps[*]}")"
fi

settings="-c listen_addresses=127.0.0.1"
[[ "$EXT" == timescaledb ]] && settings+=" -c shared_preload_libraries=timescaledb -c timescaledb.telemetry_level=off"
"$PG/bin/initdb" -D "$tmp/data" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null
"$PG/bin/pg_ctl" -D "$tmp/data" -l "$tmp/log" -w start -o "-p 54329 -k '' $settings" >/dev/null ||
  { fail "postgres did not start: $(tail -5 "$tmp/log")"; exit 1; }
trap '"$PG/bin/pg_ctl" -D "$tmp/data" -m fast stop >/dev/null 2>&1' EXIT
check() { # <name> <sql> <expected substring>
  local got
  if got="$("$PG/bin/psql" -X -h 127.0.0.1 -p 54329 -U postgres -v ON_ERROR_STOP=1 -At -c "$2" 2>&1)" && [[ "$got" == *"$3"* ]]; then
    ok "$1: $(tail -1 <<<"$got")"
  else
    fail "$1: $(tail -3 <<<"$got")"
  fi
}

case "$EXT" in
  pgvector)
    check "CREATE EXTENSION vector" "CREATE EXTENSION vector; SELECT extversion FROM pg_extension WHERE extname = 'vector'" "."
    check "distance" "SELECT '[1,2,3]'::vector <-> '[3,2,1]'" "2.828"
    check "HNSW index" "CREATE TABLE items (embedding vector(3)); INSERT INTO items SELECT ARRAY[random(), random(), random()] FROM generate_series(1, 200);
      CREATE INDEX ON items USING hnsw (embedding vector_l2_ops); SELECT count(*) FROM (SELECT 1 FROM items ORDER BY embedding <-> '[0.5,0.5,0.5]' LIMIT 5) t" "5"
    ;;
  postgis)
    check "CREATE EXTENSION postgis" "CREATE EXTENSION postgis; SELECT postgis_full_version()" "PROJ="
    check "ST_Transform (proj.db)" "SELECT ST_AsText(ST_Transform(ST_SetSRID(ST_MakePoint(14.42, 50.08), 4326), 3857))" "POINT(1605227"
    check "geography distance" "SELECT round(ST_Distance('POINT(14.42 50.08)'::geography, 'POINT(16.61 49.19)'::geography) / 1000)" "18"
    check "postgis_topology" "CREATE EXTENSION postgis_topology; SELECT count(*) FROM topology.topology" "0"
    ;;
  pgrouting)
    check "CREATE EXTENSION pgrouting" "CREATE EXTENSION postgis; CREATE EXTENSION pgrouting; SELECT pgr_version()" "."
    check "pgr_dijkstra" "CREATE TABLE edges (id int, source int, target int, cost float); INSERT INTO edges VALUES (1,1,2,1),(2,2,3,1),(3,1,3,5);
      SELECT max(agg_cost) FROM pgr_dijkstra('SELECT id, source, target, cost FROM edges', 1, 3, false)" "2"
    ;;
  timescaledb)
    check "CREATE EXTENSION timescaledb" "CREATE EXTENSION timescaledb; SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'" "."
    check "hypertable + compression (TSL)" "CREATE TABLE m (t timestamptz NOT NULL, v float); SELECT create_hypertable('m', 't');
      INSERT INTO m SELECT t, random() FROM generate_series(now() - interval '3 days', now(), interval '1 minute') t;
      ALTER TABLE m SET (timescaledb.compress); SELECT count(compress_chunk(c)) > 0 FROM show_chunks('m') c" "t"
    check "telemetry off" "SHOW timescaledb.telemetry_level" "off"
    ;;
  *) fail "no smoke test for $EXT" ;;
esac
exit $failed
