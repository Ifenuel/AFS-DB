#requires -Version 5.1
<#
.SYNOPSIS
    Run the AFS SQL health check and return a monitoring-friendly exit code.

.DESCRIPTION
    Exit codes: 0 = OK, 1 = WARNING, 2 = CRITICAL or execution failure.
    A local text report is not a production paging system; it is a lab alert
    demonstration with a saved artifact for evidence.
#>
[CmdletBinding()]
param(
    [string]$Server = $(if ($env:AFS_SQL_SERVER) { $env:AFS_SQL_SERVER } else { 'localhost' }),
    [string]$SqlCmdPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$healthScript = Join-Path $repoRoot 'sql-server/monitoring/40_health_check.sql'
$reportDir = Join-Path $repoRoot 'reports/generated'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$reportFile = Join-Path $reportDir "health-$stamp.txt"

if (-not $SqlCmdPath) {
    $command = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if (-not $command) {
        Write-Error 'sqlcmd not found; cannot run health check.'
        exit 2
    }
    $SqlCmdPath = $command.Source
}

$output = & $SqlCmdPath -S $Server -E -b -I -l 60 -i $healthScript 2>&1
$exitCode = $LASTEXITCODE
$output | Tee-Object -FilePath $reportFile
if ($exitCode -ne 0) {
    Write-Host "Health-check SQL failed with exit code $exitCode. Report: $reportFile"
    exit 2
}

$critical = @($output | Select-String -Pattern 'CRITICAL' -CaseSensitive).Count
$warning = @($output | Select-String -Pattern 'WARNING' -CaseSensitive).Count
if ($critical -gt 0) {
    Write-Host "Health status: CRITICAL ($critical matching line(s)). Report: $reportFile"
    exit 2
}
if ($warning -gt 0) {
    Write-Host "Health status: WARNING ($warning matching line(s)). Report: $reportFile"
    exit 1
}
Write-Host "Health status: OK. Report: $reportFile"
exit 0
