# Smoke-tests a Windows FrankenPHP directory (frankenphp.exe next to the official PHP TS build):
#   - frankenphp runs and embeds a thread-safe PHP of the expected minor
#   - common extension DLLs from ext\ load into the embedded PHP (through an ini file)
#   - a classic request and worker mode (frankenphp_handle_request keeps state between requests)
# Usage: scripts/windows/smoke-frankenphp.ps1 -Dir out -Php 8.4
param([Parameter(Mandatory)] [string] $Dir, [Parameter(Mandatory)] [string] $Php)
$ErrorActionPreference = 'Stop'
$Dir = (Resolve-Path $Dir).Path
$fp = Join-Path $Dir 'frankenphp.exe'
$work = Join-Path $env:RUNNER_TEMP 'fp-smoke'
New-Item -ItemType Directory -Force "$work\public", "$work\worker", "$work\ini" | Out-Null
$rows = [System.Collections.Generic.List[string]]::new()
$failed = $false
function Report([bool] $ok, [string] $text) {
    $rows.Add($(if ($ok) { "ok: $text" } else { "FAIL: $text" }))
    if (-not $ok) { $script:failed = $true }
}

$rows.Add("### $(& $fp version)")

# Extensions Laravel apps need, shipped as DLLs by the official build.
$exts = 'curl', 'fileinfo', 'gd', 'intl', 'mbstring', 'openssl', 'pdo_mysql', 'pdo_pgsql', 'pdo_sqlite', 'sodium', 'zip'
$ini = @("extension_dir=""$Dir\ext""") + ($exts | ForEach-Object { "extension=$_" })
# opcache is compiled in from PHP 8.5 on; older builds ship it as a DLL.
if (Test-Path "$Dir\ext\php_opcache.dll") { $ini += 'zend_extension=opcache' }
$ini | Set-Content "$work\ini\flock.ini" -Encoding ascii
$env:PHP_INI_SCAN_DIR = "$work\ini"

# Under `frankenphp php-cli`, $argv[0] is frankenphp.exe and $argv[1] the script.
@'
<?php
echo PHP_VERSION, ' ', ZEND_THREAD_SAFE ? 'zts' : 'nts', "\n";
foreach (array_slice($argv, 2) as $e) echo $e, '=', extension_loaded($e) ? 'yes' : 'no', "\n";
echo 'opcache=', extension_loaded('Zend OPcache') ? 'yes' : 'no', "\n";
'@ | Set-Content "$work\info.php" -Encoding ascii
$out = & $fp php-cli "$work\info.php" @exts 2>&1 | ForEach-Object { "$_" }
$warnings = $out | Where-Object { $_ -match 'Warning|Fatal' }
$first = $out | Where-Object { $_ -match '^\d+\.\d+\.\d+ (zts|nts)$' } | Select-Object -First 1
Report ($first -match "^$([regex]::Escape($Php))\.\d+ zts$") "embedded PHP $first"
$missing = $out | Where-Object { $_ -match '=no$' } | ForEach-Object { ($_ -split '=')[0] }
Report (-not $missing -and -not $warnings) "extensions + opcache loaded ($($exts -join ', '))$(if ($missing) { "; missing: $($missing -join ', ')" })$(if ($warnings) { "; $($warnings -join ' ')" })"

'<?php echo "classic ", PHP_VERSION;' | Set-Content "$work\public\index.php" -Encoding ascii
# The worker gets its own root, so it serves every request there.
@'
<?php
$n = 0;
while (frankenphp_handle_request(function () use (&$n) { echo "worker ", ++$n; })) {
    gc_collect_cycles();
}
'@ | Set-Content "$work\worker\index.php" -Encoding ascii

function Invoke-Server([int] $port, [string] $root, [string[]] $extra) {
    $argList = @('php-server', '--listen', "127.0.0.1:$port", '--root', $root) + $extra
    $p = Start-Process -FilePath $fp -ArgumentList $argList -PassThru -NoNewWindow `
        -RedirectStandardError "$work\server-$port.log" -RedirectStandardOutput "$work\server-$port.out"
    $bodies = @()
    for ($i = 0; $i -lt 50; $i++) {
        try { Invoke-WebRequest "http://127.0.0.1:$port/" -UseBasicParsing | Out-Null; break } catch { Start-Sleep -Milliseconds 200 }
    }
    foreach ($i in 1, 2) {
        try { $bodies += (Invoke-WebRequest "http://127.0.0.1:$port/" -UseBasicParsing).Content } catch { $bodies += "error: $($_.Exception.Message)" }
    }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    return $bodies
}

$classic = Invoke-Server 18099 "$work\public" @()
Report ($classic[0] -like "classic $Php.*") "classic request: $($classic[0])"

$worker = Invoke-Server 18100 "$work\worker" @('--worker', "$work\worker\index.php")
$ok = $worker[0] -match '^worker (\d+)$'
$a = if ($ok) { [int]$Matches[1] } else { 0 }
$ok = $ok -and ($worker[1] -match '^worker (\d+)$') -and ([int]$Matches[1] -gt $a)
Report $ok "worker mode keeps state: '$($worker[0])' then '$($worker[1])'"
if (-not $ok) { Get-Content "$work\server-18100.log" -Tail 5 | ForEach-Object { $rows.Add("  $_") } }

$rows | Write-Output
if ($env:GITHUB_STEP_SUMMARY) { $rows | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ($failed) { exit 1 }
