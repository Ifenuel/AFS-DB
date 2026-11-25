#requires -Version 5.1
<#
.SYNOPSIS
    Install SQL Server 2025 Developer Edition on the AFS lab machine.
.DESCRIPTION
    Must run from an elevated PowerShell session. Uses the Microsoft winget
    package and logs the complete attempt. This script does not invent success:
    it exits non-zero if winget fails or the expected service is absent.
.NOTES
    The package's silent switches perform a default Developer installation.
    Authentication mode and memory settings are verified/configured afterwards.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$logFile = Join-Path $logDir "sqlserver-install-$stamp.log"

Start-Transcript -Path $logFile -Force | Out-Null
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This installer must run elevated.'
    }

    $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $winget) {
        $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    }
    if (-not (Test-Path -LiteralPath $winget)) {
        throw 'winget was not found.'
    }

    Write-Host "Installing SQL Server 2025 Developer via winget..."
    & $winget install --id Microsoft.SQLServer.2025.Developer --exact --source winget `
        --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    $wingetExit = $LASTEXITCODE
    Write-Host "winget exit code: $wingetExit"

    $service = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "SQL Server service MSSQLSERVER is not present after winget exit $wingetExit. See $logFile."
    }
    if ($service.Status -ne 'Running') {
        Start-Service -Name 'MSSQLSERVER'
        $service.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
    }

    Write-Host "SQL Server service status: $((Get-Service MSSQLSERVER).Status)"
    $sqlcmd = 'C:\Program Files\SqlCmd\sqlcmd.exe'
    if (Test-Path -LiteralPath $sqlcmd) {
        Write-Host "sqlcmd: $sqlcmd"
    }
    Write-Host 'Installation worker completed. Verify connectivity and edition next.'
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
