#requires -Version 5.1
<#
.SYNOPSIS
    Start the AFS SQL Server installer detached from the calling shell.
.DESCRIPTION
    Must run elevated. Starts Install-AfsSqlServer.ps1 in a hidden PowerShell
    process, writes its PID, and returns. Poll logs/sqlserver-install-*.log and
    the MSSQLSERVER service for progress.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$worker = Join-Path $PSScriptRoot 'Install-AfsSqlServer.ps1'
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$launcherLog = Join-Path $logDir 'sqlserver-install-launcher.log'
$pidFile = Join-Path $logDir 'sqlserver-install-worker.pid'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This launcher must run elevated.'
}

$p = Start-Process powershell.exe -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$worker`""
) -WindowStyle Hidden -PassThru
Set-Content -LiteralPath $pidFile -Value $p.Id
"[$(Get-Date -Format o)] started worker PID $($p.Id)" | Tee-Object -FilePath $launcherLog
exit 0
