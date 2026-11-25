# Point-in-time recovery drill on the SQL Server Developer instance.
#
# Uses a throwaway source database so the six AFS databases are untouched:
#   1. create AFS_PITR_Source in FULL recovery, take a full backup
#   2. insert a marker row, take a log backup
#   3. delete the row, take another log backup
#   4. restore full + logs into AFS_PITR_Target with STOPAT one second before the
#      delete, and assert the marker row is back
#   5. drop both databases
#
# This is the STOPAT behaviour claimed in INC-007, re-run on the Developer
# instance rather than left as a 2026-11-20 LocalDB result.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Server    = '.',
  [string]$BackupDir = 'C:\ProgramData\AFS\pitr'
)
$ErrorActionPreference = 'Stop'
$cs = "Server=$Server;Database=master;Integrated Security=true;Connect Timeout=20;Encrypt=false;Application Name=AFS-PITR-Drill"
$conn = New-Object System.Data.SqlClient.SqlConnection($cs)
$conn.Open()

function Invoke-Sql {
  param([string]$Sql)
  $cmd = $conn.CreateCommand()
  $cmd.CommandTimeout = 600
  $cmd.CommandText = $Sql
  $cmd.ExecuteNonQuery() | Out-Null
}
function Get-Scalar {
  param([string]$Sql)
  $cmd = $conn.CreateCommand()
  $cmd.CommandTimeout = 600
  $cmd.CommandText = $Sql
  return $cmd.ExecuteScalar()
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
# Per-run names: the files are owned by the SQL Server service account, so a
# re-run must never depend on being able to delete the previous run's output.
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$full    = Join-Path $BackupDir ("pitr_full_{0}.bak" -f $stamp)
$log1    = Join-Path $BackupDir ("pitr_log1_{0}.trn" -f $stamp)
$log2    = Join-Path $BackupDir ("pitr_log2_{0}.trn" -f $stamp)
$fullQ = $full.Replace("'", "''"); $log1Q = $log1.Replace("'", "''"); $log2Q = $log2.Replace("'", "''")

Write-Host '== setup =='
Invoke-Sql "IF DB_ID('AFS_PITR_Target') IS NOT NULL BEGIN ALTER DATABASE AFS_PITR_Target SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE AFS_PITR_Target; END"
Invoke-Sql "IF DB_ID('AFS_PITR_Source') IS NOT NULL BEGIN ALTER DATABASE AFS_PITR_Source SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE AFS_PITR_Source; END"
Invoke-Sql "CREATE DATABASE AFS_PITR_Source;"
Invoke-Sql "ALTER DATABASE AFS_PITR_Source SET RECOVERY FULL;"
Invoke-Sql "BACKUP DATABASE AFS_PITR_Source TO DISK = N'$fullQ' WITH INIT, CHECKSUM;"
Invoke-Sql "CREATE TABLE AFS_PITR_Source.dbo.Marker (Id int IDENTITY(1,1) PRIMARY KEY, Note nvarchar(80) NOT NULL, CreatedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME());"
Invoke-Sql "INSERT INTO AFS_PITR_Source.dbo.Marker (Note) VALUES (N'survives point-in-time recovery');"
Invoke-Sql "BACKUP LOG AFS_PITR_Source TO DISK = N'$log1Q' WITH INIT, CHECKSUM;"

$markerId = Get-Scalar "SELECT MAX(Id) FROM AFS_PITR_Source.dbo.Marker;"
Write-Host "marker row id=$markerId inserted and logged"

Start-Sleep -Seconds 2
$deletedAt = Get-Scalar "DELETE FROM AFS_PITR_Source.dbo.Marker WHERE Id = $markerId; SELECT SYSUTCDATETIME();"
Invoke-Sql "BACKUP LOG AFS_PITR_Source TO DISK = N'$log2Q' WITH INIT, CHECKSUM;"
$before = Get-Scalar "SELECT COUNT(*) FROM AFS_PITR_Source.dbo.Marker;"
Write-Host ("row deleted at {0}; rows now {1}" -f $deletedAt, $before)

# STOPAT one second before the delete: the row must come back, and only it.
$stopAt = ([datetime]$deletedAt).AddSeconds(-1).ToString('yyyy-MM-ddTHH:mm:ss.fff')
Write-Host "== restore to STOPAT $stopAt =="
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Invoke-Sql "RESTORE DATABASE AFS_PITR_Target FROM DISK = N'$fullQ' WITH MOVE 'AFS_PITR_Source' TO '$BackupDir\pitr_target.mdf', MOVE 'AFS_PITR_Source_log' TO '$BackupDir\pitr_target_log.ldf', NORECOVERY, REPLACE;"
Invoke-Sql "RESTORE LOG AFS_PITR_Target FROM DISK = N'$log1Q' WITH NORECOVERY;"
Invoke-Sql "RESTORE LOG AFS_PITR_Target FROM DISK = N'$log2Q' WITH STOPAT = '$stopAt', RECOVERY;"
$sw.Stop()

$restored = Get-Scalar "SELECT COUNT(*) FROM AFS_PITR_Target.dbo.Marker WHERE Id = $markerId;"
$note = Get-Scalar "SELECT Note FROM AFS_PITR_Target.dbo.Marker WHERE Id = $markerId;"
Write-Host ("rows recovered: {0} (note: {1})" -f $restored, $note)
Write-Host ("restore elapsed: {0:N2} s" -f ($sw.ElapsedMilliseconds / 1000))

Write-Host '== cleanup =='
Invoke-Sql "ALTER DATABASE AFS_PITR_Target SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE AFS_PITR_Target;"
Invoke-Sql "ALTER DATABASE AFS_PITR_Source SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE AFS_PITR_Source;"
# The service account owns the files it wrote, so removal can be denied; that is
# not a drill failure and must not abort the result line.
try {
  Get-ChildItem -LiteralPath $BackupDir -Filter 'pitr_*' -ErrorAction Stop | Remove-Item -Force -ErrorAction Stop
} catch {
  Write-Host ("note: backup files left in {0} (owned by the SQL Server service): {1}" -f $BackupDir, $_.Exception.Message)
}
$conn.Close()

if ($restored -ne 1) { Write-Host 'FAIL: the deleted row was not recovered exactly once'; exit 1 }
Write-Host 'PASS: point-in-time recovery restored exactly one deleted row'
exit 0
