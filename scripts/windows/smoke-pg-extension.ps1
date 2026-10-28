# Smoke-tests a PostgreSQL extension package on Windows the way Flock runs it: its lib\ copied into
# the server's pkglibdir, extension\ into its extension directory and deps\ next to postgres.exe
# (never replacing the server's own files), preloaded when it has to be, then CREATE EXTENSION and
# a query that uses it. PROJ_DATA points at a package's share\proj, as Flock sets it.
# Usage: scripts/windows/smoke-pg-extension.ps1 -Extension <name> -Postgres <dir> -Archive <zip> [-Required <zip>,...]
param(
    [Parameter(Mandatory)] [string] $Extension,
    [Parameter(Mandatory)] [string] $Postgres,
    [Parameter(Mandatory)] [string] $Archive,
    [string[]] $Required = @()
)
$ErrorActionPreference = 'Stop'
Remove-Item Env:PROJ_LIB, Env:PROJ_DATA -ErrorAction SilentlyContinue
$summary = if ($env:GITHUB_STEP_SUMMARY) { $env:GITHUB_STEP_SUMMARY } else { $null }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
$script:failed = 0
function Report($line) { Write-Output $line; if ($summary) { Add-Content $summary $line } }

$pg = (Resolve-Path $Postgres).Path
$bin = Join-Path $pg 'bin'
$lib = (Get-ChildItem $pg -Recurse -Filter 'plpgsql.dll' | Select-Object -First 1).DirectoryName
$ext = (Get-ChildItem $pg -Recurse -Filter 'plpgsql.control' | Select-Object -First 1).DirectoryName

function Install-Package($zip, $name) {
    $dir = Join-Path $tmp $name
    Expand-Archive $zip $dir
    foreach ($pair in @(@('lib', $lib), @('extension', $ext), @('deps', $bin))) {
        $from = Join-Path $dir $pair[0]
        if (-not (Test-Path $from)) { continue }
        foreach ($f in Get-ChildItem $from -File) {
            $to = Join-Path $pair[1] $f.Name
            if (Test-Path $to) { Report "  (kept the server's $($f.Name))"; continue }
            Copy-Item $f.FullName $to
        }
    }
    # PROJ would look for share\proj next to bin\, where its DLL was copied: Flock starts the
    # server with PROJ_DATA on the package's own share\proj instead.
    $proj = Join-Path $dir 'share/proj'
    if (Test-Path $proj) { $env:PROJ_DATA = $proj }
}
Install-Package $Archive $Extension
$i = 0
foreach ($r in $Required) { Install-Package $r "required$i"; $i++ }
Report "### ${Extension}: $(Split-Path $Archive -Leaf)"

$data = Join-Path $tmp 'data'
& (Join-Path $bin 'initdb.exe') -D $data -U postgres --auth=trust -E UTF8 --locale=C | Out-Null
$settings = '-p 54329 -c listen_addresses=127.0.0.1'
if ($Extension -eq 'timescaledb') { $settings += ' -c shared_preload_libraries=timescaledb -c timescaledb.telemetry_level=off' }
# Through pg_ctl: the runner is an administrator, and postgres.exe refuses to run as one.
$ctl = Start-Process -FilePath (Join-Path $bin 'pg_ctl.exe') -PassThru -NoNewWindow `
    -ArgumentList 'start', '-w', '-t', '60', '-D', $data, '-l', "$tmp/server.log", '-o', "`"$settings`"" `
    -RedirectStandardOutput "$tmp/pg_ctl.out" -RedirectStandardError "$tmp/pg_ctl.err"
if (-not $ctl.WaitForExit(90000) -or $ctl.ExitCode) {
    Get-Content "$tmp/server.log", "$tmp/pg_ctl.err" -ErrorAction SilentlyContinue
    throw 'postgres did not start'
}

function Check($name, $sql, $want) {
    $got = (& (Join-Path $bin 'psql.exe') -X -h 127.0.0.1 -p 54329 -U postgres -v ON_ERROR_STOP=1 -At -c $sql 2>&1) -join ' '
    if ($LASTEXITCODE -eq 0 -and $got.Contains($want)) { Report "✓ ${name}: $($got.Substring([Math]::Max(0, $got.Length - 120)))" }
    else { Report "✗ ${name}: $got"; $script:failed++ }
}

switch ($Extension) {
    'pgvector' {
        Check 'CREATE EXTENSION vector' "CREATE EXTENSION vector; SELECT extversion FROM pg_extension WHERE extname = 'vector'" '.'
        Check 'distance' "SELECT '[1,2,3]'::vector <-> '[3,2,1]'" '2.828'
        Check 'HNSW index' "CREATE TABLE items (embedding vector(3)); INSERT INTO items SELECT ARRAY[random(), random(), random()] FROM generate_series(1, 200); CREATE INDEX ON items USING hnsw (embedding vector_l2_ops); SELECT count(*) FROM (SELECT 1 FROM items ORDER BY embedding <-> '[0.5,0.5,0.5]' LIMIT 5) t" '5'
    }
    'postgis' {
        Check 'CREATE EXTENSION postgis' 'CREATE EXTENSION postgis; SELECT postgis_full_version()' 'PROJ='
        Check 'ST_Transform (proj.db)' 'SELECT ST_AsText(ST_Transform(ST_SetSRID(ST_MakePoint(14.42, 50.08), 4326), 3857))' 'POINT(1605227'
        Check 'postgis_topology' 'CREATE EXTENSION postgis_topology; SELECT count(*) FROM topology.topology' '0'
    }
    'pgrouting' {
        Check 'CREATE EXTENSION pgrouting' 'CREATE EXTENSION postgis; CREATE EXTENSION pgrouting; SELECT pgr_version()' '.'
        Check 'pgr_dijkstra' "CREATE TABLE edges (id int, source int, target int, cost float); INSERT INTO edges VALUES (1,1,2,1),(2,2,3,1),(3,1,3,5); SELECT max(agg_cost) FROM pgr_dijkstra('SELECT id, source, target, cost FROM edges', 1, 3, false)" '2'
    }
    'timescaledb' {
        Check 'CREATE EXTENSION timescaledb' "CREATE EXTENSION timescaledb; SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'" '.'
        Check 'hypertable + compression (TSL)' "CREATE TABLE m (t timestamptz NOT NULL, v float); SELECT create_hypertable('m', 't'); INSERT INTO m SELECT t, random() FROM generate_series(now() - interval '3 days', now(), interval '1 minute') t; ALTER TABLE m SET (timescaledb.compress); SELECT count(compress_chunk(c)) > 0 FROM show_chunks('m') c" 't'
        Check 'telemetry off' 'SHOW timescaledb.telemetry_level' 'off'
    }
    default { Report "✗ no smoke test for $Extension"; $script:failed++ }
}
& (Join-Path $bin 'pg_ctl.exe') stop -D $data -m fast | Out-Null
if ($script:failed) { Get-Content "$tmp/server.log" -Tail 30; exit 1 }
