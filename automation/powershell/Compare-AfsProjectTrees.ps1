#requires -Version 5.1
<#
.SYNOPSIS
    Compare two project trees by relative path, size and SHA-256 hash.

.DESCRIPTION
    Proves that a copy of the project is complete and unaltered. Compares file
    counts, folder counts, byte totals and per-file hashes. Excludes the
    directories that are intentionally not copied (source-control metadata and
    application-internal folders) plus oversized installer media.

.PARAMETER Source
    Reference tree (the original project folder).

.PARAMETER Target
    Tree being verified (for example the permanent Documents copy).

.PARAMETER ExcludeDirectory
    Directory names skipped in both trees. Default: .git, node_modules.

.PARAMETER ExcludeExtension
    File extensions skipped in both trees. Default: .iso, .pid.

.OUTPUTS
    Console table plus a PASS/FAIL summary. Exit code 0 when identical,
    2 when differences are found, 1 on error.

.EXAMPLE
    .\Compare-AfsProjectTrees.ps1 `
        -Source 'C:\Users\me\AppData\Local\app\projects\abc' `
        -Target "$env:USERPROFILE\Documents\Apex-Financial-Services-DBA-Portfolio"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Source,

    [Parameter(Mandatory)]
    [string]$Target,

    [string[]]$ExcludeDirectory = @('.git', 'node_modules'),

    [string[]]$ExcludeExtension = @('.iso', '.pid')
)

$ErrorActionPreference = 'Stop'

function Get-AfsTreeFile {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        throw "Path not found: $Root"
    }

    Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object {
            $relative = $_.FullName.Substring($Root.Length).Trim('\')
            $parts = $relative.Split('\')
            $inExcludedDirectory = $false
            foreach ($part in $parts[0..([Math]::Max($parts.Count - 2, 0))]) {
                if ($ExcludeDirectory -contains $part) { $inExcludedDirectory = $true }
            }
            (-not $inExcludedDirectory) -and ($ExcludeExtension -notcontains $_.Extension)
        }
}

function Get-AfsFolderCount {
    param([string]$Root)

    (Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force |
        Where-Object {
            $relative = $_.FullName.Substring($Root.Length).Trim('\')
            $blocked = $false
            foreach ($part in $relative.Split('\')) {
                if ($ExcludeDirectory -contains $part) { $blocked = $true }
            }
            -not $blocked
        }).Count
}

$sourceRoot = (Resolve-Path -LiteralPath $Source).Path
$targetRoot = (Resolve-Path -LiteralPath $Target).Path

Write-Host "Source : $sourceRoot"
Write-Host "Target : $targetRoot"
Write-Host "Excluded directories: $($ExcludeDirectory -join ', ')"
Write-Host "Excluded extensions : $($ExcludeExtension -join ', ')"
Write-Host ''

$sourceFiles = Get-AfsTreeFile -Root $sourceRoot
$targetFiles = Get-AfsTreeFile -Root $targetRoot

$sourceHash = @{}
foreach ($file in $sourceFiles) {
    $sourceHash[$file.FullName.Substring($sourceRoot.Length).Trim('\')] =
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}

$targetHash = @{}
foreach ($file in $targetFiles) {
    $targetHash[$file.FullName.Substring($targetRoot.Length).Trim('\')] =
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}

$missing = @($sourceHash.Keys | Where-Object { -not $targetHash.ContainsKey($_) })
$extra = @($targetHash.Keys | Where-Object { -not $sourceHash.ContainsKey($_) })
$changed = @($sourceHash.Keys | Where-Object {
    $targetHash.ContainsKey($_) -and $targetHash[$_] -ne $sourceHash[$_]
})
$identical = @($sourceHash.Keys | Where-Object {
    $targetHash.ContainsKey($_) -and $targetHash[$_] -eq $sourceHash[$_]
})

$sourceBytes = ($sourceFiles | Measure-Object -Property Length -Sum).Sum
$targetBytes = ($targetFiles | Measure-Object -Property Length -Sum).Sum

[pscustomobject]@{
    Metric         = 'Files'
    Source         = $sourceFiles.Count
    Target         = $targetFiles.Count
}, [pscustomobject]@{
    Metric         = 'Folders'
    Source         = Get-AfsFolderCount -Root $sourceRoot
    Target         = Get-AfsFolderCount -Root $targetRoot
}, [pscustomobject]@{
    Metric         = 'Bytes'
    Source         = $sourceBytes
    Target         = $targetBytes
}, [pscustomobject]@{
    Metric         = 'SHA256 identical'
    Source         = $sourceFiles.Count
    Target         = $identical.Count
} | Format-Table -AutoSize

Write-Host "Missing in target : $($missing.Count)"
$missing | ForEach-Object { Write-Host "  - $_" }
Write-Host "Extra in target   : $($extra.Count)"
$extra | ForEach-Object { Write-Host "  + $_" }
Write-Host "Content mismatch  : $($changed.Count)"
$changed | ForEach-Object { Write-Host "  ! $_" }

Write-Host ''
if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $changed.Count -eq 0) {
    Write-Host "RESULT: PASS - target is an exact copy of $($sourceFiles.Count) files."
    exit 0
}

Write-Host 'RESULT: FAIL - differences were found (see lists above).'
exit 2
