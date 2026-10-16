# Builds FrankenPHP for Windows against the official thread-safe PHP build of one PHP minor,
# following FrankenPHP's own Windows release workflow (.github/workflows/windows.yaml):
# Go + clang (from Visual Studio), vcpkg (brotli, pthreads), e-dant/watcher, PHP TS + devel pack.
# The result is a directory with frankenphp.exe next to the complete official PHP TS build.
#
# Usage: packages/frankenphp/windows/build.ps1 -Version 8.4.26 -FrankenPHP 1.13.0 -Out out
#   -Version  the PHP release, which must be windows.php.net's current build of its minor (only
#             current builds have published checksums)
#   needs: go on PATH (it fetches the version go.mod requires), GH_TOKEN for downloading watcher with gh
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $FrankenPHP,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$work = Join-Path (Get-Location) 'frankenphp-work'
New-Item -ItemType Directory -Force $work | Out-Null
$Out = (New-Item -ItemType Directory -Force $Out).FullName
$Php = ($Version -split '\.')[0..1] -join '.'
$FrankenPHP = $FrankenPHP.TrimStart('v')

# PHP: releases.json instead of the directory listing (403 since October 2026). Both the build
# and its devel pack (headers, import libraries) are checked against its SHA-256.
$releases = Invoke-RestMethod https://downloads.php.net/~windows/releases/releases.json
$entry = $releases.$Php
$key = $entry.PSObject.Properties.Name | Where-Object { $_ -match '^ts-v[sc]\d+-x64$' } | Select-Object -First 1
if (-not $key) { throw "no thread-safe x64 build of PHP $Php in releases.json" }
$version = $entry.version
if ($version -ne $Version) { throw "windows.php.net's current PHP $Php is $version, not $Version" }
Write-Output "PHP $version ($key)"
foreach ($pack in 'zip', 'devel_pack') {
    $file = $entry.$key.$pack.path
    $dest = Join-Path $work "$pack.zip"
    Invoke-WebRequest "https://downloads.php.net/~windows/releases/$file" -OutFile $dest
    $sum = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
    if ($sum -ne $entry.$key.$pack.sha256.ToLower()) { throw "$file`: SHA-256 $sum, expected $($entry.$key.$pack.sha256)" }
    Write-Output "✓ $file SHA-256 $sum"
}
Expand-Archive (Join-Path $work 'zip.zip') -DestinationPath $Out -Force
Expand-Archive (Join-Path $work 'devel_pack.zip') -DestinationPath (Join-Path $work 'devel') -Force
$phpDevel = (Get-ChildItem (Join-Path $work 'devel') -Directory | Select-Object -First 1).FullName
# PHP < 8.4 headers don't compile/link with clang against the MSVC-built php8ts.dll; backport
# the 8.4 header fixes (a no-op where they're already in).
function Update-PhpHeader([string] $name, [string] $old, [string] $new, [string] $why) {
    $path = Join-Path $phpDevel "include\Zend\$name"
    if (-not (Test-Path $path)) { return }
    $header = Get-Content $path -Raw
    $fixed = $header.Replace($old, $new)
    if ($fixed -ne $header) {
        Set-Content $path $fixed -NoNewline
        Write-Output "patched ${name}: $why"
    }
}
# ZEND_FASTCALL: php8ts.dll exports __vectorcall names (zend_hash_destroy@@8), but < 8.4
# turns __vectorcall off for clang, which would then link against names that don't exist.
Update-PhpHeader 'zend_portability.h' '_MSC_VER >= 1800 && !defined(__clang__)' '_MSC_VER >= 1800' 'ZEND_FASTCALL is __vectorcall under clang'
# 8.3 calls the _AddressOfReturnAddress intrinsic without including <intrin.h>.
Update-PhpHeader 'zend_call_stack.h' "#include `"zend_portability.h`"`n#ifdef __APPLE__" "#include `"zend_portability.h`"`n#ifdef _MSC_VER`n# include <intrin.h>`n#endif`n#ifdef __APPLE__" 'include <intrin.h>'

# FrankenPHP source and its native dependencies.
$src = Join-Path $work 'frankenphp'
if (-not (Test-Path $src)) {
    git -c advice.detachedHead=false clone -q --depth 1 --branch "v$FrankenPHP" https://github.com/php/frankenphp.git $src
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
# auto: Go fetches the toolchain FrankenPHP's go.mod asks for (1.13 needs Go 1.27), so the
# runner's Go version doesn't have to track FrankenPHP releases.
$env:GOTOOLCHAIN = 'auto'
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

# Licenses of what we add to the official PHP build (which carries its own, license.txt).
$licenses = New-Item -ItemType Directory -Force (Join-Path $Out 'LICENSES')
Copy-Item (Join-Path $src 'LICENSE') (Join-Path $licenses 'frankenphp.txt')
foreach ($port in Get-ChildItem (Join-Path $vcpkgRoot 'share') -Directory) {
    $copyright = Join-Path $port.FullName 'copyright'
    if (Test-Path $copyright) { Copy-Item $copyright (Join-Path $licenses "$($port.Name).txt") }
}
Invoke-WebRequest https://raw.githubusercontent.com/e-dant/watcher/HEAD/license -OutFile (Join-Path $licenses 'watcher.txt')
& (Join-Path $Out 'frankenphp.exe') version
