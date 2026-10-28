# Repackages part of OSGeo's PostGIS bundle for Windows (fetched and checked by scripts/osgeo-bundle.sh)
# into the layout Flock links:
#   lib\        the modules given
#   extension\  the control and SQL files of the extensions given
#   deps\       every DLL the modules load from the bundle, found by following their imports
#               (dumpbin /dependents) through the bundle's bin\ and its subfolders: libwinpthread-1.dll
#               only is in bin\postgisgui\. Flock copies them next to postgres.exe, never replacing
#               the server's own (OpenSSL, zlib).
#   share\proj  with -Proj: PROJ's data; Flock points PROJ_DATA at it
# Nothing else of the bundle (GDAL, raster, h3, MobilityDB, ...) is taken.
# Run in a Visual Studio developer shell (dumpbin).
# Usage: scripts/windows/repack-osgeo.ps1 -Source <dir> -Modules <dll,...> -Extensions <regex> -Out <dir> [-Proj]
param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string[]] $Modules,
    [Parameter(Mandatory)] [string] $Extensions,
    [Parameter(Mandatory)] [string] $Out,
    [switch] $Proj
)
$ErrorActionPreference = 'Stop'

$root = (Get-ChildItem (Resolve-Path $Source).Path -Recurse -Filter 'postgis.control' | Select-Object -First 1).Directory.Parent.Parent.FullName
$Out = [IO.Path]::GetFullPath($Out)
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
foreach ($d in 'lib', 'extension', 'deps', 'LICENSES') { New-Item -ItemType Directory -Force (Join-Path $Out $d) | Out-Null }

# DLLs of the bundle by name; bin\ wins over its subfolders.
$available = @{}
foreach ($f in Get-ChildItem (Join-Path $root 'bin') -Recurse -Filter '*.dll' | Sort-Object { $_.FullName.Split('\').Count }) {
    if (-not $available.ContainsKey($f.Name.ToLower())) { $available[$f.Name.ToLower()] = $f.FullName }
}
$queue = [Collections.Generic.Queue[string]]::new()
foreach ($m in $Modules) {
    $path = Join-Path $root "lib/$m"
    if (-not (Test-Path $path)) { throw "the bundle has no lib\$m" }
    Copy-Item $path (Join-Path $Out 'lib')
    $queue.Enqueue($path)
}
$seen = @{}
while ($queue.Count) {
    $file = $queue.Dequeue()
    $imports = dumpbin /nologo /dependents $file | Where-Object { $_ -match '^\s+(\S+\.dll)\s*$' } | ForEach-Object { $Matches[1] }
    foreach ($dll in $imports) {
        $key = $dll.ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if ($available.ContainsKey($key)) {
            Copy-Item $available[$key] (Join-Path $Out 'deps')
            $queue.Enqueue($available[$key])
        }
    }
}
Write-Output "deps: $((Get-ChildItem (Join-Path $Out 'deps')).Name -join ' ')"

Get-ChildItem (Join-Path $root 'share/extension') -File | Where-Object { $_.Name -match $Extensions } |
    Copy-Item -Destination (Join-Path $Out 'extension')
if ($Proj) {
    $projDb = Get-ChildItem $root -Recurse -Filter 'proj.db' | Select-Object -First 1
    if (-not $projDb) { throw 'the bundle has no proj.db' }
    New-Item -ItemType Directory -Force (Join-Path $Out 'share') | Out-Null
    Copy-Item $projDb.DirectoryName (Join-Path $Out 'share/proj') -Recurse
}
foreach ($f in Get-ChildItem $root -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|README)' -or $_.Name -match '_version\.txt$|^version\.txt$' }) {
    Copy-Item $f.FullName (Join-Path $Out "LICENSES/osgeo-$($f.Name)")
}
