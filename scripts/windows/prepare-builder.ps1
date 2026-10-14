# Checks out php/php-windows-builder at a pinned commit into .builder/ and patches it to work
# without directory listings on downloads.php.net, which the CDN stopped serving (403) in
# October 2026: https://github.com/php/php-windows-builder/issues/34
# The patched lookups read files that are still served instead:
#   php-sdk deps  series/packages-<php>-<vs>-<arch>-{stable,staging}.txt
#   pecl deps     pecl/deps/dllmapping.json (every dependency zip per VS version and arch)
# Drop this once upstream is fixed and use php/php-windows-builder/extension@v1 again.
param([string] $Dest = '.builder')
$ErrorActionPreference = 'Stop'

$commit = '5f63433eb2bda2ca8d0d970fe487be84f7ab195c'  # 2026-09-23, "Add PHP 8.7 support"

if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
git init -q $Dest
git -C $Dest fetch -q --depth 1 https://github.com/php/php-windows-builder.git $commit
git -C $Dest checkout -q FETCH_HEAD
$private = Join-Path $Dest 'extension/BuildPhpExtension/private'

# A listing stand-in: Content (names, one per line) and Links (objects with HREF), the two
# properties the builder reads from Invoke-WebRequest results.
@'
Function Get-DepsListing {
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('php', 'pecl')] [string] $Kind,
        [Parameter(Mandatory = $true)] [string] $VsVersion,
        [Parameter(Mandatory = $true)] [string] $Arch,
        [string] $PhpVersion
    )
    $names = @()
    if ($Kind -eq 'php') {
        foreach ($stability in 'stable', 'staging') {
            try {
                $url = "https://downloads.php.net/~windows/php-sdk/deps/series/packages-$PhpVersion-$VsVersion-$Arch-$stability.txt"
                $names += ((Invoke-WebRequest -Uri $url -UseBasicParsing).Content -split "`r?`n") | Where-Object { $_ }
            } catch { }
        }
    } else {
        $map = Invoke-RestMethod -Uri 'https://downloads.php.net/~windows/pecl/deps/dllmapping.json'
        # All VS versions: Get-PeclLibraryZip also falls back to older toolsets. (Loop variables
        # must not be named like the [string] parameters, or PowerShell converts them to strings.)
        foreach ($toolset in $map.PSObject.Properties) {
            foreach ($platform in $toolset.Value.PSObject.Properties) {
                $names += $platform.Value.PSObject.Properties.Name
            }
        }
    }
    $names = $names | Sort-Object -Unique
    [PSCustomObject]@{
        Content = ($names -join "`n")
        Links   = @($names | ForEach-Object { [PSCustomObject]@{ HREF = $_ } })
    }
}
'@ | Set-Content (Join-Path $private 'Get-DepsListing.ps1') -Encoding utf8

function Edit-File([string] $file, [string] $from, [string] $to) {
    $path = Join-Path $private $file
    $text = Get-Content $path -Raw
    if (-not $text.Contains($from)) { throw "patch target not found in ${file}: $from" }
    Set-Content $path $text.Replace($from, $to) -NoNewline -Encoding utf8
}

Edit-File 'Add-PhpDependencies.ps1' `
    '$phpTrunk = Get-File -Url $phpTrunkBaseUrl' `
    '$phpTrunk = Get-DepsListing -Kind php -VsVersion $Config.vs_version -Arch $Config.arch -PhpVersion $Config.php_version'

Edit-File 'Get-ExtensionConfig.ps1' `
    '$phpSeries = Get-File -Url "https://downloads.php.net/~windows/php-sdk/deps/$VsVersion/$Arch"' `
    '$phpSeries = Get-DepsListing -Kind php -VsVersion $VsVersion -Arch $Arch -PhpVersion $PhpVersion'
Edit-File 'Get-ExtensionConfig.ps1' `
    '$extensionSeries = Get-File -Url "https://downloads.php.net/~windows/pecl/deps"' `
    '$extensionSeries = Get-DepsListing -Kind pecl -VsVersion $VsVersion -Arch $Arch'
Edit-File 'Get-ExtensionConfig.ps1' `
    '$extensionArchivesSeries = Get-File -Url "https://downloads.php.net/~windows/pecl/deps/archives"' `
    '$extensionArchivesSeries = [PSCustomObject]@{ Content = ""; Links = @() }'

Edit-File 'Get-LibrariesFromConfig.ps1' `
    '$phpSeries = (Get-File -Url "https://downloads.php.net/~windows/php-sdk/deps/$VsVersion/$Arch").Content.ToLower()' `
    '$phpSeries = (Get-DepsListing -Kind php -VsVersion $VsVersion -Arch $Arch -PhpVersion $PhpVersion).Content.ToLower()'

Write-Output "php-windows-builder $commit prepared in $Dest (patched for missing directory listings)"
