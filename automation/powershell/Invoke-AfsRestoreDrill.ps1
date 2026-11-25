# Timed restore drill: latest full + every log to the end of the chain, into a throw-away database.
# Restores to -Target, runs DBCC CHECKDB, compares row counts, then drops the target.
# This is the only script in the repository that writes to the instance; run it deliberately.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Server   = '.',
  [string]$Database = 'AFS_CoreBanking',
  [string]$Target   = 'AFS_RTO_Test',
  [string]$DataDir  = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA',
  [switch]$KeepTarget
)

$ErrorActionPreference = 'Stop'
$cs  = "Server=$Server;Database=master;Integrated Security=true;Connect Timeout=30;Encrypt=false;Application Name=AFS-RestoreDrill"
$sw  = [System.Diagnostics.Stopwatch]::StartNew()
$log = New-Object System.Collections.Generic.List[string]
function Say([string]$m) { $line = "[{0:HH:mm:ss.fff}] {1}" -f (Get-Date), $m; Write-Host $line; $log.Add($line) }

$conn = New-Object System.Data.SqlClient.SqlConnection($cs)
$conn.Open()
function Invoke-Sql([string]$sql, [int]$timeout = 600) {
  $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = $timeout; $cmd.CommandText = $sql
  $cmd.ExecuteNonQuery() | Out-Null
}
function Get-Rows([string]$sql) {
  $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = 600; $cmd.CommandText = $sql
  $t = New-Object System.Data.DataTable
  (New-Object System.Data.SqlClient.SqlDataAdapter($cmd)).Fill($t) | Out-Null
  return ,$t
}

try {
  Say "source=$Database target=$Target server=$Server"

  # 1. Latest full backup that still exists on disk
  $fulls = Get-Rows @"
SELECT TOP 5 b.backup_set_id, b.backup_finish_date, mf.physical_device_name
FROM msdb.dbo.backupset b
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = b.media_set_id
WHERE b.database_name = '$Database' AND b.type = 'D'
ORDER BY b.backup_finish_date DESC;
"@
  $full = $null
  foreach ($r in $fulls.Rows) {
    $path = [string]$r['physical_device_name']
    if ($path -and (Test-Path -LiteralPath $path)) { $full = $r; break }
    Say ("skip missing media: " + $path)
  }
  if (-not $full) { throw "no full backup file found on disk for $Database" }
  $fullPath = [string]$full['physical_device_name']
  Say ("full: {0} ({1})" -f $full['backup_finish_date'], $fullPath)

  # 2. Log backups after that full, in LSN order
  $logs = Get-Rows @"
SELECT b.backup_set_id, b.backup_finish_date, b.first_lsn, mf.physical_device_name
FROM msdb.dbo.backupset b
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = b.media_set_id
WHERE b.database_name = '$Database' AND b.type = 'L'
  AND b.backup_finish_date > '$(([datetime]$full['backup_finish_date']).ToString('yyyy-MM-dd HH:mm:ss.fff'))'
ORDER BY b.first_lsn;
"@
  Say ("log chain: {0} file(s)" -f $logs.Rows.Count)

  # 3. Logical file names from the full backup
  $files = Get-Rows "RESTORE FILELISTONLY FROM DISK = N'$fullPath';"
  $moves = @()
  foreach ($f in $files.Rows) {
    $ext  = if ($f.Type -eq 'L') { '.ldf' } else { '.mdf' }
    $dest = Join-Path $DataDir ("$Target" + $(if ($f.Type -eq 'L') { '_log' } else { '' }) + $ext)
    $moves += "MOVE N'$($f.LogicalName)' TO N'$dest'"
  }
  Say ("moves: " + ($moves -join '; '))

  # 4. Restore full, then each log
  $t0 = $sw.ElapsedMilliseconds
  Invoke-Sql ("RESTORE DATABASE [$Target] FROM DISK = N'$fullPath' WITH " +
              ($moves -join ', ') + ", NORECOVERY, CHECKSUM;")
  Say ("full restored in {0:N1} s" -f (($sw.ElapsedMilliseconds - $t0) / 1000))

  $i = 0
  foreach ($lg in $logs.Rows) {
    $i++
    $lgPath = [string]$lg['physical_device_name']
    $rec = if ($i -eq $logs.Rows.Count) { 'RECOVERY' } else { 'NORECOVERY' }
    Invoke-Sql ("RESTORE LOG [$Target] FROM DISK = N'$lgPath' WITH $rec, CHECKSUM;")
    if ($i % 5 -eq 0) { Say ("applied {0}/{1} logs" -f $i, $logs.Rows.Count) }
  }
  if ($logs.Rows.Count -eq 0) { Invoke-Sql "RESTORE DATABASE [$Target] WITH RECOVERY;" }
  $tRestore = $sw.ElapsedMilliseconds - $t0
  Say ("restore complete (full + $($logs.Rows.Count) logs) in {0:N1} s" -f ($tRestore / 1000))

  # 5. Integrity check
  $t1 = $sw.ElapsedMilliseconds
  Invoke-Sql "DBCC CHECKDB([$Target]) WITH NO_INFOMSGS, ALL_ERRORMSGS;" 3000
  $tCheck = $sw.ElapsedMilliseconds - $t1
  Say ("DBCC CHECKDB clean; {0:N1} s" -f ($tCheck / 1000))

  # 6. Prove the data is really there
  $c = Get-Rows @"
SELECT (SELECT COUNT_BIG(*) FROM [$Target].customer.Customer) cust,
       (SELECT COUNT_BIG(*) FROM [$Target].account.Account) acct,
       (SELECT COUNT_BIG(*) FROM [$Target].account.Transfer) trf,
       (SELECT COUNT_BIG(*) FROM [$Target].account.AccountLedgerEntry) ledg;
"@
  $row = $c.Rows[0]
  Say ("restored counts: customers={0} accounts={1} transfers={2} ledger={3}" -f $row.cust, $row.acct, $row.trf, $row.ledg)

  $total = $sw.ElapsedMilliseconds
  Say ("TOTAL RTO {0:N1} s (restore {1:N1} s + checkdb {2:N1} s)" -f ($total/1000), ($tRestore/1000), ($tCheck/1000))

  $log | Set-Content -Encoding UTF8 "evidence/verify/live/13_rto_drill.txt"
}
finally {
  if (-not $KeepTarget) {
    try {
      Invoke-Sql "IF DB_ID('$Target') IS NOT NULL BEGIN ALTER DATABASE [$Target] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Target]; END" 300
      Say "target dropped"
      $log | Set-Content -Encoding UTF8 "evidence/verify/live/13_rto_drill.txt"
    } catch { Write-Host "drop failed: $($_.Exception.Message)" }
  }
  $conn.Close()
}
