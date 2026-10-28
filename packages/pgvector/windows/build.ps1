# Builds pgvector for Windows x64 with MSVC (pgvector's Makefile.win, nmake) against Flock's
# postgres package of one major, whose include\ and lib\postgres.lib it compiles and links
# against, into the layout Flock links: lib\vector.dll, extension\vector*.{control,sql}.
# Run in a Visual Studio developer shell (x64): see build-pg-extension.yml.
# -Source is the source fetched by packages/pgvector/source.sh, in a bash step of its own: run
# from here, Git's bash never handed control back on the runners.
# Usage: packages/pgvector/windows/build.ps1 -Version <x.y.z> -Source <dir> -Postgres <dir> -Out <dir>
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Postgres,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Out = [IO.Path]::GetFullPath($Out)
$pg = (Resolve-Path $Postgres).Path
# Where this PostgreSQL has its files (include\postgresql\server, lib\postgresql, ...): pgvector's
# Makefile.win assumes include\server and lib, so they are given to nmake.
$pgConfig = Join-Path $pg 'bin/pg_config.exe'
function Dir($what) { (& $pgConfig "--$what").Trim() }
$dirs = @{
    BINDIR = Dir 'bindir'; INCLUDEDIR = Dir 'includedir'; INCLUDEDIR_SERVER = Dir 'includedir-server'
    LIBDIR = Dir 'libdir'; PKGLIBDIR = Dir 'pkglibdir'; SHAREDIR = Dir 'sharedir'
}
foreach ($f in (Join-Path $dirs.INCLUDEDIR_SERVER 'postgres.h'), (Join-Path $dirs.LIBDIR 'postgres.lib')) {
    if (-not (Test-Path $f)) { throw "no ${f}: the postgres package needs build 2 or later" }
}

$src = (Resolve-Path $Source).Path

Push-Location $src
try {
    $env:PGROOT = $pg
    nmake /NOLOGO /F Makefile.win @($dirs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
} finally { Pop-Location }

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force (Join-Path $Out 'lib'), (Join-Path $Out 'extension'), (Join-Path $Out 'LICENSES') | Out-Null
Copy-Item (Join-Path $src 'vector.dll') (Join-Path $Out 'lib')
Copy-Item (Join-Path $src 'vector.control') (Join-Path $Out 'extension')
Copy-Item (Join-Path $src 'sql/vector--*.sql') (Join-Path $Out 'extension')
Copy-Item (Join-Path $src 'LICENSE') (Join-Path $Out 'LICENSES/pgvector.txt')
Get-ChildItem -Recurse $Out | ForEach-Object { $_.FullName.Substring($Out.Length) }
