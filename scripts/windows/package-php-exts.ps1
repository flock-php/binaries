# Assembles the Windows extension pack of one PHP minor and tests it: every DLL has to load into
# the official thread-safe x64 PHP build of that minor (checked against windows.php.net's SHA-256),
# and opentelemetry's hook() has to fire (scripts/smoke-opentelemetry.php).
#   -Exts     the build jobs' artifacts, one directory ext-<name>-<minor> per extension
#   -MongoDB  version of the MongoDB maintainers' own DLLs to add (PHP 8.1+), checked against
#             GitHub's SHA-256 of the release asset
# $env:EXTENSIONS lists the extensions built from source (JSON: name, repo, ref), as computed by the
# workflow's config job from versions.json. Results go to stdout and $GITHUB_STEP_SUMMARY.
# Usage: scripts/windows/package-php-exts.ps1 -Minor 8.4 -Exts exts -Out pkg [-MongoDB 2.5.5]
param(
    [Parameter(Mandatory)] [string] $Minor,
    [Parameter(Mandatory)] [string] $Exts,
    [Parameter(Mandatory)] [string] $Out,
    [string] $MongoDB
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Resolve-Path (Join-Path $PSScriptRoot '../..')
$versions = Get-Content (Join-Path $root 'versions.json') -Raw | ConvertFrom-Json
$extensions = @($env:EXTENSIONS | ConvertFrom-Json)
$work = Join-Path $env:RUNNER_TEMP 'php-exts'
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory $work | Out-Null
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
$Out = (New-Item -ItemType Directory $Out).FullName
$extDir = New-Item -ItemType Directory (Join-Path $Out 'ext')
$licenses = New-Item -ItemType Directory (Join-Path $Out 'LICENSES')

function Get-RepoLicense([string] $repo, [string] $ref, [string] $name) {
    $url = gh api "repos/$repo/license?ref=$ref" --jq .download_url
    if ($LASTEXITCODE -or -not $url) { throw "no license file in $repo at $ref" }
    Invoke-WebRequest $url -OutFile (Join-Path $licenses "$name.txt")
}

# The official PHP build the pack is for (and tested against); for a minor without a release
# yet, its release candidate from qa/.
$base = 'https://downloads.php.net/~windows/releases'
$entry = (Invoke-RestMethod "$base/releases.json").$Minor
if (-not $entry) {
    $base = 'https://downloads.php.net/~windows/qa'
    $entry = (Invoke-RestMethod "$base/releases.json").$Minor
    if ($entry -and $entry.version -notmatch '^\d+\.\d+\.0RC\d+$') { $entry = $null }
}
$key = $entry.PSObject.Properties.Name | Where-Object { $_ -match '^ts-v[sc]\d+-x64$' } | Select-Object -First 1
if (-not $key) { throw "no thread-safe x64 build of PHP $Minor in releases.json" }
$vs = $key -replace '^ts-(v[sc]\d+)-x64$', '$1'
$phpZip = Join-Path $work 'php.zip'
Invoke-WebRequest "$base/$($entry.$key.zip.path)" -OutFile $phpZip
if ((Get-FileHash $phpZip -Algorithm SHA256).Hash -ne $entry.$key.zip.sha256) { throw "PHP $($entry.version): SHA-256 mismatch" }
$php = Join-Path $work 'php'
Expand-Archive $phpZip -DestinationPath $php
Write-Output "PHP $($entry.version) ($key)"

# Extensions built from source: php_<name>-<ref>-<minor>-ts-<vs>-x86_64.dll in the builder's
# zips becomes ext/php_<name>.dll; the libraries next to it go next to php.exe.
$built = [ordered]@{}
foreach ($e in $extensions) {
    $dir = Join-Path $Exts "ext-$($e.name)-$Minor"
    if (-not (Test-Path $dir)) { throw "no build artifact for $($e.name)" }
    Get-ChildItem $dir -Filter *.zip -Recurse | ForEach-Object {
        Expand-Archive $_.FullName -DestinationPath (Join-Path $_.DirectoryName 'unpacked') -Force
    }
    $dll = Get-ChildItem $dir -Recurse -Filter "php_$($e.name)*.dll" | Select-Object -First 1
    if (-not $dll) { throw "no php_$($e.name) DLL in the $($e.name) artifact" }
    Copy-Item $dll.FullName (Join-Path $extDir "php_$($e.name).dll")
    Get-ChildItem $dir -Recurse -Filter *.dll | Where-Object Name -notlike 'php_*' | Copy-Item -Destination $Out -Force
    Get-RepoLicense $e.repo $e.ref $e.name
    $built[$e.name] = $e.ref
}
if ($built.Contains('imagick')) { Get-RepoLicense 'ImageMagick/ImageMagick' 'main' 'imagemagick' }

# MongoDB: the maintainers publish DLLs for the PHP versions their releases support.
if ($MongoDB -and [version]$Minor -ge [version]'8.1') {
    $name = "php_mongodb-$MongoDB-$Minor-ts-$vs-x86_64.zip"
    $digest = gh api "repos/mongodb/mongo-php-driver/releases/tags/$MongoDB" --jq ".assets[] | select(.name == `"$name`") | .digest"
    if (-not $digest) { throw "mongodb $MongoDB has no $name" }
    $zip = Join-Path $work $name
    Invoke-WebRequest "https://github.com/mongodb/mongo-php-driver/releases/download/$MongoDB/$name" -OutFile $zip
    $sum = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ("sha256:$sum" -ne $digest) { throw "$name`: SHA-256 $sum, expected $digest" }
    Expand-Archive $zip -DestinationPath (Join-Path $work 'mongodb')
    # Named like the zip: php_mongodb-<version>-<minor>-ts-<vs>-x86_64.dll.
    $dll = Get-ChildItem (Join-Path $work 'mongodb') -Recurse -Filter 'php_mongodb*.dll' | Select-Object -First 1
    if (-not $dll) { throw "no php_mongodb DLL in $name" }
    Copy-Item $dll.FullName (Join-Path $extDir 'php_mongodb.dll')
    Get-RepoLicense 'mongodb/mongo-php-driver' $MongoDB 'mongodb'
    $built['mongodb'] = $MongoDB
}

# Load every DLL into the official build, as Flock will install it (ext\ and next to php.exe).
Copy-Item (Join-Path $extDir '*') (Join-Path $php 'ext') -Force
Get-ChildItem $Out -Filter *.dll | Copy-Item -Destination $php -Force
$phpExe = Join-Path $php 'php.exe'
$rows = @("### php-exts $Minor (PHP $($entry.version), $vs)", '', '| extension | version | result |', '|---|---|---|')
$failed = $false
foreach ($ext in $built.Keys) {
    $code = "echo phpversion('$ext');"
    if ($ext -eq 'imagick') {
        $code += " `$i = new Imagick(); `$i->newImage(8, 8, 'red'); `$i->setImageFormat('png'); echo ' png:', strlen(`$i->getImageBlob()), ' bytes';"
    }
    $flags = @('-n', '-d', "extension_dir=$(Join-Path $php 'ext')")
    # phpredis may be built with igbinary support, which then has to be loaded first.
    if ($ext -eq 'redis' -and $built.Contains('igbinary')) { $flags += @('-d', 'extension=igbinary') }
    $flags += @('-d', $(if ($ext -eq 'xdebug') { 'zend_extension=xdebug' } else { "extension=$ext" }))
    $result = & $phpExe @flags -r $code 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $result.Trim() -and $result -notmatch 'Warning|Fatal|Unable') {
        $rows += "| $ext | $($built[$ext]) | ✓ $($result.Trim()) |"
    } else {
        $rows += "| $ext | $($built[$ext]) | ✗ $($result.Trim() -replace '\r?\n', ' ') |"; $failed = $true
    }
}
# opentelemetry is only there for its hook(): loading is not enough, the hooks have to fire.
if ($built.Contains('opentelemetry')) {
    $probe = Join-Path $root 'scripts/smoke-opentelemetry.php'
    $result = & $phpExe -n -d "extension_dir=$(Join-Path $php 'ext')" -d extension=opentelemetry $probe 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $result -like 'hook ok *') {
        $rows += "| opentelemetry hook() | $($built['opentelemetry']) | ✓ $($result.Trim()) |"
    } else {
        $rows += "| opentelemetry hook() | $($built['opentelemetry']) | ✗ $($result.Trim() -replace '\r?\n', ' ') |"; $failed = $true
    }
}
$rows | Write-Output
if ($env:GITHUB_STEP_SUMMARY) { $rows | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ($failed) { exit 1 }

[ordered]@{
    package    = 'php-exts'
    version    = $Minor
    build      = $versions.php.windows.extensions.build
    platform   = 'windows-x64'
    php_build  = $key
    tested_with = $entry.version
    extensions = $built
    built      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    commit     = $env:GITHUB_SHA
} | ConvertTo-Json | Set-Content (Join-Path $Out 'flock-package.json') -Encoding utf8
