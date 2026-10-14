# Smoke-tests a Windows Valkey package the way Flock uses it: start on a port with a data dir,
# read/write, fork-based persistence (BGSAVE, AOF rewrite), a hard kill (how Flock's supervisor
# stops processes) and a restart that must find the data again.
# Usage: scripts/smoke-valkey.ps1 -Dir <package dir>
param([Parameter(Mandatory)] [string] $Dir)
$ErrorActionPreference = 'Stop'

$server = Join-Path $Dir 'valkey-server.exe'
$cli = Join-Path $Dir 'valkey-cli.exe'
# Forward slashes: the MSYS runtime accepts C:/… paths but not every tool copes with backslashes.
$data = (Join-Path $env:RUNNER_TEMP 'valkey-data') -replace '\\', '/'
$port = 6390
New-Item -ItemType Directory -Force $data | Out-Null
$results = [System.Collections.Generic.List[string]]::new()

function Start-Valkey {
    $p = Start-Process -FilePath $server -PassThru -NoNewWindow `
        -ArgumentList '--port', $port, '--bind', '127.0.0.1', '--dir', $data, '--appendonly', 'yes'
    for ($i = 0; $i -lt 50; $i++) {
        if ((& $cli -p $port PING 2>$null) -eq 'PONG') { return $p }
        Start-Sleep -Milliseconds 200
    }
    throw 'valkey-server did not answer PING within 10s'
}
function Invoke-Cli { & $cli -p $port @args }
function Wait-Persistence([string] $field) {
    for ($i = 0; $i -lt 100; $i++) {
        $info = (Invoke-Cli INFO persistence) -join "`n"
        if ($info -match "${field}:0") { return $info }
        Start-Sleep -Milliseconds 200
    }
    throw "$field did not finish"
}
function Check([string] $name, [scriptblock] $test) {
    try { & $test; $results.Add("| $name | ✓ |") }
    catch { $results.Add("| $name | ✗ $($_.Exception.Message) |"); $script:failed = $true }
}
$failed = $false

$p = Start-Valkey
Check 'version' { $v = & $server --version; if (-not $v) { throw 'no output' }; $results.Add("| version | $v |") }
Check 'SET/GET' { Invoke-Cli SET flock works | Out-Null; if ((Invoke-Cli GET flock) -ne 'works') { throw 'GET mismatch' } }
Check 'many keys' { 1..2000 | ForEach-Object { "SET key:$_ $_" } | & $cli -p $port | Out-Null; if ([int](Invoke-Cli DBSIZE) -lt 2001) { throw 'DBSIZE too small' } }
Check 'BGSAVE (fork)' {
    Invoke-Cli BGSAVE | Out-Null
    $info = Wait-Persistence 'rdb_bgsave_in_progress'
    if ($info -notmatch 'rdb_last_bgsave_status:ok') { throw 'bgsave failed' }
}
Check 'BGREWRITEAOF (fork)' {
    Invoke-Cli BGREWRITEAOF | Out-Null
    $info = Wait-Persistence 'aof_rewrite_in_progress'
    if ($info -notmatch 'aof_last_bgrewrite_status:ok') { throw 'aof rewrite failed' }
}
Check 'benchmark' { & (Join-Path $Dir 'valkey-benchmark.exe') -p $port -n 20000 -q -t set,get,lpush,lpop | Out-Null; if ($LASTEXITCODE) { throw "exit $LASTEXITCODE" } }

Check 'hard kill + restart keeps data' {
    Stop-Process -Id $p.Id -Force
    Start-Sleep -Seconds 1
    $script:p = Start-Valkey
    if ((Invoke-Cli GET flock) -ne 'works') { throw 'data lost after restart' }
}
Check 'SHUTDOWN' {
    Invoke-Cli SHUTDOWN 2>$null | Out-Null
    if (-not $p.WaitForExit(10000)) { throw 'did not exit' }
}

$table = @('| check | result |', '|---|---|') + $results
$table | Write-Output
if ($env:GITHUB_STEP_SUMMARY) { $table | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ($failed) { exit 1 }
