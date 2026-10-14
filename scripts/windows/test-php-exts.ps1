# Installs the official thread-safe (TS) x64 build of a PHP minor and loads every extension DLL found under
# -Exts into it (one directory per extension, as downloaded from the build jobs' artifacts).
# MongoDB is not built: its maintainers publish signed Windows DLLs, which are fetched here.
# Results go to stdout and $GITHUB_STEP_SUMMARY; exits 1 if any extension fails to load.
# Usage: scripts/windows/test-php-exts.ps1 -Php 8.5 -Exts exts [-MongoDB 2.5.4]
param(
    [Parameter(Mandatory)] [string] $Php,
    [Parameter(Mandatory)] [string] $Exts,
    [string] $MongoDB = '2.5.4'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# releases.json lists the newest build of every minor (including 7.4 and 8.0); the files of
# minors without current releases live under archives/. Directory listings are gone (403).
$releases = Invoke-RestMethod https://windows.php.net/downloads/releases/releases.json
$entry = $releases.$Php
$key = $entry.PSObject.Properties.Name | Where-Object { $_ -match '^ts-v[sc]\d+-x64$' } | Select-Object -First 1
$zip = $entry.$key.zip.path
$vs = $key -replace '^ts-(v[sc]\d+)-x64$', '$1'
try {
    Invoke-WebRequest "https://downloads.php.net/~windows/releases/$zip" -OutFile php.zip
} catch {
    Invoke-WebRequest "https://downloads.php.net/~windows/releases/archives/$zip" -OutFile php.zip
}
Expand-Archive php.zip -DestinationPath php -Force
& ./php/php.exe -n -v

# MongoDB's official DLL (only published for the PHP versions it supports).
try {
    $url = "https://github.com/mongodb/mongo-php-driver/releases/download/$MongoDB/php_mongodb-$MongoDB-$Php-ts-$vs-x86_64.zip"
    $dir = New-Item -ItemType Directory -Force (Join-Path $Exts 'ext-mongodb')
    Invoke-WebRequest $url -OutFile (Join-Path $dir 'mongodb.zip')
} catch {
    Write-Output "no official MongoDB $MongoDB DLL for PHP $Php ($vs)"
}

Get-ChildItem $Exts -Filter *.zip -Recurse | ForEach-Object {
    Expand-Archive $_.FullName -DestinationPath (Join-Path $_.DirectoryName 'unpacked') -Force
}

$rows = @("| extension | PHP $Php |", '|---|---|')
$failed = $false
foreach ($dir in Get-ChildItem $Exts -Directory -Filter 'ext-*') {
    $ext = ($dir.Name -split '-')[1]
    # Builder output is named e.g. php_pcov-v1.0.12-8.5-ts-vs17-x86_64.dll; PHP wants php_pcov.dll.
    $dll = Get-ChildItem $dir.FullName -Recurse -Filter "php_$ext*.dll" | Select-Object -First 1
    if (-not $dll) { $rows += "| $ext | FAIL: no php_$ext DLL in artifact |"; $failed = $true; continue }
    Copy-Item $dll.FullName "php/ext/php_$ext.dll" -Force
    # Dependency DLLs (e.g. ImageMagick's CORE_RL_*.dll) must sit next to php.exe.
    Get-ChildItem $dir.FullName -Recurse -Filter *.dll | Where-Object Name -notlike 'php_*' |
        Copy-Item -Destination php/ -Force

    $code = "echo phpversion('$ext');"
    if ($ext -eq 'imagick') {
        $code += " `$i = new Imagick(); `$i->newImage(8, 8, 'red'); `$i->setImageFormat('png'); echo ' png:', strlen(`$i->getImageBlob()), ' bytes, formats:', count(Imagick::queryFormats());"
    }
    if ($ext -eq 'redis') {
        # phpredis is built with igbinary support and needs it loaded first.
        $pre = if (Test-Path php/ext/php_igbinary.dll) { @('-d', 'extension=igbinary') } else { @() }
    } else { $pre = @() }
    $out = & ./php/php.exe -n -d extension_dir=php/ext @pre -d "extension=$ext" -r $code 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $out.Trim() -and $out -notmatch 'Warning|Fatal') {
        $rows += "| $ext | ok: $($out.Trim()) |"
    } else {
        $rows += "| $ext | FAIL: $($out.Trim() -replace '\r?\n', ' ') |"; $failed = $true
    }
}
$rows | Write-Output
if ($env:GITHUB_STEP_SUMMARY) { $rows | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ($failed) { exit 1 }
