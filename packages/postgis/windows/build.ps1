# Repackages PostGIS from OSGeo's bundle for Windows (windows/fetch.sh), with the same extensions
# as on macOS and Linux: postgis, postgis_topology, postgis_tiger_geocoder. Not raster, SFCGAL or
# address_standardizer. PROJ's data goes along as share\proj.
# Usage: packages/postgis/windows/build.ps1 -Version <x.y.z> -Source <dir> -Postgres <dir> -Out <dir>
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Postgres,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '../../../scripts/windows/repack-osgeo.ps1') -Source $Source -Out $Out -Proj `
    -Modules 'postgis-3.dll', 'postgis_topology-3.dll' `
    -Extensions '^postgis(_topology|_tiger_geocoder)?(--.*)?\.(control|sql)$'
if (-not (Test-Path (Join-Path $Out "extension/postgis--$Version.sql"))) { throw "the bundle has no PostGIS $Version" }
