#requires -Version 5.1
<#
.SYNOPSIS
    Install SQL Server 2025 Express LocalDB for the AFS lab fallback.
.DESCRIPTION
    Must run elevated. Installs the official SqlLocalDB.msi already downloaded
    under installers/. LocalDB is a user-mode engine; it is not a full SQL Server
    Developer instance and does not provide SQL Agent or mixed-mode logins.
#>
[CmdletBinding()]
param(
    [string]$MsiPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $MsiPath) {
    $MsiPath = Join-Path $repoRoot 'installers\SqlLocalDB.msi'
}
$logFile = Join-Path $repoRoot 'logs\localsql-msi.log'

if (-not (Test-Path -LiteralPath $MsiPath)) {
    throw "LocalDB MSI not found: $MsiPath"
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This installer must run elevated.'
}

$arguments = "/i `"$MsiPath`" /qn /norestart IACCEPTSQLLOCALDBLICENSETERMS=YES /l*v `"$logFile`""
$p = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
Write-Host "LocalDB MSI exit code: $($p.ExitCode)"
Write-Host "Log: $logFile"
exit $p.ExitCode
