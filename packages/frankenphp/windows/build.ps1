# Builds FrankenPHP for Windows against the official thread-safe PHP build of one PHP minor,
# following FrankenPHP's own Windows release workflow (.github/workflows/windows.yaml):
# Go + clang (from Visual Studio), vcpkg (brotli, pthreads), e-dant/watcher, PHP TS + devel pack.
# The result is a directory with frankenphp.exe next to the complete official PHP TS build.
#
# Usage: packages/frankenphp/windows/build.ps1 -Php 8.4 -FrankenPHP v1.13.0 -Out out
#   needs: go (1.26+) on PATH, GH_TOKEN for downloading watcher with gh
param(
    [Parameter(Mandatory)] [string] $Php,
    [Parameter(Mandatory)] [string] $FrankenPHP,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$work = Join-Path (Get-Location) 'frankenphp-work'
New-Item -ItemType Directory -Force $work | Out-Null
$Out = (New-Item -ItemType Directory -Force $Out).FullName

# PHP: releases.json instead of the directory listing (403 since October 2026).
$releases = Invoke-RestMethod https://windows.php.net/downloads/releases/releases.json
$entry = $releases.$Php
$key = $entry.PSObject.Properties.Name | Where-Object { $_ -match '^ts-v[sc]\d+-x64$' } | Select-Object -First 1
if (-not $key) { throw "no thread-safe x64 build of PHP $Php in releases.json" }
$version = $entry.version
Write-Output "PHP $version ($key)"
foreach ($pack in 'zip', 'devel_pack') {
    $file = $entry.$key.$pack.path
    Invoke-WebRequest "https://downloads.php.net/~windows/releases/$file" -OutFile (Join-Path $work "$pack.zip")
}
Expand-Archive (Join-Path $work 'zip.zip') -DestinationPath $Out -Force
Expand-Archive (Join-Path $work 'devel_pack.zip') -DestinationPath (Join-Path $work 'devel') -Force
$phpDevel = (Get-ChildItem (Join-Path $work 'devel') -Directory | Select-Object -First 1).FullName

# FrankenPHP source and its native dependencies.
$src = Join-Path $work 'frankenphp'
if (-not (Test-Path $src)) {
    git -c advice.detachedHead=false clone -q --depth 1 --branch $FrankenPHP https://github.com/php/frankenphp.git $src
}
Push-Location $src
& (Join-Path $env:VCPKG_INSTALLATION_ROOT 'vcpkg.exe') install
if ($LASTEXITCODE) { throw "vcpkg install failed" }
Pop-Location
$vcpkgRoot = Join-Path $src 'vcpkg_installed\x64-windows'

$watcherRoot = Join-Path $work 'watcher'
if (-not (Test-Path $watcherRoot)) {
    $tag = gh release list --repo e-dant/watcher --limit 1 --exclude-drafts --exclude-pre-releases --json tagName --jq '.[0].tagName'
    gh release download $tag --repo e-dant/watcher --pattern '*x86_64-pc-windows-msvc.tar' -O (Join-Path $work 'watcher.tar')
    tar -xf (Join-Path $work 'watcher.tar') -C $work
    Rename-Item (Join-Path $work 'x86_64-pc-windows-msvc') 'watcher'
}

# Toolchain: Visual Studio's clang, as upstream.
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
$env:PATH = "$vs\VC\Tools\Llvm\bin;$vcpkgRoot\bin;$watcherRoot;$Out;$env:PATH"
$env:CC = 'clang'
$env:CXX = 'clang++'
$env:CGO_ENABLED = '1'
$env:GOTOOLCHAIN = 'local'
$fpVersion = $FrankenPHP.TrimStart('v')
$env:CGO_CFLAGS = "-DFRANKENPHP_VERSION=$fpVersion -I$vcpkgRoot\include -I$watcherRoot -I$phpDevel\include -I$phpDevel\include\main -I$phpDevel\include\TSRM -I$phpDevel\include\Zend -I$phpDevel\include\ext"
$env:CGO_LDFLAGS = "-L$vcpkgRoot\lib -lbrotlienc -L$watcherRoot -llibwatcher-c -L$Out -L$phpDevel\lib -lphp8ts -lphp8embed"

Push-Location (Join-Path $src 'caddy\frankenphp')
$customVersion = "FrankenPHP $fpVersion PHP $version Caddy"
go build -tags 'nobadger,nomysql,nopgx' `
    -ldflags "-extldflags=-fuse-ld=lld -X 'github.com/caddyserver/caddy/v2.CustomVersion=$customVersion' -X 'github.com/caddyserver/caddy/v2.CustomBinaryName=frankenphp' -X 'github.com/caddyserver/caddy/v2/modules/caddyhttp.ServerHeader=FrankenPHP Caddy'"
if ($LASTEXITCODE) { throw "go build failed" }
Copy-Item frankenphp.exe $Out -Force
Pop-Location

Copy-Item (Join-Path $watcherRoot 'libwatcher-c.dll') $Out -Force
foreach ($dll in 'brotlienc', 'brotlidec', 'brotlicommon', 'pthreadVC3') {
    Copy-Item (Join-Path $vcpkgRoot "bin\$dll.dll") $Out -Force
}
& (Join-Path $Out 'frankenphp.exe') version
