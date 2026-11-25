#requires -Version 5.1
<#
.SYNOPSIS
    Verify the newest AFS backup files without restoring the databases.

.DESCRIPTION
    Checks file existence/size/age and runs RESTORE VERIFYONLY WITH CHECKSUM for
    each newest full or log backup found under the backup root. A successful file
    listing is not enough; VERIFYONLY is executed. This still does not prove
    logical consistency - use the recovery runbook for a restore drill.

    Exit codes: 0 = all checked files verified, 1 = verification failed or a
    backup is overdue, 2 = prerequisite/configuration failure.
#>
[CmdletBinding()]
param(
    [string]$Server = $(if ($env:AFS_SQL_SERVER) { $env:AFS_SQL_SERVER } else { 'localhost' }),
    [string]$BackupRoot = $(if ($env:AFS_BACKUP_ROOT) { $env:AFS_BACKUP_ROOT } else { 'C:\AFS\Backups' }),
    [int]$MaxFullAgeDays = 7,
    [string]$SqlCmdPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$verifyScript = Join-Path $repoRoot 'sql-server/backup/23_backup_verify.sql'
$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$logFile = Join-Path $logDir "backup-verify-$stamp.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString('s'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

if (-not (Test-Path -LiteralPath $BackupRoot)) {
    Write-Log "Backup root does not exist: $BackupRoot"
    exit 2
}
if (-not $SqlCmdPath) {
    $command = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if (-not $command) { Write-Log 'sqlcmd not found.'; exit 2 }
    $SqlCmdPath = $command.Source
}
if (-not (Test-Path -LiteralPath $verifyScript)) {
    Write-Log "Verify script not found: $verifyScript"
    exit 2
}

$files = Get-ChildItem -Path $BackupRoot -Recurse -File -Include '*.bak', '*.trn' |
    Sort-Object LastWriteTime -Descending
if (-not $files) {
    Write-Log "No backup files found under $BackupRoot"
    exit 1
}

$failures = 0
$checked = 0
foreach ($file in $files) {
    if ($file.Length -le 0) {
        Write-Log "FAIL empty file: $($file.FullName)"
        $failures++
        continue
    }
    $isFull = $file.Name -match '_FULL_' -or $file.Name -match '_DIFF_'
    $ageDays = ((Get-Date).ToUniversalTime() - $file.LastWriteTimeUtc).TotalDays
    if ($isFull -and $ageDays -gt $MaxFullAgeDays) {
        Write-Log "FAIL overdue full/diff backup (${ageDays:N1} days): $($file.FullName)"
        $failures++
    }

    Write-Log "Verifying $($file.FullName) ($([math]::Round($file.Length / 1MB, 2)) MB)"
    & $SqlCmdPath -S $Server -E -b -I -l 60 -i $verifyScript -v "BackupFile=$($file.FullName)" 2>&1 |
        Tee-Object -FilePath $logFile -Append
    if ($LASTEXITCODE -ne 0) {
        Write-Log "FAIL verification: $($file.FullName)"
        $failures++
    }
    else {
        Write-Log "PASS verification: $($file.FullName)"
    }
    $checked++
}

Write-Log "Checked $checked file(s); failures: $failures"
if ($failures -gt 0) { exit 1 }
exit 0
