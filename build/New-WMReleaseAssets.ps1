#requires -Version 5.1
<#
.SYNOPSIS
  Creates the release files for Windows Makeover.

.DESCRIPTION
  Creates a standalone PowerShell script, a complete ZIP package,
  and a SHA-256 checksum file. The declared tool version must match the
  requested release version.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$entryPath = Join-Path $projectRoot 'windows-makeover.ps1'
$modulePath = Join-Path $projectRoot 'src\WindowsMakeover.psm1'
$readmePath = Join-Path $projectRoot 'README.md'

foreach ($requiredPath in @($entryPath, $modulePath, $readmePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required release file not found: $requiredPath"
    }
}

$entryContent = [System.IO.File]::ReadAllText($entryPath)
$versionPattern = '\$script:WMToolVersion = ''([^'']+)'''
$versionMatch = [regex]::Match($entryContent, $versionPattern)
if (-not $versionMatch.Success) {
    throw 'Tool version declaration was not found in windows-makeover.ps1.'
}

$declaredVersion = $versionMatch.Groups[1].Value
if ($declaredVersion -ne $Version) {
    throw "Requested release version '$Version' does not match tool version '$declaredVersion'."
}

$moduleContent = [System.IO.File]::ReadAllText($modulePath)
$moduleBody = [regex]::Replace($moduleContent, '(?m)^Export-ModuleMember[^\r\n]*(?:\r?\n)?$', '')
$moduleBody = [regex]::Replace($moduleBody, '\ASet-StrictMode -Version Latest\r?\n\r?\n', '')
if ($moduleBody -match '(?m)^Export-ModuleMember') {
    throw 'The standalone script still contains Export-ModuleMember.'
}

$entryNormalized = [regex]::Replace($entryContent, '\r?\n', "`n")
$moduleNormalized = [regex]::Replace($moduleBody, '\r?\n', "`n").Trim()
$importBlock = "`$modulePath = Join-Path `$PSScriptRoot 'src\WindowsMakeover.psm1'`nImport-Module `$modulePath -Force`n"
if (-not $entryNormalized.Contains($importBlock)) {
    throw 'The expected module import block was not found in windows-makeover.ps1.'
}

$standaloneContent = $entryNormalized.Replace($importBlock, "$moduleNormalized`n")
$standaloneContent = [regex]::Replace($standaloneContent, '\r?\n', "`r`n")

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}
$outputRoot = (Resolve-Path -LiteralPath $OutputDirectory).Path
$standalonePath = Join-Path $outputRoot "windows-makeover-$Version.ps1"
$zipPath = Join-Path $outputRoot "windows-makeover-$Version.zip"
$checksumPath = Join-Path $outputRoot 'SHA256SUMS.txt'

[System.IO.File]::WriteAllText($standalonePath, $standaloneContent, [System.Text.UTF8Encoding]::new($true))

$stagingPath = Join-Path $outputRoot ('.package-' + [guid]::NewGuid().ToString('N'))
$expectedStagingPrefix = $outputRoot.TrimEnd('\') + '\'
try {
    New-Item -ItemType Directory -Path (Join-Path $stagingPath 'src') -Force | Out-Null
    Copy-Item -LiteralPath $entryPath -Destination (Join-Path $stagingPath 'windows-makeover.ps1')
    Copy-Item -LiteralPath $modulePath -Destination (Join-Path $stagingPath 'src\WindowsMakeover.psm1')
    Copy-Item -LiteralPath $readmePath -Destination (Join-Path $stagingPath 'README.md')

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $stagingPath '*') -DestinationPath $zipPath -CompressionLevel Optimal
}
finally {
    $resolvedStagingPath = [System.IO.Path]::GetFullPath($stagingPath)
    if ((Test-Path -LiteralPath $resolvedStagingPath) -and $resolvedStagingPath.StartsWith($expectedStagingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedStagingPath -Recurse -Force
    }
}

$checksumLines = foreach ($assetPath in @($standalonePath, $zipPath)) {
    $hash = Get-FileHash -LiteralPath $assetPath -Algorithm SHA256
    '{0}  {1}' -f $hash.Hash.ToLowerInvariant(), (Split-Path -Path $assetPath -Leaf)
}
[System.IO.File]::WriteAllLines($checksumPath, $checksumLines, [System.Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    Version          = $Version
    StandaloneScript = $standalonePath
    ZipPackage       = $zipPath
    Checksums        = $checksumPath
}
