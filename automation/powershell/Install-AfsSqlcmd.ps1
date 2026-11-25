#requires -Version 5.1
<#
.SYNOPSIS
    Install Microsoft sqlcmd 1.10 from the downloaded MSI.
.DESCRIPTION
    Must run elevated. Installs only the official Microsoft MSI already present
    under installers/. Logs to logs/sqlcmd-msi.log. Exit code is the MSI result.
#>
[CmdletBinding()]
param(
    [string]$MsiPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $MsiPath) {
    $MsiPath = Join-Path $repoRoot 'installers\sqlcmd-amd64.msi'
}
$logDir = Join-Path $repoRoot 'logs'
$logFile = Join-Path $logDir 'sqlcmd-msi.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

if (-not (Test-Path -LiteralPath $MsiPath)) {
    throw "sqlcmd MSI not found: $MsiPath"
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This installer must run elevated.'
}

Write-Host "Installing $MsiPath"
$arguments = "/i `"$MsiPath`" /qn /norestart /l*v `"$logFile`""
$p = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
Write-Host "MSI exit code: $($p.ExitCode)"
Write-Host "Log: $logFile"
exit $p.ExitCode
