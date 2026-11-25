# AFS backup health: the completeness check the project was missing.
#
# A backup job that silently stops looks exactly like a healthy one if you only
# read the last success row. This checks the things that actually break an RPO:
#   * SQL Server: how long since each FULL-recovery database got a log backup
#   * Oracle: fast recovery area usage, and how stale the last scheduled run is
#   * MySQL: how stale the newest dump is
#
# Exit codes: 0 = OK, 1 = WARNING, 2 = CRITICAL (or a check could not run).
# The result is a lab alert artifact with a real exit code, not a paging system.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$SqlServer        = '.',
  [int]$SqlLogWarnMinutes   = 30,
  [int]$SqlLogCritMinutes   = 120,
  [int]$FraWarnPercent      = 80,
  [int]$FraCritPercent      = 90,
  [int]$BackupWarnHours     = 36,
  [string]$MysqlBackupRoot  = 'C:\ProgramData\AFS\backups\mysql',
  [string]$LogFile          = 'C:\ProgramData\AFS\logs\backup_health.log'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repo

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
  param([string]$Engine, [string]$Check, [string]$Status, [string]$Detail)
  $results.Add([pscustomobject]@{ Engine = $Engine; Check = $Check; Status = $Status; Detail = $Detail })
}

# ---- SQL Server: log backup age per FULL database -------------------------
try {
  $q = @"
SELECT d.name + '|' + CAST(ISNULL(DATEDIFF(MINUTE, MAX(b.backup_finish_date), GETDATE()), 999999) AS varchar(12))
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b ON b.database_name = d.name AND b.type = 'L'
WHERE d.recovery_model_desc = 'FULL' AND d.name LIKE 'AFS%'
GROUP BY d.name;
"@
  $raw = & (Join-Path $PSScriptRoot 'AfsReadOnly.ps1') -Server $SqlServer -Query $q 6>&1 | Out-String
  $rows = $raw -split "`r?`n" | Where-Object { $_ -match '\|' }
  if (-not $rows) { Add-Result 'SQL Server' 'log backup age' 'CRITICAL' 'query returned no rows' }
  foreach ($line in $rows) {
    $name, $mins = $line.Trim() -split '\|'
    $m = [int]$mins
    if ($m -ge $SqlLogCritMinutes) { $st = 'CRITICAL' }
    elseif ($m -ge $SqlLogWarnMinutes) { $st = 'WARNING' }
    else { $st = 'OK' }
    Add-Result 'SQL Server' "log backup: $name" $st "$m min since last log backup (warn ${SqlLogWarnMinutes}m / crit ${SqlLogCritMinutes}m)"
  }
} catch {
  Add-Result 'SQL Server' 'log backup age' 'CRITICAL' "check failed: $($_.Exception.Message)"
}

# ---- Oracle: FRA usage, archive freshness, scheduled run ------------------
try {
  $oraOut = & (Join-Path $PSScriptRoot 'Invoke-OracleSql.ps1') `
    -Query "SELECT 'FRA_PCT=' || ROUND(space_used / space_limit * 100, 1) FROM v`$recovery_file_dest;" 6>&1 | Out-String
  if ($oraOut -match 'FRA_PCT=([\d.]+)') {
    $pct = [double]$Matches[1]
    if ($pct -ge $FraCritPercent) { $st = 'CRITICAL' } elseif ($pct -ge $FraWarnPercent) { $st = 'WARNING' } else { $st = 'OK' }
    Add-Result 'Oracle' 'fast recovery area' $st "$pct% used (warn ${FraWarnPercent}% / crit ${FraCritPercent}%)"
  } else {
    Add-Result 'Oracle' 'fast recovery area' 'CRITICAL' 'could not read FRA usage from v$recovery_file_dest'
  }
} catch {
  Add-Result 'Oracle' 'fast recovery area' 'CRITICAL' "check failed: $($_.Exception.Message)"
}

try {
  $info = Get-ScheduledTaskInfo -TaskName 'AFS Oracle RMAN Backup' -ErrorAction Stop
  $ageH = [math]::Round(((Get-Date) - [datetime]$info.LastRunTime).TotalHours, 1)
  if ($info.LastTaskResult -ne 0) { $st = 'CRITICAL' }
  elseif ($ageH -gt ($BackupWarnHours * 2)) { $st = 'CRITICAL' }
  elseif ($ageH -gt $BackupWarnHours) { $st = 'WARNING' }
  else { $st = 'OK' }
  Add-Result 'Oracle' 'scheduled RMAN run' $st "last run $ageH h ago, result $($info.LastTaskResult)"
} catch {
  Add-Result 'Oracle' 'scheduled RMAN run' 'CRITICAL' "task not found or unreadable: $($_.Exception.Message)"
}

# ---- MySQL: newest dump age ----------------------------------------------
try {
  $newest = Get-ChildItem -LiteralPath $MysqlBackupRoot -Filter '*.sql' -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { throw "no dump found under $MysqlBackupRoot" }
  $ageH = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalHours, 1)
  if ($ageH -gt ($BackupWarnHours * 2)) { $st = 'CRITICAL' } elseif ($ageH -gt $BackupWarnHours) { $st = 'WARNING' } else { $st = 'OK' }
  Add-Result 'MySQL' 'newest dump' $st "$($newest.Name), $ageH h old"
} catch {
  Add-Result 'MySQL' 'newest dump' 'CRITICAL' "check failed: $($_.Exception.Message)"
}

Pop-Location

$stamp = (Get-Date).ToString('s')
$dir = Split-Path -Parent $LogFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$lines = @("[{0}] AFS backup health" -f $stamp)
foreach ($r in $results) { $lines += ("{0,-8} {1,-12} {2,-32} {3}" -f $r.Status, $r.Engine, $r.Check, $r.Detail) }
$lines | ForEach-Object { Write-Host $_ }
Add-Content -LiteralPath $LogFile -Value $lines

if ($results.Status -contains 'CRITICAL') { exit 2 }
if ($results.Status -contains 'WARNING')  { exit 1 }
exit 0
