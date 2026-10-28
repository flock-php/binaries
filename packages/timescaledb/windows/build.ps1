# Repackages Timescale's own Windows build of TimescaleDB (fetched and checked by windows/fetch.sh)
# unmodified into the layout Flock links: lib\timescaledb*.dll, extension\timescaledb*.
# Usage: packages/timescaledb/windows/build.ps1 -Version <x.y.z> -Source <dir> -Postgres <dir> -Out <dir>
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Postgres,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'

$src = (Resolve-Path $Source).Path
$Out = [IO.Path]::GetFullPath($Out)
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force (Join-Path $Out 'lib'), (Join-Path $Out 'extension'), (Join-Path $Out 'LICENSES') | Out-Null
$dlls = Get-ChildItem $src -Recurse -Filter 'timescaledb*.dll'
if (-not ($dlls | Where-Object Name -eq "timescaledb-$Version.dll")) { throw "no timescaledb-$Version.dll in Timescale's package" }
$dlls | Copy-Item -Destination (Join-Path $Out 'lib')
Get-ChildItem $src -Recurse -File | Where-Object { $_.Name -match '^timescaledb.*\.(control|sql)$' } | Copy-Item -Destination (Join-Path $Out 'extension')
foreach ($license in Get-ChildItem $src -Recurse -File | Where-Object { $_.Name -match '^LICENSE' }) {
    Copy-Item $license.FullName (Join-Path $Out "LICENSES/timescaledb-$($license.Name.ToLower()).txt")
}
Get-ChildItem -Recurse $Out | ForEach-Object { $_.FullName.Substring($Out.Length) }
