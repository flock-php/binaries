# Builds the PostgreSQL server, client tools and contrib extensions for Windows x64 with MSVC,
# OpenSSL and zlib from vcpkg (their DLLs are shipped in bin/). PostgreSQL 16+ builds with meson;
# 14 and 15 only have the older MSVC build scripts (src/tools/msvc).
# Run in a Visual Studio developer shell with Strawberry Perl, winflexbison and (16+) meson and
# ninja on PATH: see build-service.yml.
# -Source is the unpacked, verified source (packages/postgres/source.sh), prepared by a bash step:
# run from here, Git's bash never handed control back on the runners.
# Usage: packages/postgres/windows/build.ps1 -Version <x.y> -Source <dir> -Out <dir>
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$work = Join-Path $PWD 'postgres-work'
New-Item -ItemType Directory -Force $work | Out-Null
$Out = [IO.Path]::GetFullPath($Out)
$major = [int]$Version.Split('.')[0]

$src = (Resolve-Path $Source).Path
if (-not (Test-Path (Join-Path $src 'COPYRIGHT'))) { throw "$src is not a PostgreSQL source tree" }

Write-Output "::group::OpenSSL and zlib (vcpkg) $(Get-Date -Format HH:mm:ss)"
$vcpkgRoot = Join-Path $work 'vcpkg'
& "$env:VCPKG_INSTALLATION_ROOT/vcpkg.exe" install openssl zlib --triplet x64-windows "--x-install-root=$vcpkgRoot"
$deps = Join-Path $vcpkgRoot 'x64-windows'
Write-Output '::endgroup::'

# winflexbison installs win_bison/win_flex; the MSVC scripts (14, 15) call bison and flex.
$tools = Join-Path $work 'tools'
New-Item -ItemType Directory -Force $tools | Out-Null
foreach ($t in 'bison', 'flex') {
    $exe = (Get-Command "win_$t.exe").Source
    Copy-Item $exe (Join-Path $tools "$t.exe") -Force
    Copy-Item (Join-Path (Split-Path $exe) 'data') (Join-Path $tools 'data') -Recurse -Force -ErrorAction SilentlyContinue
}
$env:PATH = "$tools;$env:PATH"

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
if ($major -ge 16) {
    Write-Output "::group::meson setup $(Get-Date -Format HH:mm:ss)"
    $env:PKG_CONFIG_PATH = Join-Path $deps 'lib/pkgconfig'
    $env:CMAKE_PREFIX_PATH = $deps
    meson setup (Join-Path $work 'build') $src --prefix=$Out --buildtype=release `
        -Dssl=openssl -Dzlib=enabled -Dicu=disabled -Dnls=disabled -Dreadline=disabled `
        -Dplperl=disabled -Dplpython=disabled -Dpltcl=disabled -Dlz4=disabled -Dzstd=disabled `
        -Dgssapi=disabled -Dldap=disabled -Dlibxml=disabled -Dlibxslt=disabled -Duuid=none `
        "-Dextra_include_dirs=$deps/include" "-Dextra_lib_dirs=$deps/lib"
    Write-Output '::endgroup::'
    Write-Output "::group::Build $(Get-Date -Format HH:mm:ss)"
    meson compile -C (Join-Path $work 'build')
    meson install -C (Join-Path $work 'build') --quiet
    Write-Output '::endgroup::'
} else {
    Write-Output "::group::MSVC build scripts $(Get-Date -Format HH:mm:ss)"
    # The scripts look for zlib as lib\zdll.lib and run bin\openssl.exe to learn its version.
    Copy-Item (Join-Path $deps 'lib/zlib.lib') (Join-Path $deps 'lib/zdll.lib') -Force
    Copy-Item (Join-Path $deps 'tools/openssl/openssl.exe') (Join-Path $deps 'bin/openssl.exe') -Force
    $depsPerl = $deps -replace '\\', '/'
    Set-Content (Join-Path $src 'src/tools/msvc/config.pl') -Encoding ascii -Value @"
use strict;
use warnings;
our `$config;
`$config->{openssl} = '$depsPerl';
`$config->{zlib} = '$depsPerl';
1;
"@
    Push-Location (Join-Path $src 'src/tools/msvc')
    try {
        perl build.pl
        perl install.pl $Out
    } finally { Pop-Location }
    Write-Output '::endgroup::'
}

# The runtime DLLs of OpenSSL and zlib, next to the executables that load them.
foreach ($dll in Get-ChildItem (Join-Path $deps 'bin') -Filter '*.dll') {
    Copy-Item $dll.FullName (Join-Path $Out 'bin') -Force
}
# Headers, import libraries and debug symbols are only for building against PostgreSQL.
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $Out 'include'), (Join-Path $Out 'symbols'), (Join-Path $Out 'doc'), (Join-Path $Out 'share/doc')
Get-ChildItem $Out -Recurse -Include '*.lib', '*.a', '*.pdb' | Remove-Item -Force

$licenses = Join-Path $Out 'LICENSES'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item (Join-Path $src 'COPYRIGHT') (Join-Path $licenses 'postgresql.txt')
Copy-Item (Join-Path $vcpkgRoot 'x64-windows/share/openssl/copyright') (Join-Path $licenses 'openssl.txt')
Copy-Item (Join-Path $vcpkgRoot 'x64-windows/share/zlib/copyright') (Join-Path $licenses 'zlib.txt')

& (Join-Path $Out 'bin/postgres.exe') --version
