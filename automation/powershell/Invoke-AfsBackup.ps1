#requires -Version 5.1
<#
.SYNOPSIS
    Run AFS SQL Server backups through the versioned SQL scripts.

.DESCRIPTION
    Uses Windows Authentication and sqlcmd. Each database is attempted; failures
    are collected and returned as a non-zero exit code. The script does not
    delete old backups and does not claim a backup is valid merely because the
    command returned success: the SQL script performs RESTORE VERIFYONLY.

.PARAMETER Type
    Full, Differential or Log.

.PARAMETER Databases
    Database names. Defaults to the AFS estate. Log backups skip SIMPLE-recovery
    reporting if it is present in the list; the SQL script also guards this.
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Differential', 'Log')]
    [string]$Type = 'Full',
    [string[]]$Databases = @(
        'AFS_CoreBanking', 'AFS_Payments', 'AFS_CustomerService',
        'AFS_Audit', 'AFS_Fraud', 'AFS_Reporting'
    ),
    [string]$Server = $(if ($env:AFS_SQL_SERVER) { $env:AFS_SQL_SERVER } else { 'localhost' }),
    [string]$BackupRoot = $(if ($env:AFS_BACKUP_ROOT) { $env:AFS_BACKUP_ROOT } else { 'C:\AFS\Backups' }),
    [string]$SqlCmdPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$logFile = Join-Path $logDir "backup-$($Type.ToLower())-$stamp.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString('s'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

if (-not $SqlCmdPath) {
    $command = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if (-not $command) { throw 'sqlcmd was not found. Install Microsoft.Sqlcmd or SSMS first.' }
    $SqlCmdPath = $command.Source
}

$script = switch ($Type) {
    'Full'         { 'sql-server/backup/20_backup_full.sql' }
    'Differential' { 'sql-server/backup/21_backup_differential.sql' }
    'Log'          { 'sql-server/backup/22_backup_log.sql' }
}
$scriptPath = Join-Path $repoRoot $script
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Backup script not found: $scriptPath" }

$failures = New-Object System.Collections.Generic.List[string]
foreach ($database in $Databases) {
    Write-Log "Starting $Type backup for $database"
    # BACKUP DATABASE does not create the target directory.
    $databaseBackupRoot = Join-Path $BackupRoot $database
    New-Item -ItemType Directory -Path $databaseBackupRoot -Force | Out-Null
    $arguments = @(
        '-S', $Server, '-E', '-b', '-I', '-l', '120',
        '-i', $scriptPath,
        '-v', "DatabaseName=$database",
        '-v', "BackupRoot=$BackupRoot"
    )
    & $SqlCmdPath @arguments 2>&1 | Tee-Object -FilePath $logFile -Append
    if ($LASTEXITCODE -ne 0) {
        $failures.Add($database)
        Write-Log "FAILED: $database (exit $LASTEXITCODE)"
    }
    else {
        Write-Log "Completed and verified: $database"
    }
}

if ($failures.Count -gt 0) {
    Write-Log ("Backup failures: " + ($failures -join ', '))
    exit 1
}

Write-Log "All $Type backups completed and verified."
exit 0
