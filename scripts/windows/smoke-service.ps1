# Smoke-tests a service package on Windows the way Flock runs it: unpack (dropping a single
# top-level folder, as Flock does), initialise a data directory, start on 127.0.0.1, talk to it
# with its own client, shut down. With $env:SIGNER_WINDOWS set, the main executable must carry a valid
# Authenticode signature whose subject matches that regex (the vendor's, for mirrored packages).
# Valkey has its own, more thorough test: scripts/smoke-valkey.ps1.
# Usage: scripts/windows/smoke-service.ps1 -Package <name> -Archive <zip>
param(
    [Parameter(Mandatory)] [string] $Package,
    [Parameter(Mandatory)] [string] $Archive
)
$ErrorActionPreference = 'Stop'

$tmp = Join-Path $env:RUNNER_TEMP "smoke-$Package"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
$D = Join-Path $tmp 'pkg'
# Forward slashes: MySQL, MariaDB and MongoDB all accept them, and they need no escaping.
$data = (Join-Path $tmp 'data') -replace '\\', '/'
New-Item -ItemType Directory -Force $D, $data | Out-Null
$results = [System.Collections.Generic.List[string]]::new()
$failed = $false

function Check([string] $name, [scriptblock] $test) {
    try { $r = & $test; $results.Add("| $name | ✓ $r |") }
    catch { $results.Add("| $name | ✗ $($_.Exception.Message) |"); $script:failed = $true }
}
# Arguments go in as one array: passed loose to a PowerShell function, -h127.0.0.1 and
# --version would be taken apart as PowerShell's own parameter syntax.
function Invoke-Native([string] $exe, [string[]] $arguments) {
    $out = & $exe @arguments 2>&1 | Out-String
    if ($LASTEXITCODE) { throw "exit $LASTEXITCODE`: $($out.Trim() | Select-Object -Last 1)" }
    $out.Trim()
}
function Wait-Port([int] $port, $proc, [string] $log) {
    for ($i = 0; $i -lt 300; $i++) {
        $c = [System.Net.Sockets.TcpClient]::new()
        try { $c.Connect('127.0.0.1', $port); return } catch { Start-Sleep -Milliseconds 200 } finally { $c.Dispose() }
        if ($proc.HasExited) { break }
    }
    $tail = if (Test-Path $log) { (Get-Content $log -Tail 5) -join ' / ' } else { '' }
    throw "nothing listening on $port`: $tail"
}
function Wait-Http([string] $url) {
    for ($i = 0; $i -lt 300; $i++) {
        try { return Invoke-RestMethod $url -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 200 }
    }
    throw "$url did not answer"
}
function Start-Server([string] $exe, [string[]] $arguments) {
    Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput "$tmp/out.log" -RedirectStandardError "$tmp/err.log"
}
function Stop-Server($proc) {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    $proc.WaitForExit(10000) | Out-Null
}

tar -xf $Archive -C $D
if ($LASTEXITCODE) { throw "could not unpack $Archive" }
$entries = @(Get-ChildItem $D)
if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { $D = $entries[0].FullName }
$results.Add("| package | $(Split-Path -Leaf $Archive) |")

if ($env:SIGNER_WINDOWS) {
    $main = @{ mysql = 'bin/mysqld.exe'; mongodb = 'bin/mongod.exe'; node = 'node.exe' }[$Package]
    Check "Authenticode signature of $main" {
        $sig = Get-AuthenticodeSignature (Join-Path $D $main)
        if ($sig.Status -ne 'Valid') { throw "status $($sig.Status)" }
        if ($sig.SignerCertificate.Subject -notmatch $env:SIGNER_WINDOWS) { throw "signed by $($sig.SignerCertificate.Subject)" }
        $sig.SignerCertificate.Subject
    }
}

switch ($Package) {
    'postgres' {
        $bin = Join-Path $D 'bin'
        Check 'initdb' { Invoke-Native "$bin/initdb.exe" @('-D', $data, '-U', 'postgres', '--auth=trust', '-E', 'UTF8', '--locale=C') | Out-Null }
        $p = Start-Server "$bin/postgres.exe" @('-D', $data, '-p', '54329', '-c', 'listen_addresses=127.0.0.1')
        Check 'start' { Wait-Port 54329 $p "$tmp/err.log" }
        $psql = @('-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At')
        Check 'query' { Invoke-Native "$bin/psql.exe" ($psql + @('-c', 'select version()')) }
        Check 'contrib extensions (pgcrypto, pg_trgm, hstore, citext)' {
            Invoke-Native "$bin/psql.exe" ($psql + @('-c', 'create extension pgcrypto; create extension pg_trgm; create extension hstore; create extension citext',
                '-c', "select encode(digest('flock', 'sha256'), 'hex'), gen_random_uuid(), similarity('flock', 'block'), 'a=>1'::hstore, 'A'::citext = 'a'")) | Out-Null
        }
        Check 'createdb' { Invoke-Native "$bin/createdb.exe" @('-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', 'flock') }
        Check 'pg_dump | pg_restore' {
            Invoke-Native "$bin/pg_dump.exe" @('-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', '-Fc', '-f', "$tmp/dump", 'postgres')
            Invoke-Native "$bin/pg_restore.exe" @('-l', "$tmp/dump") | Out-Null
        }
        Check 'pg_ctl stop' { Invoke-Native "$bin/pg_ctl.exe" @('stop', '-D', $data, '-m', 'fast') | Out-Null }
    }
    { $_ -in 'mysql', 'mariadb' } {
        $bin = Join-Path $D 'bin'
        if ($Package -eq 'mariadb') {
            # mariadb-install-db creates the data directory itself.
            Remove-Item -Recurse -Force $data
            Check 'install-db' {
                Invoke-Native "$bin/mariadb-install-db.exe" @("--datadir=$data") | Out-Null
                if (-not (Test-Path "$data/mysql")) { throw 'no system tables in the data directory' }
            }
            $server = "$bin/mariadbd.exe"; $client = "$bin/mariadb.exe"; $admin = "$bin/mariadb-admin.exe"
            $serverArgs = @('--no-defaults', "--basedir=$D", "--datadir=$data")
        } else {
            Check 'initialize' { Invoke-Native "$bin/mysqld.exe" @('--no-defaults', '--initialize-insecure', "--basedir=$D", "--datadir=$data") | Out-Null }
            $server = "$bin/mysqld.exe"; $client = "$bin/mysql.exe"; $admin = "$bin/mysqladmin.exe"
            $serverArgs = @('--no-defaults', "--basedir=$D", "--datadir=$data", '--mysqlx=OFF')
        }
        $p = Start-Server $server ($serverArgs + @('--port=33069', '--bind-address=127.0.0.1'))
        Check 'start' { Wait-Port 33069 $p "$tmp/err.log" }
        $sql = @('--no-defaults', '-h127.0.0.1', '-P33069', '-uroot')
        Check 'query' {
            Invoke-Native $client ($sql + @('-e', 'create database flock; create table flock.t (id int primary key, v json) engine=innodb; insert into flock.t values (1, json_object(''a'', 1))')) | Out-Null
            Invoke-Native $client ($sql + @('-N', '-e', 'select version()'))
        }
        Check 'shutdown' { Invoke-Native $admin ($sql + @('shutdown')) | Out-Null; if (-not $p.WaitForExit(30000)) { throw 'did not exit' } }
    }
    'mongodb' {
        Check 'version' { ((Invoke-Native "$D/bin/mongod.exe" @('--version')) -split "
")[0] }
        $p = Start-Server "$D/bin/mongod.exe" @('--dbpath', $data, '--port', '27029', '--bind_ip', '127.0.0.1')
        Check 'accepts connections' { Wait-Port 27029 $p "$tmp/out.log" }
        Stop-Server $p
    }
    'meilisearch' {
        $p = Start-Server "$D/meilisearch.exe" @('--db-path', "$data/data.ms", '--http-addr', '127.0.0.1:7709', '--env', 'development', '--no-analytics')
        Check 'health' { Wait-Http 'http://127.0.0.1:7709/health' | Out-Null; (Invoke-RestMethod 'http://127.0.0.1:7709/version').pkgVersion }
        Check 'index a document' {
            Invoke-RestMethod -Method Post 'http://127.0.0.1:7709/indexes/flock/documents' -ContentType 'application/json' -Body '[{"id":1,"name":"flock"}]' | Out-Null
        }
        Stop-Server $p
    }
    'rustfs' {
        $p = Start-Server "$D/rustfs.exe" @('server', '--address', '127.0.0.1:9109', '--access-key', 'rustfsadmin', '--secret-key', 'rustfsadmin', $data)
        Check 'listens' { Wait-Port 9109 $p "$tmp/err.log" }
        Stop-Server $p
    }
    'node' {
        Check 'node' { Invoke-Native "$D/node.exe" @('-e', 'console.log(process.version, require(''crypto'').createHash(''sha256'').update(''x'').digest(''hex'').length)') }
        Check 'npm' { Invoke-Native "$D/npm.cmd" @('--version') }
    }
    default { $results.Add("| $Package | ✗ no smoke test |"); $failed = $true }
}

$table = @("### $Package", '', '| check | result |', '|---|---|') + $results
$table | Write-Output
if ($env:GITHUB_STEP_SUMMARY) { $table | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ($failed) { exit 1 }
