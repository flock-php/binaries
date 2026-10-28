# Repackages pgRouting from OSGeo's PostGIS bundle for Windows (windows/fetch.sh). It needs
# PostGIS (requires in its control file), installed as its own package.
# Usage: packages/pgrouting/windows/build.ps1 -Version <x.y.z> -Source <dir> -Postgres <dir> -Out <dir>
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Postgres,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
$module = (Get-ChildItem (Resolve-Path $Source).Path -Recurse -Filter 'libpgrouting-*.dll' | Select-Object -First 1).Name
& (Join-Path $PSScriptRoot '../../../scripts/windows/repack-osgeo.ps1') -Source $Source -Out $Out `
    -Modules $module -Extensions '^pgrouting(--.*)?\.(control|sql)$'
if (-not (Test-Path (Join-Path $Out "extension/pgrouting--$Version.sql"))) { throw "the bundle has no pgRouting $Version" }
