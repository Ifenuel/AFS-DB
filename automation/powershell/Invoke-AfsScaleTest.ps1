# Realistic-volume performance and concurrency exercise on the Developer instance.
#
# The 17k-row estate cannot show what an index does, so this builds a throwaway
# table of 1,000,000 transfers and measures the same month filter three ways:
#   * no index                          -> clustered scan
#   * index on CompletedAt              -> usually still a scan, because the query
#                                          also needs Amount (key lookups cost more)
#   * index on CompletedAt covering Amount -> index seek
#
# Measurement goes through sqlcmd because it returns SET STATISTICS IO text on
# stdout; the ADO.NET InfoMessage event does not surface those messages from
# PowerShell 5.1, and sys.dm_exec_query_stats is awkward to attribute to a single
# execution. Plan shape comes from SET SHOWPLAN_TEXT in its own batch (it must be
# the only statement in a batch).
#
# A final step opens two sessions on one row: the first holds an update in an open
# transaction and the second times out. Blocking is measured, not asserted.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Server     = '.',
  [int]$Rows          = 1000000,
  [string]$SqlCmdPath = 'C:\Program Files\SqlCmd\sqlcmd.exe',
  [int]$BlockSeconds  = 3
)
$ErrorActionPreference = 'Stop'
$Database = 'AFS_Scale_Lab'
if (-not (Test-Path -LiteralPath $SqlCmdPath)) { throw "sqlcmd not found: $SqlCmdPath" }
$tmpDir = 'C:\ProgramData\AFS\tmp'
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

function Invoke-Sqlcmd {
  param([string]$Query, [string]$File)
  if ($File) {
    $out = & $SqlCmdPath -S $Server -E -C -h-1 -W -i $File 2>&1 | Out-String
  } else {
    $out = & $SqlCmdPath -S $Server -E -C -h-1 -W -Q $Query 2>&1 | Out-String
  }
  if ($LASTEXITCODE -ne 0 -or $out -match 'Msg \d+, Level 1[6-9]|Msg \d+, Level 2') {
    throw "sqlcmd failed ($LASTEXITCODE): $out"
  }
  return $out
}

$where   = "CompletedAt >= '2026-11-01' AND CompletedAt < '2026-12-01'"
$measure = "SET NOCOUNT ON; USE [$Database]; SET STATISTICS IO ON; SELECT COUNT(*) AS rows_returned, SUM(Amount) AS total FROM dbo.TransferScale WHERE $where;"

$planFile = Join-Path $tmpDir 'scale_plan.sql'
Set-Content -LiteralPath $planFile -Encoding ASCII -Value @(
  'SET SHOWPLAN_TEXT ON',
  'GO',
  "USE [$Database];",
  "SELECT COUNT(*) AS rows_returned, SUM(Amount) AS total FROM dbo.TransferScale WHERE $where;",
  'GO'
)

function Get-PlanShape {
  $out = Invoke-Sqlcmd -File $planFile
  # Order matters: 'Clustered Index Scan' also contains 'Index Scan'.
  if ($out -match 'Clustered Index Scan') { return 'Clustered Index Scan' }
  if ($out -match 'Index Seek') { return 'Index Seek' }
  if ($out -match 'Table Scan') { return 'Table Scan' }
  if ($out -match 'Index Scan') { return 'Index Scan' }
  return 'unknown'
}

function Measure-Phase {
  param([string]$Label)
  $out = Invoke-Sqlcmd -Query $measure
  $reads = 0
  if ($out -match 'logical reads (\d+)') { $reads = [int]$Matches[1] }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  [void](Invoke-Sqlcmd -Query $measure)
  $sw.Stop()
  [pscustomobject]@{ Phase = $Label; Access = (Get-PlanShape); LogicalReads = $reads; WallMs = $sw.ElapsedMilliseconds }
}

Write-Host "== building $Database with $Rows rows =="
[void](Invoke-Sqlcmd -Query "IF DB_ID('$Database') IS NOT NULL BEGIN ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Database]; END")
[void](Invoke-Sqlcmd -Query "CREATE DATABASE [$Database];")

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$insert = @"
USE [$Database];
SET NOCOUNT ON;
WITH n AS (
  SELECT TOP ($Rows) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
  FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.TransferScale (FromAccountId, ToAccountId, Amount, Status, CompletedAt)
SELECT 1 + (i % 700), 1 + ((i * 7) % 700), CAST((i % 5000) + 1 AS decimal(19,4)),
       CASE WHEN i % 50 = 0 THEN 'FAILED' WHEN i % 10 = 0 THEN 'PENDING' ELSE 'COMPLETED' END,
       DATEADD(SECOND, -((i * 97) % (3 * 365 * 86400)), CAST('2026-11-25T00:00:00' AS datetime2(3)))
FROM n;
"@
[void](Invoke-Sqlcmd -Query "USE [$Database]; CREATE TABLE dbo.TransferScale (TransferId bigint IDENTITY(1,1) NOT NULL CONSTRAINT pk_TransferScale PRIMARY KEY, FromAccountId int NOT NULL, ToAccountId int NOT NULL, Amount decimal(19,4) NOT NULL, Status varchar(20) NOT NULL, CompletedAt datetime2(3) NOT NULL);")
[void](Invoke-Sqlcmd -Query $insert)
$sw.Stop()

$count = (& $SqlCmdPath -S $Server -E -C -h-1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM [$Database].dbo.TransferScale;" 2>&1 | Out-String).Trim()
$months = (& $SqlCmdPath -S $Server -E -C -h-1 -W -Q "SET NOCOUNT ON; SELECT COUNT(DISTINCT FORMAT(CompletedAt,'yyyy-MM')) FROM [$Database].dbo.TransferScale;" 2>&1 | Out-String).Trim()
Write-Host ("rows: {0} loaded in {1:N1} s, spanning {2} months" -f $count, ($sw.ElapsedMilliseconds / 1000), $months)

Write-Host '== 1. no index on CompletedAt =='
$r1 = Measure-Phase -Label 'no index'
$r1 | Format-Table -AutoSize

Write-Host '== 2. index on CompletedAt only =='
[void](Invoke-Sqlcmd -Query "USE [$Database]; CREATE INDEX IX_TransferScale_CompletedAt ON dbo.TransferScale (CompletedAt);")
$r2 = Measure-Phase -Label 'index (CompletedAt)'
$r2 | Format-Table -AutoSize

Write-Host '== 3. index on CompletedAt covering Amount =='
[void](Invoke-Sqlcmd -Query "USE [$Database]; CREATE INDEX IX_TransferScale_CompletedCover ON dbo.TransferScale (CompletedAt) INCLUDE (Amount);")
$r3 = Measure-Phase -Label 'index + INCLUDE (Amount)'
$r3 | Format-Table -AutoSize

Write-Host '== concurrency: two sessions, one row =='
$victim = (& $SqlCmdPath -S $Server -E -C -h-1 -W -Q "SET NOCOUNT ON; SELECT TOP 1 TransferId FROM [$Database].dbo.TransferScale ORDER BY TransferId;" 2>&1 | Out-String).Trim()
$cs = "Server=$Server;Database=$Database;Integrated Security=true;Connect Timeout=20;Encrypt=false"
$connA = New-Object System.Data.SqlClient.SqlConnection($cs); $connA.Open()
$connB = New-Object System.Data.SqlClient.SqlConnection($cs); $connB.Open()
$blocked = $false
try {
  $cA = $connA.CreateCommand(); $cA.CommandTimeout = 30
  $cA.CommandText = "BEGIN TRANSACTION; UPDATE dbo.TransferScale SET Status = 'HELD' WHERE TransferId = $victim;"
  $cA.ExecuteNonQuery() | Out-Null

  $cB = $connB.CreateCommand(); $cB.CommandTimeout = $BlockSeconds
  $cB.CommandText = "UPDATE dbo.TransferScale SET Status = 'HELD' WHERE TransferId = $victim;"
  $swB = [System.Diagnostics.Stopwatch]::StartNew()
  try { $cB.ExecuteNonQuery() | Out-Null } catch { $blocked = $true }
  $swB.Stop()
  Write-Host ("second session: {0} after {1:N1} s" -f $(if ($blocked) { 'timed out - lock wait observed' } else { 'SUCCEEDED - no blocking observed' }), ($swB.ElapsedMilliseconds / 1000))
} finally {
  $cA = $connA.CreateCommand(); $cA.CommandText = 'IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;'; $cA.ExecuteNonQuery() | Out-Null
  $connA.Close(); $connB.Close()
}

Write-Host '== cleanup =='
[void](Invoke-Sqlcmd -Query "IF DB_ID('$Database') IS NOT NULL BEGIN ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; END")
Start-Sleep -Seconds 2
[void](Invoke-Sqlcmd -Query "IF DB_ID('$Database') IS NOT NULL DROP DATABASE [$Database];")
Remove-Item -LiteralPath $planFile -Force -ErrorAction SilentlyContinue
$still = (& $SqlCmdPath -S $Server -E -C -h-1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '$Database';" 2>&1 | Out-String).Trim()
Write-Host ("lab database present after cleanup: {0}" -f $still)
if ($still -ne '0') { exit 1 }
Write-Host 'done'
exit 0
